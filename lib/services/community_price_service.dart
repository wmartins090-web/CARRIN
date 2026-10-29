import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/community_price.dart';
import '../models/item.dart';
import 'database_helper.dart';
import 'default_supermarkets.dart';
import 'location_service.dart';

class CommunityPriceService {
  CommunityPriceService._privateConstructor();
  static final CommunityPriceService instance = CommunityPriceService._privateConstructor();

  static const String _prefUrlKey = 'supabase_community_url';
  static const String _prefAnonKey = 'supabase_community_anon_key';
  static const String _prefDeviceIdKey = 'community_price_device_id';

  /// Namespace persistente do dispositivo para evitar colisões entre IDs SQLite
  /// que podem se repetir em instalações/dispositivos diferentes.
  Future<String> _getStableDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_prefDeviceIdKey);
    if (deviceId != null && deviceId.trim().isNotEmpty) return deviceId;

    final random = Random.secure();
    final timestamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final randomPart = List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();
    deviceId = '${timestamp}_$randomPart';
    await prefs.setString(_prefDeviceIdKey, deviceId);
    return deviceId;
  }


  /// Credenciais padrão do Supabase embutidas (zero configuração para o usuário)
  static const String defaultSupabaseUrl = 'https://togbshissjtctvlsvapc.supabase.co';
  static const String defaultSupabaseAnonKey = 'sb_publishable_DikvfAMTza89HWcTX5zNBQ_Z987Ak_y';

  /// Supermercado padrão de referência (Guanabara Niterói)
  static const String defaultStoreName = 'Supermercados Guanabara - Niterói';
  static const double defaultStoreLat = -22.89012;
  static const double defaultStoreLng = -43.11535;

  /// Descobre as coordenadas reais de um supermercado usando o banco local e o catálogo pré-carregado
  Future<Map<String, double>?> resolveMarketCoordinates(String marketName, {double? userLat, double? userLng}) async {
    final clean = marketName.trim();
    if (clean.isEmpty) return null;

    // 1. Tenta no catálogo estático calibrado DefaultSupermarketsData (fonte de verdade oficial)
    final preloaded = DefaultSupermarketsData.findMatch(clean, userLat: userLat, userLng: userLng);
    if (preloaded != null) {
      return {'latitude': preloaded.latitude, 'longitude': preloaded.longitude};
    }

    // 2. Tenta buscar no SQLite (supermercados customizados salvos)
    final saved = await DatabaseHelper.instance.findSupermarketByName(clean);
    if (saved != null) {
      final lat = (saved['latitude'] as num?)?.toDouble();
      final lng = (saved['longitude'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        return {'latitude': lat, 'longitude': lng};
      }
    }

    // 3. Fallback se contiver guanabara
    if (clean.toLowerCase().contains('guanabara')) {
      return {'latitude': defaultStoreLat, 'longitude': defaultStoreLng};
    }

    return null;
  }

  String? _cachedUrl;
  String? _cachedAnonKey;
  bool _isInitialized = false;
  Future<void>? _initFuture;
  DateTime? _lastCloudFetchTime;
  Future<void>? _ongoingCloudSync;
  static const int _catalogSyncVersion = 548;

  Future<void> init() async {
    if (_isInitialized) return;
    if (_initFuture != null) return _initFuture!;
    _initFuture = _doInit();
    await _initFuture;
  }

  Future<void> _doInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _cachedUrl = prefs.getString(_prefUrlKey) ?? defaultSupabaseUrl;
      _cachedAnonKey = prefs.getString(_prefAnonKey) ?? defaultSupabaseAnonKey;

      final lastSyncedCatalogVersion = prefs.getInt('community_catalog_sync_version') ?? 0;
      if (lastSyncedCatalogVersion != _catalogSyncVersion) {
        await DatabaseHelper.instance.purgeSeedCommunityPrices();
        await DatabaseHelper.instance.cleanTestSupermarkets();
        await DatabaseHelper.instance.ensureDefaultSupermarkets();
        await DatabaseHelper.instance.assignDefaultSupermarket(defaultStoreName);
        await prefs.setInt('community_catalog_sync_version', _catalogSyncVersion);
      }

      await DatabaseHelper.instance.fixExistingLocalPricesDates();
      await DatabaseHelper.instance.seedCommunityPricesFromUserPurchases();

      // Auto-sincronização obrigatória e transparente das compras do usuário para a comunidade
      _autoSyncUserPurchasesInBackground();
    } catch (e) {
      debugPrint('📍 CommunityPriceService init error: $e');
    }
    _isInitialized = true;
  }

  /// Sincroniza compras usando um identificador de evento persistente por item SQLite.
  /// A chave do evento não depende de preço/nome, portanto compras repetidas são eventos distintos.
  Future<void> _autoSyncUserPurchasesInBackground() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userItems = await DatabaseHelper.instance.getAllUserPurchasedProducts();
      if (userItems.isEmpty) return;

      final deviceId = await _getStableDeviceId();
      final syncedJson = prefs.getString('community_synced_event_ids_v1');
      final Set<String> syncedEventIds = {};
      if (syncedJson != null && syncedJson.isNotEmpty) {
        try {
          syncedEventIds.addAll((jsonDecode(syncedJson) as List).whereType<String>());
        } catch (_) {}
      }

      final List<CommunityPrice> toPublish = [];
      final Set<String> eventIdsInBatch = {};
      for (final row in userItems) {
        final itemId = (row['id'] as num?)?.toInt();
        final name = (row['name'] as String? ?? '').trim();
        final price = (row['unit_price'] as num?)?.toDouble() ?? 0.0;
        if (itemId == null || name.isEmpty || price <= 0) continue;

        final eventId = 'purchase_${deviceId}_$itemId';
        if (syncedEventIds.contains(eventId) || !eventIdsInBatch.add(eventId)) continue;

        String market = (row['supermarket'] as String? ?? '').trim();
        if (market.isEmpty || market.toLowerCase() == 'supermercado local' || market.toLowerCase() == 'supermercado') {
          market = defaultStoreName;
        }
        final coords = await resolveMarketCoordinates(market);
        final itemDate = DatabaseHelper.parseDateFromMonthTitle(row['month_title'] as String?);
        toPublish.add(CommunityPrice(
          id: eventId,
          productName: name,
          category: row['category'] as String?,
          unit: row['is_kg'] == 1 ? 'kg' : 'un',
          price: price,
          supermarketName: market,
          latitude: coords?['latitude'],
          longitude: coords?['longitude'],
          submittedBy: 'Cliente CARRIN',
          verifiedReceipt: false,
          createdAt: itemDate,
        ));
      }

      if (toPublish.isEmpty) return;
      debugPrint('🚀 Sincronizando ${toPublish.length} eventos de compra para a Comunidade...');
      final count = await publishPricesBatch(toPublish);
      if (count == toPublish.length) {
        syncedEventIds.addAll(toPublish.map((p) => p.id));
        await prefs.setString('community_synced_event_ids_v1', jsonEncode(syncedEventIds.toList()));
        debugPrint('✅ ${toPublish.length} eventos de compra confirmados/sincronizados!');
      } else {
        debugPrint('⚠️ Sincronização incompleta/falhou; os eventos serão tentados novamente.');
      }
    } catch (e) {
      debugPrint('⚠️ Erro na auto-sincronização de compras: $e');
    }
  }

  /// Sincroniza em lote os itens comprados de um carrinho/mês finalizado
  Future<void> syncMonthPurchases(String month, List<dynamic> items) async {
    try {
      final List<CommunityPrice> toPublish = [];
      for (var it in items) {
        final bool isBought = it is Item ? it.isBought : (it.isBought == true);
        if (!isBought) continue;

        final name = (it.name as String? ?? '').trim();
        final price = (it.unitPrice as num?)?.toDouble() ?? 0.0;
        if (name.isEmpty || price <= 0) continue;

        String market = (it.supermarket as String? ?? '').trim();
        if (market.isEmpty || market.toLowerCase() == 'supermercado local' || market.toLowerCase() == 'supermercado') {
          market = defaultStoreName;
        }

        final coords = await resolveMarketCoordinates(market);
        final monthDate = DatabaseHelper.parseDateFromMonthTitle(month);

        toPublish.add(CommunityPrice(
          id: 'month_${DateTime.now().millisecondsSinceEpoch}_${name.hashCode.abs()}',
          productName: name,
          category: it.category as String?,
          unit: it.isKg == true ? 'kg' : 'un',
          price: price,
          supermarketName: market,
          latitude: coords?['latitude'],
          longitude: coords?['longitude'],
          submittedBy: 'Cliente CARRIN',
          verifiedReceipt: false,
          createdAt: monthDate,
        ));
      }
      if (toPublish.isNotEmpty) {
        await publishPricesBatch(toPublish);
      }
    } catch (e) {
      debugPrint('Erro ao sincronizar compras do mês: $e');
    }
  }

  bool get isConfigured => 
      _cachedUrl != null && _cachedUrl!.trim().isNotEmpty && 
      _cachedAnonKey != null && _cachedAnonKey!.trim().isNotEmpty;

  String? get supabaseUrl => _cachedUrl ?? defaultSupabaseUrl;
  String? get supabaseAnonKey => _cachedAnonKey ?? defaultSupabaseAnonKey;

  Map<String, String> _buildHeaders({bool isPost = false}) {
    final key = _cachedAnonKey ?? defaultSupabaseAnonKey;
    final headers = <String, String>{
      'apikey': key,
      'Accept': 'application/json',
    };
    // As chaves legadas do Supabase são JWTs (iniciando em eyJ).
    // Apenas JWTs devem ser enviados no header Authorization: Bearer.
    // As novas chaves (sb_publishable_...) não devem ir no Authorization Bearer.
    if (key.startsWith('eyJ')) {
      headers['Authorization'] = 'Bearer $key';
    }
    if (isPost) {
      headers['Content-Type'] = 'application/json';
      headers['Prefer'] = 'resolution=ignore-duplicates,return=minimal';
    }
    return headers;
  }

  Future<void> saveConfig(String url, String anonKey) async {
    final prefs = await SharedPreferences.getInstance();
    _cachedUrl = url.trim();
    _cachedAnonKey = anonKey.trim();
    await prefs.setString(_prefUrlKey, _cachedUrl!);
    await prefs.setString(_prefAnonKey, _cachedAnonKey!);
  }

  /// Publica um preço registrado pelo usuário na base da comunidade
  Future<bool> publishPrice({
    required String productName,
    required double price,
    required String supermarketName,
    String? category,
    String? unit,
    double? latitude,
    double? longitude,
    String? submittedBy,
    bool verifiedReceipt = false,
    DateTime? createdAt,
  }) async {
    await init();
    if (productName.trim().isEmpty || price <= 0 || supermarketName.trim().isEmpty) {
      return false;
    }

    double? finalLat = latitude;
    double? finalLng = longitude;
    if (finalLat == null || finalLng == null) {
      final coords = await resolveMarketCoordinates(supermarketName);
      if (coords != null) {
        finalLat = coords['latitude'];
        finalLng = coords['longitude'];
      }
    }

    final newPrice = CommunityPrice(
      id: 'cp_${DateTime.now().millisecondsSinceEpoch}_${productName.hashCode.abs()}',
      productName: productName.trim(),
      category: category,
      unit: unit ?? 'un',
      price: price,
      supermarketName: supermarketName.trim(),
      latitude: finalLat,
      longitude: finalLng,
      submittedBy: submittedBy ?? 'Cliente CARRIN',
      verifiedReceipt: verifiedReceipt,
      createdAt: createdAt ?? DateTime.now(),
    );

    // 1. Salva imediatamente no banco SQLite local do dispositivo
    await DatabaseHelper.instance.saveCommunityPrice(newPrice);

    // 2. Se o Supabase estiver configurado, envia via REST API
    if (isConfigured) {
      try {
        final endpoint = Uri.parse('${_cachedUrl!}/rest/v1/community_prices?on_conflict=event_id');
        final response = await http.post(
          endpoint,
          headers: _buildHeaders(isPost: true),
          body: jsonEncode({
            'event_id': newPrice.id,
            'product_name': newPrice.productName,
            'category': newPrice.category,
            'unit': newPrice.unit,
            'price': newPrice.price,
            'supermarket_name': newPrice.supermarketName,
            'latitude': newPrice.latitude,
            'longitude': newPrice.longitude,
            'submitted_by': newPrice.submittedBy,
            'verified_receipt': false, // Sempre false no envio público anon para respeitar a política RLS
            'created_at': newPrice.createdAt.toIso8601String(),
          }),
        ).timeout(const Duration(seconds: 5));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          debugPrint('✅ Preço publicado na nuvem Supabase com sucesso: ${newPrice.productName}');
          return true;
        } else {
          debugPrint('⚠️ Resposta Supabase: ${response.statusCode} - ${response.body}');
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao enviar preço para o Supabase (salvo localmente): $e');
      }
    }

    // O preço continua salvo no SQLite para uso offline, mas só consideramos
    // a publicação bem-sucedida quando o Supabase confirma uma resposta 2xx.
    return false;
  }

  /// Publica uma lista de preços em lote na nuvem do Supabase e no SQLite local
  Future<int> publishPricesBatch(List<CommunityPrice> prices) async {
    if (prices.isEmpty) return 0;
    await init();

    // 1. Salva no SQLite local
    await DatabaseHelper.instance.saveCommunityPrices(prices);

    // 2. Se o Supabase estiver configurado, envia em lote via REST API
    if (isConfigured) {
      try {
        final endpoint = Uri.parse('${_cachedUrl!}/rest/v1/community_prices?on_conflict=event_id');
        final payload = prices.map((p) => {
          'event_id': p.id,
          'product_name': p.productName,
          'category': p.category,
          'unit': p.unit,
          'price': p.price,
          'supermarket_name': p.supermarketName,
          'latitude': p.latitude,
          'longitude': p.longitude,
          'submitted_by': p.submittedBy,
          'verified_receipt': false, // Sempre false no envio público anon para respeitar a política RLS
          'created_at': p.createdAt.toIso8601String(),
        }).toList();

        final response = await http.post(
          endpoint,
          headers: _buildHeaders(isPost: true),
          body: jsonEncode(payload),
        ).timeout(const Duration(seconds: 12));

        if (response.statusCode >= 200 && response.statusCode < 300) {
          debugPrint('✅ ${prices.length} preços publicados em lote no Supabase com sucesso!');
          return prices.length;
        } else {
          debugPrint('⚠️ Erro no batch Supabase: ${response.statusCode} - ${response.body}');
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao enviar lote para o Supabase: $e');
      }
    }

    // Mantém os preços no SQLite, mas sinaliza falha para que a sincronização
    // não marque os itens como enviados e possa tentar novamente mais tarde.
    return 0;
  }

  /// Coleta os produtos que o usuário possui com preços reais registrados no app
  Future<List<CommunityPrice>> getUserRegisteredPrices({
    String? fallbackSupermarket,
    double? fallbackLat,
    double? fallbackLng,
    Map<String, List<Map<String, dynamic>>>? priceHistoryCache,
  }) async {
    final List<CommunityPrice> list = [];
    final Set<String> seenKeys = {};

    // 1. Coleta do SQLite (todas as listas de compras registradas)
    final dbRows = await DatabaseHelper.instance.getAllUserPurchasedProducts();
    for (var row in dbRows) {
      final name = (row['name'] as String? ?? '').trim();
      final price = (row['unit_price'] as num?)?.toDouble() ?? 0.0;
      if (name.isEmpty || price <= 0) continue;

      String market = (row['supermarket'] as String? ?? '').trim();
      final lMarket = market.toLowerCase();
      if (market.isEmpty || lMarket == 'supermercado local' || lMarket == 'supermercado') {
        market = fallbackSupermarket ?? defaultStoreName;
      }

      final normName = name.toLowerCase();
      final normMarket = market.toLowerCase();
      final key = '${normName}_$normMarket';

      if (!seenKeys.contains(key)) {
        seenKeys.add(key);
        list.add(CommunityPrice(
          id: 'user_${DateTime.now().millisecondsSinceEpoch}_${key.hashCode.abs()}',
          productName: name,
          category: row['category'] as String?,
          unit: row['is_kg'] == 1 ? 'kg' : 'un',
          price: price,
          supermarketName: market,
          latitude: (market == defaultStoreName) ? defaultStoreLat : fallbackLat,
          longitude: (market == defaultStoreName) ? defaultStoreLng : fallbackLng,
          submittedBy: 'Minhas Compras',
          verifiedReceipt: false,
          createdAt: DateTime.now(),
        ));
      }
    }

    // 2. Se houver histórico de preços em memória/cache, adiciona os que faltam
    if (priceHistoryCache != null) {
      for (var entryList in priceHistoryCache.values) {
        for (var entry in entryList) {
          final name = (entry['name'] as String? ?? '').trim();
          final price = (entry['price'] as num?)?.toDouble() ?? 0.0;
          if (name.isEmpty || price <= 0) continue;

          String market = (entry['supermarket'] as String? ?? '').trim();
          final lMarket = market.toLowerCase();
          if (market.isEmpty || lMarket == 'supermercado local' || lMarket == 'supermercado') {
            market = fallbackSupermarket ?? defaultStoreName;
          }

          final normName = name.toLowerCase();
          final normMarket = market.toLowerCase();
          final key = '${normName}_$normMarket';

          if (!seenKeys.contains(key)) {
            seenKeys.add(key);
            list.add(CommunityPrice(
              id: 'hist_${DateTime.now().millisecondsSinceEpoch}_${key.hashCode.abs()}',
              productName: name,
              category: entry['category'] as String?,
              unit: 'un',
              price: price,
              supermarketName: market,
              latitude: (market == defaultStoreName) ? defaultStoreLat : fallbackLat,
              longitude: (market == defaultStoreName) ? defaultStoreLng : fallbackLng,
              submittedBy: 'Minhas Compras',
              verifiedReceipt: false,
              createdAt: DateTime.now(),
            ));
          }
        }
      }
    }

    return list;
  }

  /// Sincroniza dados da nuvem Supabase com controle de cooldown para evitar múltiplas chamadas seguidas
  Future<void> syncFromCloud({
    String? query,
    double? userLat,
    double? userLng,
    bool force = false,
  }) async {
    await init();
    if (!isConfigured) return;

    final hasQuery = query != null && query.trim().isNotEmpty;
    if (!force && !hasQuery && _lastCloudFetchTime != null) {
      final elapsed = DateTime.now().difference(_lastCloudFetchTime!);
      if (elapsed.inSeconds < 45) return;
    }

    if (!hasQuery && _ongoingCloudSync != null) {
      await _ongoingCloudSync;
      return;
    }

    final future = _performCloudSync(query: query, userLat: userLat, userLng: userLng);
    if (!hasQuery) {
      _ongoingCloudSync = future;
    }
    try {
      await future;
    } finally {
      if (!hasQuery) {
        _ongoingCloudSync = null;
      }
    }
  }

  Future<void> _performCloudSync({
    String? query,
    double? userLat,
    double? userLng,
  }) async {
    try {
      String urlStr = '${_cachedUrl!}/rest/v1/community_prices?select=id,event_id,product_name,category,unit,price,supermarket_name,latitude,longitude,submitted_by,verified_receipt,created_at&order=created_at.desc&limit=500';
      if (query != null && query.trim().isNotEmpty) {
        urlStr += '&product_name=ilike.*${Uri.encodeComponent(query.trim())}*';
      }
      final endpoint = Uri.parse(urlStr);
      final response = await http.get(
        endpoint,
        headers: _buildHeaders(isPost: false),
      ).timeout(const Duration(milliseconds: 3500));

      if (response.statusCode == 200) {
        final List<dynamic> list = jsonDecode(response.body);
        final cloudPrices = list
            .map((item) => CommunityPrice.fromMap(item as Map<String, dynamic>, userLat: userLat, userLng: userLng))
            .where((p) {
              final isMock = p.submittedBy.contains('Teste') ||
                             p.submittedBy == 'Comunidade CARRIN' ||
                             p.id.startsWith('seed_');
              return !isMock;
            })
            .toList();
        if (cloudPrices.isNotEmpty) {
          await DatabaseHelper.instance.saveCommunityPrices(cloudPrices);
          await DatabaseHelper.instance.deduplicateCommunityPricesCache();
        }
        if (query == null || query.trim().isEmpty) {
          _lastCloudFetchTime = DateTime.now();
        }
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao buscar feed no Supabase (usando cache local): $e');
    }
  }

  /// Busca os preços mais recentes e sincroniza com a nuvem se disponível
  Future<List<CommunityPrice>> getRecentFeed({
    double? userLat,
    double? userLng,
    double radiusKm = 25.0,
    String? query,
    bool syncWithCloud = true,
    bool forceCloudRefresh = false,
  }) async {
    await init();

    // 1. Tenta buscar dados novos do Supabase se solicitado (respeitando cooldown de 45s)
    if (syncWithCloud) {
      await syncFromCloud(
        query: query,
        userLat: userLat,
        userLng: userLng,
        force: forceCloudRefresh,
      );
    }

    // 2. Lê do cache local SQLite
    List<CommunityPrice> localPrices = [];
    try {
      localPrices = await DatabaseHelper.instance.getCachedCommunityPrices(
        query: query,
        userLat: userLat,
        userLng: userLng,
      );
    } catch (_) {
      localPrices = [];
    }

    // 3. Filtra pelo raio do GPS se o usuário tiver localização
    List<CommunityPrice> filtered = localPrices;
    if (userLat != null && userLng != null) {
      final maxMeters = radiusKm * 1000;
      final inRadius = localPrices.where((p) {
        if (p.distanceMeters == null) return true; // sem coordenadas aceita
        return p.distanceMeters! <= maxMeters;
      }).toList();
      if (inRadius.isNotEmpty) {
        filtered = inRadius;
      }
    }

    // 4. Garante unicidade no feed (elimina produtos repetidos do mesmo mercado)
    final List<CommunityPrice> dedupedFeed = [];
    final Set<String> seenFeedKeys = {};
    for (final p in filtered) {
      final normProd = p.productName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final normMarket = p.supermarketName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      final key = '$normProd|$normMarket';
      if (seenFeedKeys.add(key)) {
        dedupedFeed.add(p);
      }
    }

    // 5. Ordena cronologicamente (preços mais recentes primeiro no feed social)
    dedupedFeed.sort((a, b) {
      final dateComp = b.createdAt.compareTo(a.createdAt);
      if (dateComp != 0) return dateComp;
      final distA = a.distanceMeters ?? double.infinity;
      final distB = b.distanceMeters ?? double.infinity;
      return distA.compareTo(distB);
    });

    return dedupedFeed;
  }

  /// Retorna o ranking comparativo de quais mercados na região estão valendo mais a pena
  Future<List<MarketComparison>> getCheapestMarketsNearby({
    required double userLat,
    required double userLng,
    double radiusKm = 15.0,
    List<CommunityPrice>? preloadedPrices,
    bool syncWithCloud = false,
  }) async {
    await init();
    final allPrices = preloadedPrices ??
        await getRecentFeed(
          userLat: userLat,
          userLng: userLng,
          radiusKm: radiusKm,
          syncWithCloud: syncWithCloud,
        );

    List<Map<String, dynamic>> savedSupermarkets = [];
    try {
      savedSupermarkets = await DatabaseHelper.instance.getSupermarkets();
    } catch (_) {
      savedSupermarkets = [];
    }
    final Map<String, Map<String, dynamic>> savedByNormName = {};
    for (final s in savedSupermarkets) {
      final n = (s['name'] as String? ?? '').trim().toLowerCase();
      if (n.isNotEmpty) {
        savedByNormName[n] = s;
      }
    }

    // Agrupa preços por supermercado canônico
    final Map<String, List<CommunityPrice>> marketMap = {};
    final Map<String, CommunityPrice> marketPosMap = {};

    for (var p in allPrices) {
      final rawMarket = p.supermarketName.trim();
      if (rawMarket.isEmpty) continue;
      final match = DefaultSupermarketsData.findMatch(rawMarket, userLat: userLat, userLng: userLng);
      final market = match?.name ?? rawMarket;

      marketMap.putIfAbsent(market, () => []).add(p);
      if (p.latitude != null && p.longitude != null && !marketPosMap.containsKey(market)) {
        marketPosMap[market] = p;
      }
    }

    // Agrupa preços por produto para descobrir onde cada produto é mais barato
    final Map<String, double> lowestProductPrice = {};
    for (var p in allPrices) {
      final normName = p.productName.toLowerCase().trim();
      if (!lowestProductPrice.containsKey(normName) || p.price < lowestProductPrice[normName]!) {
        lowestProductPrice[normName] = p.price;
      }
    }

    final Map<String, MarketComparison> deduped = {};
    final maxMeters = radiusKm * 1000;

    for (var entry in marketMap.entries) {
      final market = entry.key;
      final prices = entry.value;

      double totalSum = 0;
      int cheapestCount = 0;

      for (var p in prices) {
        totalSum += p.price;
        final normName = p.productName.toLowerCase().trim();
        if (lowestProductPrice.containsKey(normName) && p.price <= lowestProductPrice[normName]!) {
          cheapestCount++;
        }
      }

      final avgPrice = prices.isNotEmpty ? totalSum / prices.length : 0.0;
      final posRef = marketPosMap[market];

      // Resolução O(1) em memória (Catálogo oficial -> SQLite carregado -> Fallback)
      final preloaded = DefaultSupermarketsData.findMatch(market, userLat: userLat, userLng: userLng);
      final saved = savedByNormName[market.toLowerCase()];

      double? lat = preloaded?.latitude ??
          (saved?['latitude'] as num?)?.toDouble() ??
          posRef?.latitude;
      double? lng = preloaded?.longitude ??
          (saved?['longitude'] as num?)?.toDouble() ??
          posRef?.longitude;

      if ((lat == null || lng == null) && market.toLowerCase().contains('guanabara')) {
        lat = defaultStoreLat;
        lng = defaultStoreLng;
      }

      double? dist;
      if (lat != null && lng != null) {
        dist = LocationService.instance.calculateDistance(userLat, userLng, lat, lng);
      }

      final canonicalName = preloaded?.name ?? market;
      final key = canonicalName.toLowerCase();

      final comp = MarketComparison(
        supermarketName: canonicalName,
        latitude: lat,
        longitude: lng,
        distanceMeters: dist,
        itemsCount: prices.length,
        averageItemPrice: avgPrice,
        cheapestCount: cheapestCount,
      );

      if (!deduped.containsKey(key) || comp.itemsCount > deduped[key]!.itemsCount) {
        deduped[key] = comp;
      }
    }

    // Inclui mercados do catálogo oficial dentro do raio (O(N) direto com pré-filtro de bounding box)
    final maxDegLat = (radiusKm / 110.0) + 0.02;
    final maxDegLng = (radiusKm / 100.0) + 0.02;
    for (final pre in DefaultSupermarketsData.all) {
      if ((pre.latitude - userLat).abs() > maxDegLat ||
          (pre.longitude - userLng).abs() > maxDegLng) {
        continue;
      }
      final key = pre.name.toLowerCase();
      if (deduped.containsKey(key)) continue;

      final dist = LocationService.instance.calculateDistance(userLat, userLng, pre.latitude, pre.longitude);
      if (dist > maxMeters) continue;

      deduped[key] = MarketComparison(
        supermarketName: pre.name,
        latitude: pre.latitude,
        longitude: pre.longitude,
        distanceMeters: dist,
        itemsCount: 0,
        averageItemPrice: 0.0,
        cheapestCount: 0,
      );
    }

    // Inclui mercados customizados salvos no SQLite
    for (var s in savedSupermarkets) {
      final sName = (s['name'] as String? ?? '').trim();
      if (sName.isEmpty) continue;
      final match = DefaultSupermarketsData.findMatch(sName, userLat: userLat, userLng: userLng);
      final canonicalName = match?.name ?? sName;
      final key = canonicalName.toLowerCase();

      if (deduped.containsKey(key)) continue;

      final lat = match?.latitude ?? (s['latitude'] as num?)?.toDouble();
      final lng = match?.longitude ?? (s['longitude'] as num?)?.toDouble();
      double? dist;
      if (lat != null && lng != null) {
        dist = LocationService.instance.calculateDistance(userLat, userLng, lat, lng);
        if (dist > maxMeters) continue;
      }
      deduped[key] = MarketComparison(
        supermarketName: canonicalName,
        latitude: lat,
        longitude: lng,
        distanceMeters: dist,
        itemsCount: 0,
        averageItemPrice: 0.0,
        cheapestCount: 0,
      );
    }

    final comparisons = deduped.values.toList();

    // Ordena: primeiro mercados com itens monitorados (por mais itens campeões e menor média), depois por distância
    comparisons.sort((a, b) {
      final aHasItems = a.itemsCount > 0 ? 1 : 0;
      final bHasItems = b.itemsCount > 0 ? 1 : 0;
      if (bHasItems != aHasItems) {
        return bHasItems.compareTo(aHasItems);
      }
      if (b.cheapestCount != a.cheapestCount) {
        return b.cheapestCount.compareTo(a.cheapestCount);
      }
      if (a.averageItemPrice > 0 && b.averageItemPrice > 0 && a.averageItemPrice != b.averageItemPrice) {
        return a.averageItemPrice.compareTo(b.averageItemPrice);
      }
      final distA = a.distanceMeters ?? double.infinity;
      final distB = b.distanceMeters ?? double.infinity;
      return distA.compareTo(distB);
    });

    if (comparisons.isNotEmpty && comparisons.first.itemsCount > 0) {
      final first = comparisons.first;
      comparisons[0] = MarketComparison(
        supermarketName: first.supermarketName,
        latitude: first.latitude,
        longitude: first.longitude,
        distanceMeters: first.distanceMeters,
        itemsCount: first.itemsCount,
        averageItemPrice: first.averageItemPrice,
        cheapestCount: first.cheapestCount,
        isCheapest: true,
      );
    }

    return comparisons;
  }

  /// Retorna as principais ofertas ou itens cadastrados de um supermercado específico
  Future<List<CommunityPrice>> getTopDealsForMarket(
    String marketName, {
    int limit = 6,
    double? userLat,
    double? userLng,
  }) async {
    final targetMatch = DefaultSupermarketsData.findMatch(marketName, userLat: userLat, userLng: userLng);
    final canonicalTarget = (targetMatch?.name ?? marketName).trim().toLowerCase();
    final cleanMarket = marketName.trim().toLowerCase();

    final allPrices = await getRecentFeed(
      userLat: userLat,
      userLng: userLng,
      radiusKm: 50.0,
      syncWithCloud: false,
    );
    final marketPrices = allPrices.where((p) {
      final pRaw = p.supermarketName.trim();
      if (pRaw.toLowerCase() == cleanMarket || pRaw.toLowerCase() == canonicalTarget) return true;
      final pMatch = DefaultSupermarketsData.findMatch(pRaw, userLat: userLat, userLng: userLng);
      return pMatch != null && pMatch.name.toLowerCase() == canonicalTarget;
    }).toList();

    // Remove produtos duplicados pelo nome, mantendo o menor preço
    final Map<String, CommunityPrice> uniqueByName = {};
    for (var p in marketPrices) {
      final k = p.productName.trim().toLowerCase();
      if (!uniqueByName.containsKey(k) || p.price < uniqueByName[k]!.price) {
        uniqueByName[k] = p;
      }
    }

    final result = uniqueByName.values.toList();
    result.sort((a, b) => a.price.compareTo(b.price));
    if (result.length > limit) {
      return result.sublist(0, limit);
    }
    return result;
  }

  /// Busca e compara preços de um determinado produto entre diferentes mercados
  Future<ProductComparison?> getProductComparison(
    String query, {
    double? userLat,
    double? userLng,
    double radiusKm = 20.0,
    List<CommunityPrice>? preloadedPrices,
    bool syncWithCloud = false,
  }) async {
    final prices = preloadedPrices ??
        await getRecentFeed(
          userLat: userLat,
          userLng: userLng,
          radiusKm: radiusKm,
          query: query,
          syncWithCloud: syncWithCloud,
        );
    final cleanQ = query.toLowerCase().trim();
    final matching = prices.where((p) => p.productName.toLowerCase().contains(cleanQ)).toList();

    if (matching.isEmpty) return null;

    matching.sort((a, b) => a.price.compareTo(b.price));

    double sum = 0;
    for (var p in matching) {
      sum += p.price;
    }

    final minPrice = matching.first.price;
    final maxPrice = matching.last.price;
    final avgPrice = sum / matching.length;
    final cheapest = matching.first;
    final mostExpensive = matching.last;

    return ProductComparison(
      productName: cheapest.productName,
      unit: cheapest.unit ?? 'un',
      averagePrice: avgPrice,
      minPrice: minPrice,
      maxPrice: maxPrice,
      cheapestMarket: cheapest.supermarketName,
      cheapestMarketDistance: cheapest.distanceMeters,
      mostExpensiveMarket: mostExpensive.supermarketName,
      totalQuotes: matching.length,
      prices: matching,
    );
  }

  /// Retorna a lista comparativa de todos os produtos distintos monitorados na comunidade
  Future<List<ProductComparison>> getAllProductComparisons({
    double? userLat,
    double? userLng,
    double radiusKm = 25.0,
    String? query,
    List<CommunityPrice>? preloadedPrices,
    bool syncWithCloud = false,
  }) async {
    final prices = preloadedPrices ??
        await getRecentFeed(
          userLat: userLat,
          userLng: userLng,
          radiusKm: radiusKm,
          query: query,
          syncWithCloud: syncWithCloud,
        );
    if (prices.isEmpty) return [];

    final Map<String, List<CommunityPrice>> grouped = {};
    for (var p in prices) {
      final key = p.productName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
      if (key.isNotEmpty) {
        grouped.putIfAbsent(key, () => []).add(p);
      }
    }

    final List<ProductComparison> result = [];
    for (var entry in grouped.entries) {
      final rawList = entry.value;

      // Deduplica cotações por supermercado (mantendo a cotação mais recente de cada mercado)
      final Map<String, CommunityPrice> byMarket = {};
      rawList.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      for (var p in rawList) {
        final mKey = p.supermarketName.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
        if (!byMarket.containsKey(mKey)) {
          byMarket[mKey] = p;
        }
      }

      final list = byMarket.values.toList();
      list.sort((a, b) => a.price.compareTo(b.price));
      if (list.isEmpty) continue;

      double sum = 0;
      for (var p in list) {
        sum += p.price;
      }

      final minPrice = list.first.price;
      final maxPrice = list.last.price;
      final avgPrice = sum / list.length;
      final cheapest = list.first;
      final mostExpensive = list.last;

      result.add(ProductComparison(
        productName: cheapest.productName.trim(),
        unit: cheapest.unit ?? 'un',
        averagePrice: avgPrice,
        minPrice: minPrice,
        maxPrice: maxPrice,
        cheapestMarket: cheapest.supermarketName.trim(),
        cheapestMarketDistance: cheapest.distanceMeters,
        mostExpensiveMarket: mostExpensive.supermarketName.trim(),
        totalQuotes: list.length,
        prices: list,
      ));
    }

    // Ordena alfabeticamente pelo nome do produto
    result.sort((a, b) => a.productName.toLowerCase().compareTo(b.productName.toLowerCase()));
    return result;
  }

  /// Retorna o SQL para criar a tabela no Supabase com 1 clique
  String getSupabaseSetupSql() {
    return r'''
-- CARRIN v1.3.580: execute in Supabase SQL Editor.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE IF NOT EXISTS public.community_prices (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  event_id text,
  product_name text NOT NULL,
  category text,
  unit text NOT NULL DEFAULT 'un',
  price numeric(10,2) NOT NULL,
  supermarket_name text NOT NULL,
  latitude double precision,
  longitude double precision,
  submitted_by text DEFAULT 'Cliente CARRIN',
  verified_receipt boolean DEFAULT false,
  created_at timestamptz DEFAULT timezone('utc'::text, now()) NOT NULL,
  CONSTRAINT chk_community_price_positive CHECK (price > 0 AND price <= 50000),
  CONSTRAINT chk_community_coords_valid CHECK ((latitude IS NULL OR latitude BETWEEN -90.0 AND 90.0) AND (longitude IS NULL OR longitude BETWEEN -180.0 AND 180.0)),
  CONSTRAINT chk_community_name_length CHECK (length(trim(product_name)) BETWEEN 1 AND 200),
  CONSTRAINT chk_community_market_length CHECK (length(trim(supermarket_name)) BETWEEN 1 AND 200),
  CONSTRAINT chk_community_unit_valid CHECK (unit IN ('un', 'kg', 'g', 'l', 'ml', 'cx', 'pct', 'dz'))
);

ALTER TABLE public.community_prices ADD COLUMN IF NOT EXISTS event_id text;

-- Saneamento e restrição NOT NULL na coluna unit
UPDATE public.community_prices SET unit = 'un' WHERE unit IS NULL;
ALTER TABLE public.community_prices ALTER COLUMN unit SET DEFAULT 'un';
ALTER TABLE public.community_prices ALTER COLUMN unit SET NOT NULL;

DO $$ BEGIN ALTER TABLE public.community_prices ADD CONSTRAINT chk_community_price_positive CHECK (price > 0 AND price <= 50000); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER TABLE public.community_prices ADD CONSTRAINT chk_community_coords_valid CHECK ((latitude IS NULL OR latitude BETWEEN -90.0 AND 90.0) AND (longitude IS NULL OR longitude BETWEEN -180.0 AND 180.0)); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER TABLE public.community_prices ADD CONSTRAINT chk_community_name_length CHECK (length(trim(product_name)) BETWEEN 1 AND 200); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER TABLE public.community_prices ADD CONSTRAINT chk_community_market_length CHECK (length(trim(supermarket_name)) BETWEEN 1 AND 200); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN ALTER TABLE public.community_prices ADD CONSTRAINT chk_community_unit_valid CHECK (unit IN ('un', 'kg', 'g', 'l', 'ml', 'cx', 'pct', 'dz')); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS idx_community_product ON public.community_prices(product_name);
CREATE INDEX IF NOT EXISTS idx_community_market ON public.community_prices(supermarket_name);
CREATE INDEX IF NOT EXISTS idx_community_created ON public.community_prices(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_community_product_trgm ON public.community_prices USING gin (product_name gin_trgm_ops);

-- Remove versão parcial anterior (se houver) para garantir que o PostgREST infira on_conflict=event_id:
DROP INDEX IF EXISTS public.idx_community_prices_event_id_unique;
CREATE UNIQUE INDEX IF NOT EXISTS idx_community_prices_event_id_unique ON public.community_prices(event_id);

ALTER TABLE public.community_prices ENABLE ROW LEVEL SECURITY;

-- Revoga explicitamente de PUBLIC (todos os papéis herdados), além de anon e authenticated:
REVOKE ALL ON TABLE public.community_prices FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT ON TABLE public.community_prices TO anon, authenticated;

DROP POLICY IF EXISTS "Permitir leitura pública" ON public.community_prices;
DROP POLICY IF EXISTS "Permitir inserção pública" ON public.community_prices;
DROP POLICY IF EXISTS "Enable read access for all users" ON public.community_prices;
DROP POLICY IF EXISTS "Enable insert for all users" ON public.community_prices;

CREATE POLICY "Permitir leitura pública" ON public.community_prices FOR SELECT TO anon, authenticated USING (true);
CREATE POLICY "Permitir inserção pública" ON public.community_prices FOR INSERT TO anon, authenticated WITH CHECK (verified_receipt IS NOT TRUE);
''';
  }
}
