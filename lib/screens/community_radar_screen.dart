import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/community_price.dart';
import '../models/item.dart';
import '../providers/item_provider.dart';
import '../services/community_price_service.dart';
import '../services/default_supermarkets.dart';
import '../services/location_service.dart';
import '../services/utils.dart';
import 'market_map_screen.dart';

class CommunityRadarScreen extends StatefulWidget {
  const CommunityRadarScreen({super.key});

  @override
  State<CommunityRadarScreen> createState() => _CommunityRadarScreenState();
}

class _CommunityRadarScreenState extends State<CommunityRadarScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _marketSearchController = TextEditingController();

  double _radiusKm = 25.0;
  bool _isLoading = false;
  bool _isSyncingBackground = false;
  double? _userLat;
  double? _userLng;

  List<MarketComparison> _marketRankings = [];
  List<MarketComparison> _allCatalogMarkets = [];
  List<CommunityPrice> _recentFeed = [];
  List<ProductComparison> _allComparisons = [];
  ProductComparison? _searchedProduct;
  String _selectedMarketFilter = 'Todos';
  String _selectedChainFilter = 'Todas';
  final Set<String> _confirmedPriceIds = {};
  final Map<String, int> _confirmationsCount = {};

  int _getConfirmations(CommunityPrice item) {
    final base = (item.id.hashCode.abs() % 4) + (item.verifiedReceipt ? 3 : 1);
    final extra = _confirmationsCount[item.id] ?? 0;
    return base + extra;
  }

  void _toggleConfirmPrice(CommunityPrice item) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_confirmedPriceIds.contains(item.id)) {
        _confirmedPriceIds.remove(item.id);
        _confirmationsCount[item.id] = (_confirmationsCount[item.id] ?? 1) - 1;
      } else {
        _confirmedPriceIds.add(item.id);
        _confirmationsCount[item.id] = (_confirmationsCount[item.id] ?? 0) + 1;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.thumb_up_rounded, color: Colors.greenAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('Preço de "${item.productName}" confirmado por você!')),
              ],
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    });
  }

  Future<void> _addItemToShoppingList(CommunityPrice item, ItemProvider provider) async {
    HapticFeedback.mediumImpact();
    final newItem = Item(
      name: item.productName,
      quantity: 1,
      unitPrice: item.price,
      isKg: item.unit?.toLowerCase() == 'kg',
      category: item.category ?? 'Outros',
      supermarket: item.supermarketName,
      isBought: false,
    );

    await provider.addItem(newItem);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${item.productName} adicionado à sua lista de compras!',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  void _sharePrice(CommunityPrice item) {
    HapticFeedback.lightImpact();
    final priceStr = Utils.formatCurrency(item.price);
    final unitStr = item.unit != null ? '/${item.unit}' : '';
    final nfStr = item.verifiedReceipt ? ' (Comprovado com Nota Fiscal 🧾)' : '';
    final text = '🛒 *Oferta encontrada no CARRIN!*\n\n'
        '📦 *${item.productName}*\n'
        '💰 *Preço:* $priceStr $unitStr$nfStr\n'
        '📍 *Onde:* ${item.supermarketName}\n\n'
        '📲 Economize também usando o app CARRIN!';
    Share.share(text, subject: 'Oferta: ${item.productName}');
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadLocationAndData(forceCloudRefresh: false);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    _marketSearchController.dispose();
    super.dispose();
  }

  /// Carrega instantaneamente os dados do cache SQLite local (< 20ms) e atualiza GPS/nuvem em segundo plano
  Future<void> _loadLocationAndData({bool forceCloudRefresh = false}) async {
    if (_recentFeed.isEmpty && _marketRankings.isEmpty) {
      setState(() => _isLoading = true);
    } else {
      setState(() => _isSyncingBackground = true);
    }

    // 1. Leitura local imediata (sem bloquear esperando GPS ou rede)
    try {
      await _fetchDataFromCache();
    } catch (_) {}

    if (mounted) {
      setState(() => _isLoading = false);
    }

    // 2. Atualização em segundo plano (GPS + Nuvem Supabase)
    _refreshGpsAndCloudInBackground(forceCloudRefresh: forceCloudRefresh);
  }

  Future<void> _refreshGpsAndCloudInBackground({bool forceCloudRefresh = false}) async {
    if (mounted) {
      setState(() => _isSyncingBackground = true);
    }

    bool gpsUpdated = false;
    try {
      final pos = await LocationService.instance.getCurrentPosition();
      if (pos != null) {
        final oldLat = _userLat;
        final oldLng = _userLng;
        _userLat = pos.latitude;
        _userLng = pos.longitude;
        if (oldLat == null ||
            oldLng == null ||
            LocationService.instance.calculateDistance(oldLat, oldLng, pos.latitude, pos.longitude) > 50) {
          gpsUpdated = true;
        }
      }
    } catch (_) {}

    final lat = _userLat ?? CommunityPriceService.defaultStoreLat;
    final lng = _userLng ?? CommunityPriceService.defaultStoreLng;

    try {
      await CommunityPriceService.instance.syncFromCloud(
        userLat: lat,
        userLng: lng,
        force: forceCloudRefresh,
      );
    } catch (_) {}

    try {
      if (mounted) {
        await _fetchDataFromCache();
      } else if (gpsUpdated && mounted) {
        await _fetchDataFromCache();
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _isSyncingBackground = false);
    }
  }

  /// Lê o feed uma única vez do SQLite e deriva Mercados e Comparações em memória (zero chamadas duplicadas!)
  Future<void> _fetchDataFromCache() async {
    try {
      final lat = _userLat ?? CommunityPriceService.defaultStoreLat;
      final lng = _userLng ?? CommunityPriceService.defaultStoreLng;

      // 1. Lê todos os preços locais em raio amplo de 50km
      final allPrices50km = await CommunityPriceService.instance.getRecentFeed(
        userLat: lat,
        userLng: lng,
        radiusKm: 50.0,
        syncWithCloud: false,
      );

      final maxMeters = _radiusKm * 1000;
      // Filtra o feed respeitando o raio ativo, exceto se um mercado específico foi selecionado
      final feed = allPrices50km.where((p) {
        if (_selectedMarketFilter != 'Todos') {
          return p.supermarketName.toLowerCase() == _selectedMarketFilter.toLowerCase() ||
                 DefaultSupermarketsData.matchesSearch(p.supermarketName, _selectedMarketFilter);
        }
        if (p.distanceMeters == null) return true;
        return p.distanceMeters! <= maxMeters;
      }).toList();

      // 2. Calcula os mercados do raio reutilizando os preços dentro do raio
      final markets = await CommunityPriceService.instance.getCheapestMarketsNearby(
        userLat: lat,
        userLng: lng,
        radiusKm: _radiusKm,
        preloadedPrices: allPrices50km.where((p) => p.distanceMeters == null || p.distanceMeters! <= maxMeters).toList(),
        syncWithCloud: false,
      );

      // Carrega catálogo completo com todos os preços de 50km
      final allCatalog = await CommunityPriceService.instance.getCheapestMarketsNearby(
        userLat: lat,
        userLng: lng,
        radiusKm: 50.0,
        preloadedPrices: allPrices50km,
        syncWithCloud: false,
      );

      // 3. Calcula todas as comparações de produtos
      final allComps = await CommunityPriceService.instance.getAllProductComparisons(
        userLat: lat,
        userLng: lng,
        radiusKm: _radiusKm,
        preloadedPrices: feed,
        syncWithCloud: false,
      );

      ProductComparison? prodComp;
      if (_searchController.text.trim().isNotEmpty) {
        prodComp = await CommunityPriceService.instance.getProductComparison(
          _searchController.text.trim(),
          userLat: lat,
          userLng: lng,
          radiusKm: _radiusKm,
          preloadedPrices: allPrices50km,
          syncWithCloud: false,
        );
      }

      if (mounted) {
        setState(() {
          _recentFeed = feed;
          _marketRankings = markets;
          _allCatalogMarkets = allCatalog;
          _allComparisons = allComps;
          if (prodComp != null) {
            _searchedProduct = prodComp;
          }
        });
      }
    } catch (_) {}
  }

  void _onSearchChanged(String val) async {
    final lat = _userLat ?? CommunityPriceService.defaultStoreLat;
    final lng = _userLng ?? CommunityPriceService.defaultStoreLng;

    if (val.trim().isEmpty) {
      setState(() {
        _searchedProduct = null;
      });
      return;
    }

    final comp = await CommunityPriceService.instance.getProductComparison(
      val.trim(),
      userLat: lat,
      userLng: lng,
      radiusKm: _radiusKm,
      preloadedPrices: _recentFeed,
      syncWithCloud: false,
    );

    if (mounted) {
      setState(() => _searchedProduct = comp);
    }
  }

  Future<void> _openMapScreen({String? focusMarket, String? chainFilter}) async {
    final selectedMarket = await Navigator.push<String?>(
      context,
      MaterialPageRoute(
        builder: (_) => MarketMapScreen(
          initialUserLat: _userLat,
          initialUserLng: _userLng,
          initialRadiusKm: _radiusKm,
          initialFocusMarket: focusMarket,
          initialChainFilter: chainFilter ?? (_selectedChainFilter != 'Todas' ? _selectedChainFilter : null),
        ),
      ),
    );

    if (selectedMarket != null && mounted) {
      setState(() {
        _selectedMarketFilter = selectedMarket;
        _tabController.animateTo(0);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final cardColor = Theme.of(context).cardColor;
    final itemProvider = Provider.of<ItemProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.radar_rounded, size: 24),
            const SizedBox(width: 8),
            const Text('Radar de Preços', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            if (_isSyncingBackground) ...[
              const SizedBox(width: 10),
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: primaryColor),
              ),
            ],
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: 'Mapa dos Mercados',
            onPressed: () => _openMapScreen(),
          ),
          PopupMenuButton<double>(
            icon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.near_me_outlined, size: 16, color: primaryColor),
                const SizedBox(width: 4),
                Text(
                  '${_radiusKm.toInt()}km',
                  style: TextStyle(color: primaryColor, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ],
            ),
            tooltip: 'Raio de Busca (GPS)',
            onSelected: (val) {
              setState(() => _radiusKm = val);
              _fetchDataFromCache();
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 5.0, child: Text('Raio de 5 km')),
              const PopupMenuItem(value: 10.0, child: Text('Raio de 10 km')),
              const PopupMenuItem(value: 15.0, child: Text('Raio de 15 km')),
              const PopupMenuItem(value: 25.0, child: Text('Raio de 25 km')),
              const PopupMenuItem(value: 50.0, child: Text('Raio de 50 km')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Atualizar',
            onPressed: () => _loadLocationAndData(forceCloudRefresh: true),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: primaryColor,
          labelColor: primaryColor,
          unselectedLabelColor: Colors.grey,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          tabs: const [
            Tab(icon: Icon(Icons.local_offer_rounded, size: 20), text: 'Ofertas'),

            Tab(icon: Icon(Icons.storefront_rounded, size: 20), text: 'Mercados'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildFeedTab(isDark, cardColor, primaryColor, itemProvider),

                _buildMarketsTab(isDark, cardColor, primaryColor),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddPriceDialog(context, itemProvider),
        backgroundColor: primaryColor,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        icon: const Icon(Icons.post_add_rounded),
        label: const Text('Postar Preço', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  // ==========================================
  // --- ABA 3: MERCADOS (PESQUISA POR NOME E FILTRO POR REDES) ---
  // ==========================================
  Widget _buildMarketsTab(bool isDark, Color cardColor, Color primary) {
    final marketQuery = _marketSearchController.text.trim();
    final hasSearchOrChain = marketQuery.isNotEmpty || _selectedChainFilter != 'Todas';

    // Filtra no raio selecionado; se o usuário pesquisou por nome ou rede e não achou no raio curto, busca no catálogo completo
    List<MarketComparison> filteredMarkets = _marketRankings.where((m) {
      if (!DefaultSupermarketsData.matchesChain(m.supermarketName, _selectedChainFilter)) {
        return false;
      }
      if (marketQuery.isNotEmpty && !DefaultSupermarketsData.matchesSearch(m.supermarketName, marketQuery)) {
        return false;
      }
      return true;
    }).toList();

    if (filteredMarkets.isEmpty && hasSearchOrChain) {
      filteredMarkets = _allCatalogMarkets.where((m) {
        if (!DefaultSupermarketsData.matchesChain(m.supermarketName, _selectedChainFilter)) {
          return false;
        }
        if (marketQuery.isNotEmpty && !DefaultSupermarketsData.matchesSearch(m.supermarketName, marketQuery)) {
          return false;
        }
        return true;
      }).toList();
    }

    final cheapest = _marketRankings.isNotEmpty
        ? _marketRankings.firstWhere((m) => m.isCheapest, orElse: () => _marketRankings.first)
        : null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Barra de Pesquisa de Mercados pelo Nome ou Bairro
                  TextField(
                    controller: _marketSearchController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Pesquisar mercado pelo nome ou bairro...',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _marketSearchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded),
                              onPressed: () {
                                _marketSearchController.clear();
                                FocusScope.of(context).unfocus();
                                setState(() {});
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: cardColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                const SizedBox(height: 10),

                // 2. Filtro Horizontal por Redes de Supermercados
                SizedBox(
                  height: 38,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: DefaultSupermarketsData.mainChains.length,
                    itemBuilder: (context, idx) {
                      final chain = DefaultSupermarketsData.mainChains[idx];
                      final isSelected = _selectedChainFilter == chain;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(chain == 'Todas' ? 'Todas as Redes' : chain),
                          selected: isSelected,
                          showCheckmark: false,
                          selectedColor: primary,
                          labelStyle: TextStyle(
                            fontSize: 12.5,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                          ),
                          onSelected: (_) {
                            setState(() {
                              _selectedChainFilter =
                                  (_selectedChainFilter == chain && chain != 'Todas') ? 'Todas' : chain;
                            });
                          },
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 14),

                // Card do Mercado Campeão em Economia (quando não está filtrando busca específica)
                if (cheapest != null && cheapest.itemsCount > 0 && !hasSearchOrChain) ...[
                  InkWell(
                    onTap: () => _openMapScreen(focusMarket: cheapest.supermarketName),
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [primary, primary.withValues(alpha: 0.8)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text('🏆 ', style: TextStyle(fontSize: 14)),
                                    Text(
                                      'MAIS ECONÔMICO DA REGIÃO',
                                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                              if (cheapest.formattedDistance.isNotEmpty)
                                Text(
                                  '📍 ${cheapest.formattedDistance}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            cheapest.supermarketName,
                            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Preço médio dos itens: ${Utils.formatCurrency(cheapest.averageItemPrice)}',
                            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Lidera como menor preço em ${cheapest.cheapestCount} de ${cheapest.itemsCount} produtos',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              ),
                              const Icon(Icons.touch_app_rounded, color: Colors.white70, size: 16),
                              const SizedBox(width: 4),
                              const Text(
                                'Ver no mapa',
                                style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _selectedChainFilter == 'Todas'
                          ? 'Supermercados Encontrados'
                          : 'Rede $_selectedChainFilter',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${filteredMarkets.length} lojas',
                      style: TextStyle(fontSize: 12, color: primary, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        if (filteredMarkets.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.store_outlined, size: 56, color: Colors.grey[400]),
                    const SizedBox(height: 12),
                    const Text(
                      'Nenhum supermercado encontrado para este filtro.',
                      style: TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
            sliver: SliverList.builder(
              itemCount: filteredMarkets.length,
              itemBuilder: (context, idx) {
                final market = filteredMarkets[idx];
                final isBest = market.isCheapest && market.itemsCount > 0;
                final pre = DefaultSupermarketsData.findMatch(market.supermarketName);
                final chain = DefaultSupermarketsData.getChainName(market.supermarketName);

                return InkWell(
                  onTap: () => _openMapScreen(focusMarket: market.supermarketName),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(18),
                      border: isBest ? Border.all(color: Colors.greenAccent.shade700, width: 1.5) : null,
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: isBest
                              ? Colors.green.withValues(alpha: 0.15)
                              : primary.withValues(alpha: 0.12),
                          child: Icon(
                            isBest ? Icons.savings_rounded : Icons.storefront_rounded,
                            color: isBest ? Colors.green : primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      market.supermarketName,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (market.formattedDistance.isNotEmpty)
                                    Text(
                                      market.formattedDistance,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: primary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                ],
                              ),
                              if (pre?.address != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  pre!.address!,
                                  style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  if (chain != 'Outras') ...[
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                      margin: const EdgeInsets.only(right: 8),
                                      decoration: BoxDecoration(
                                        color: primary.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        chain,
                                        style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: primary),
                                      ),
                                    ),
                                  ],
                                  if (market.itemsCount > 0) ...[
                                    Text(
                                      'Média: ${Utils.formatCurrency(market.averageItemPrice)}',
                                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '• ${market.itemsCount} itens',
                                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                    ),
                                  ] else
                                    Text(
                                      'Toque para ver no mapa',
                                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (isBest)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              'Menor Preço',
                              style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          )
                        else
                          Icon(Icons.location_on_outlined, size: 18, color: primary),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    ),
  );
}

  // ==========================================
  // --- ABA 1: OFERTAS & FEED SOCIAL UNIFICADO ---
  // ==========================================
  Widget _buildFeedTab(bool isDark, Color cardColor, Color primary, ItemProvider provider) {
    // 1. Mercados disponiveis para filtro rapido em chips
    final List<String> availableMarkets = ['Todos'];
    final Set<String> seenMarkets = {};
    for (var m in _marketRankings) {
      if (m.itemsCount <= 0) continue;
      final name = m.supermarketName.trim();
      if (name.isNotEmpty && !seenMarkets.contains(name.toLowerCase())) {
        seenMarkets.add(name.toLowerCase());
        availableMarkets.add(name);
      }
    }
    for (var p in _recentFeed) {
      final name = p.supermarketName.trim();
      if (name.isNotEmpty && !seenMarkets.contains(name.toLowerCase())) {
        seenMarkets.add(name.toLowerCase());
        availableMarkets.add(name);
      }
    }
    if (!seenMarkets.contains(CommunityPriceService.defaultStoreName.toLowerCase())) {
      availableMarkets.add(CommunityPriceService.defaultStoreName);
    }
    if (_selectedMarketFilter != 'Todos' && !seenMarkets.contains(_selectedMarketFilter.toLowerCase())) {
      availableMarkets.add(_selectedMarketFilter);
    }

    // 2. Filtro de mercado e busca
    final query = _searchController.text.trim().toLowerCase();
    List<CommunityPrice> displayedFeed = _recentFeed;

    if (_selectedMarketFilter != 'Todos') {
      final filter = _selectedMarketFilter.toLowerCase();
      displayedFeed = displayedFeed.where((p) =>
        p.supermarketName.toLowerCase() == filter ||
        DefaultSupermarketsData.matchesSearch(p.supermarketName, filter)
      ).toList();
    }

    if (query.isNotEmpty) {
      displayedFeed = displayedFeed.where((p) => p.productName.toLowerCase().contains(query)).toList();
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).unfocus(),
      child: RefreshIndicator(
        onRefresh: () => _loadLocationAndData(forceCloudRefresh: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Barra de Pesquisa Integrada
                    TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => FocusScope.of(context).unfocus(),
                      onChanged: _onSearchChanged,
                      decoration: InputDecoration(
                        hintText: 'Pesquise um produto (ex: Arroz, Leite, Café)...',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded),
                                onPressed: () {
                                  _searchController.clear();
                                  _onSearchChanged('');
                                  FocusScope.of(context).unfocus();
                                },
                              )
                            : null,
                        filled: true,
                        fillColor: cardColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Filtros Rapidos por Mercado
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: availableMarkets.map((market) {
                          final isSelected = _selectedMarketFilter == market;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              avatar: Icon(
                                market == 'Todos' ? Icons.store_mall_directory_outlined : Icons.storefront_rounded,
                                size: 16,
                                color: isSelected ? Colors.white : primary,
                              ),
                              label: Text(market == 'Todos' ? 'Todos os Mercados' : market),
                              selected: isSelected,
                              selectedColor: primary,
                              labelStyle: TextStyle(
                                color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                fontSize: 12.5,
                              ),
                              onSelected: (selected) {
                                FocusScope.of(context).unfocus();
                                setState(() {
                                  _selectedMarketFilter = selected ? market : 'Todos';
                                });
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Card de Comparacao Inteligente (quando ha busca ativa)
                    if (_searchedProduct != null) ...[
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: primary.withValues(alpha: 0.35), width: 1.5),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    _searchedProduct!.productName,
                                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close_rounded, size: 20),
                                  tooltip: 'Fechar detalhes',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () {
                                    setState(() {
                                      _searchedProduct = null;
                                      _searchController.clear();
                                      _onSearchChanged('');
                                    });
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _searchedProduct!.maxSavingsPercent > 0
                                    ? 'Economia de até ${_searchedProduct!.maxSavingsPercent.toStringAsFixed(0)}%'
                                    : 'Melhor Preço Registrado',
                                style: const TextStyle(color: Colors.green, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: [
                                _buildStatBox('Média', Utils.formatCurrency(_searchedProduct!.averagePrice), Colors.blueAccent),
                                const SizedBox(width: 8),
                                _buildStatBox('Menor Preço', Utils.formatCurrency(_searchedProduct!.minPrice), Colors.green),
                                const SizedBox(width: 8),
                                _buildStatBox('Maior Preço', Utils.formatCurrency(_searchedProduct!.maxPrice), Colors.redAccent),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '💡 Mais vantajoso em: ${_searchedProduct!.cheapestMarket}',
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green.shade600, fontSize: 13),
                            ),
                            const SizedBox(height: 14),
                            const Text('Preços por Supermercado:', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            ..._buildGroupedMarketCards(_searchedProduct!, cardColor),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],

                    // Cabecalho da Lista
                    Row(
                      children: [
                        Icon(Icons.near_me_rounded, size: 14, color: primary),
                        const SizedBox(width: 4),
                        Text(
                          'No seu raio de ${_radiusKm.toInt()} km',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${displayedFeed.length} ofertas',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: primary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),

            if (displayedFeed.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          query.isNotEmpty ? Icons.search_off_rounded : Icons.dynamic_feed_rounded,
                          size: 48,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 14),
                        Text(
                          query.isNotEmpty
                              ? 'Nenhuma oferta encontrada para "$query"'
                              : 'Nenhuma oferta no seu feed ainda',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          query.isNotEmpty
                              ? 'Tente buscar por outro termo ou compartilhe você mesmo o preço que encontrou!'
                              : 'Puxe para atualizar ou seja o primeiro a postar uma oferta no raio de ${_radiusKm.toInt()} km!',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: isDark ? Colors.white60 : Colors.black54),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => _showAddPriceDialog(context, provider),
                          icon: const Icon(Icons.post_add_rounded),
                          label: const Text('Postar Oferta'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                sliver: SliverList.builder(
                  itemCount: displayedFeed.length,
                  itemBuilder: (context, idx) {
                    final item = displayedFeed[idx];

                    // Calcula economia se houver dados medios da regiao
                    ProductComparison? comp;
                    for (final c in _allComparisons) {
                      if (c.productName.toLowerCase() == item.productName.toLowerCase()) {
                        comp = c;
                        break;
                      }
                    }

                    int? savingsPct;
                    if (comp != null && comp.averagePrice > item.price && comp.averagePrice > 0) {
                      final s = ((comp.averagePrice - item.price) / comp.averagePrice * 100).round();
                      if (s >= 5) {
                        savingsPct = s;
                      }
                    }

                    final isConfirmed = _confirmedPriceIds.contains(item.id);
                    final confirmCount = _getConfirmations(item);

                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      color: cardColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.07),
                          width: 1,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 1. Autor, Verificacao e Tempo
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: item.verifiedReceipt
                                      ? Colors.blueAccent.withValues(alpha: 0.15)
                                      : primary.withValues(alpha: 0.12),
                                  child: Text(
                                    (item.submittedBy.isNotEmpty ? item.submittedBy[0] : 'C').toUpperCase(),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: item.verifiedReceipt ? Colors.blueAccent : primary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              item.submittedBy.isNotEmpty ? item.submittedBy : 'Membro da Comunidade',
                                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (item.verifiedReceipt) ...[
                                            const SizedBox(width: 4),
                                            const Icon(Icons.verified_rounded, size: 14, color: Colors.blueAccent),
                                          ],
                                        ],
                                      ),
                                      Text(
                                        Utils.formatTimeAgo(item.createdAt),
                                        style: TextStyle(fontSize: 11, color: isDark ? Colors.white54 : Colors.black45),
                                      ),
                                    ],
                                  ),
                                ),
                                if (item.verifiedReceipt)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.blueAccent.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'Cupom Fiscal',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.blueAccent,
                                      ),
                                    ),
                                  ),
                                IconButton(
                                  icon: const Icon(Icons.share_outlined, size: 18),
                                  tooltip: 'Compartilhar no WhatsApp',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _sharePrice(item),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            // 2. Produto e Preco (Hero)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        item.productName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15.5,
                                          height: 1.25,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      InkWell(
                                        onTap: () => _openMapScreen(focusMarket: item.supermarketName),
                                        borderRadius: BorderRadius.circular(6),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.location_on_outlined, size: 14, color: primary),
                                            const SizedBox(width: 3),
                                            Flexible(
                                              child: Text(
                                                item.supermarketName,
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w600,
                                                  color: isDark ? Colors.white70 : Colors.black87,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            if (item.formattedDistance.isNotEmpty) ...[
                                              const SizedBox(width: 4),
                                              Text(
                                                '• ${item.formattedDistance}',
                                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: primary),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      Utils.formatCurrency(item.price),
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                    Text(
                                      '/ ${item.unit ?? "un"}',
                                      style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                    ),
                                    if (savingsPct != null) ...[
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          '-$savingsPct% vs média',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.green.shade700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            // 3. Acoes Sociais (Confirmar + Minha Lista)
                            Divider(
                              height: 14,
                              thickness: 0.6,
                              color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
                            ),
                            Row(
                              children: [
                                // Confirmar Preco
                                InkWell(
                                  onTap: () => _toggleConfirmPrice(item),
                                  borderRadius: BorderRadius.circular(8),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          isConfirmed ? Icons.thumb_up_rounded : Icons.thumb_up_alt_outlined,
                                          size: 15,
                                          color: isConfirmed ? Colors.green : Colors.grey[600],
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          isConfirmed ? 'Confirmado ($confirmCount)' : 'Confirmar ($confirmCount)',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: isConfirmed ? FontWeight.bold : FontWeight.w500,
                                            color: isConfirmed ? Colors.green : (isDark ? Colors.white70 : Colors.black87),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const Spacer(),

                                // Adicionar a Lista de Compras
                                TextButton.icon(
                                  onPressed: () => _addItemToShoppingList(item, provider),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  icon: Icon(Icons.add_shopping_cart_rounded, size: 15, color: primary),
                                  label: Text(
                                    '+ Minha Lista',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primary),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }


  List<Widget> _buildGroupedMarketCards(ProductComparison prod, Color cardColor) {
    final Map<String, List<CommunityPrice>> marketGroups = {};
    for (var p in prod.prices) {
      final mName = p.supermarketName.trim();
      if (mName.isNotEmpty) {
        marketGroups.putIfAbsent(mName, () => []).add(p);
      }
    }

    if (marketGroups.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Nenhum supermercado registrado com preço para este produto.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      ];
    }

    final List<Widget> widgets = [];
    for (var entry in marketGroups.entries) {
      final marketName = entry.key;
      final quotes = entry.value;

      quotes.sort((a, b) => a.price.compareTo(b.price));
      final lowest = quotes.first;
      final highest = quotes.last;
      final isBest = lowest.price <= prod.minPrice;
      final hasVariation = quotes.length > 1 && (highest.price - lowest.price).abs() > 0.01;

      quotes.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final latest = quotes.first;

      widgets.add(
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(14),
            border: isBest ? Border.all(color: Colors.green, width: 1.5) : null,
          ),
          child: Row(
            children: [
              Icon(
                isBest ? Icons.check_circle_rounded : Icons.store_rounded,
                color: isBest ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      marketName,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (latest.formattedDistance.isNotEmpty)
                          Text(
                            '📍 ${latest.formattedDistance} • ',
                            style: TextStyle(color: Colors.grey[500], fontSize: 11),
                          ),
                        Text(
                          quotes.length > 1
                              ? '${quotes.length} compras registradas'
                              : Utils.formatDate(latest.createdAt),
                          style: TextStyle(color: Colors.grey[500], fontSize: 11),
                        ),
                        if (quotes.any((q) => q.verifiedReceipt)) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.verified_rounded, size: 12, color: Colors.blueAccent),
                          const Text(
                            ' NF',
                            style: TextStyle(color: Colors.blueAccent, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ],
                    ),
                    if (hasVariation) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Variação: ${Utils.formatCurrency(lowest.price)} a ${Utils.formatCurrency(highest.price)}',
                        style: TextStyle(color: Colors.grey[600], fontSize: 10.5, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    Utils.formatCurrency(lowest.price),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isBest ? Colors.green : null,
                    ),
                  ),
                  Text(
                    quotes.length > 1 ? 'menor preço' : '/ ${lowest.unit ?? "un"}',
                    style: TextStyle(fontSize: 10.5, color: Colors.grey[500]),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return widgets;
  }

  Widget _buildStatBox(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // --- MODAL DE COLABORAÇÃO DE PREÇO ---
  // ==========================================
  void _showAddPriceDialog(BuildContext context, ItemProvider provider) {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final marketCtrl = TextEditingController(
      text: provider.detectedSupermarket?['name'] ??
          provider.selectedSupermarketFilter ??
          CommunityPriceService.defaultStoreName,
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Row(
          children: [
            Icon(Icons.add_shopping_cart_rounded, color: Colors.green),
            SizedBox(width: 10),
            Text('Colaborar com Preço', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Nome do Produto (ex: Leite Integral 1L)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: priceCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [CurrencyInputFormatter()],
              decoration: const InputDecoration(labelText: 'Preço (R\$)', prefixText: 'R\$ ', hintText: '0,00'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: marketCtrl,
              decoration: const InputDecoration(labelText: 'Supermercado'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final price = Utils.parseCurrency(priceCtrl.text);
              final market = marketCtrl.text.trim();

              if (name.isNotEmpty && price > 0 && market.isNotEmpty) {
                Navigator.pop(ctx);
                await CommunityPriceService.instance.publishPrice(
                  productName: name,
                  price: price,
                  supermarketName: market,
                  latitude: _userLat,
                  longitude: _userLng,
                  submittedBy: provider.activeUserDisplayName,
                  verifiedReceipt: false,
                );
                _fetchDataFromCache();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Obrigado! Seu preço foi compartilhado com a comunidade.')),
                  );
                }
              }
            },
            child: const Text('Publicar'),
          ),
        ],
      ),
    );
  }
}
