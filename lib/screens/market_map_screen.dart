import '../widgets/pulsing_user_location_marker.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/community_price.dart';
import '../services/community_price_service.dart';
import '../services/location_service.dart';
import '../services/utils.dart';
import '../services/default_supermarkets.dart';

/// Estilos visuais de mapa disponíveis para escolha do usuário (estilo Google Maps)
enum MapTileStyle {
  googleStandard,
  googleClean,
  googleHybrid,
  googleTerrain,
  osmStandard,
  darkNight,
}

class MarketMapScreen extends StatefulWidget {
  final double? initialUserLat;
  final double? initialUserLng;
  final double initialRadiusKm;
  final String? initialFocusMarket;
  final String? initialChainFilter;

  const MarketMapScreen({
    super.key,
    this.initialUserLat,
    this.initialUserLng,
    this.initialRadiusKm = 15.0,
    this.initialFocusMarket,
    this.initialChainFilter,
  });

  @override
  State<MarketMapScreen> createState() => _MarketMapScreenState();
}

class _MarketMapScreenState extends State<MarketMapScreen> {
  static const String _prefMapStyleKey = 'market_map_tile_style';

  final MapController _mapController = MapController();
  late PageController _cardsPageController;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  StreamSubscription<Position>? _gpsStreamSubscription;

  double _radiusKm = 15.0;
  bool _isLoading = true;
  LatLng _userPosition = const LatLng(
    CommunityPriceService.defaultStoreLat,
    CommunityPriceService.defaultStoreLng,
  );
  bool _hasRealGps = false;
  bool _isFollowingUser = false;
  double? _userHeading;
  double? _userAccuracy;
  double? _userSpeed;

  List<MarketComparison> _allLoadedMarkets = [];
  List<MarketComparison> _filteredMarkets = [];
  MarketComparison? _selectedMarket;
  List<CommunityPrice> _selectedMarketDeals = [];
  bool _isLoadingDeals = false;

  String _selectedChain = 'Todas';
  String _searchQuery = '';
  bool _showSearchSuggestions = false;
  bool _showRadiusCircle = true;
  bool _showMarketPins = true;
  bool _pickOnMapMode = false;
  LatLng? _pickedMapPoint;
  MapTileStyle _mapTileStyle = MapTileStyle.googleStandard;

  @override
  void initState() {
    super.initState();
    _radiusKm = widget.initialRadiusKm;
    if (widget.initialChainFilter != null && widget.initialChainFilter!.isNotEmpty) {
      _selectedChain = widget.initialChainFilter!;
    }
    _cardsPageController = PageController(viewportFraction: 0.88);

    if (widget.initialUserLat != null && widget.initialUserLng != null) {
      _userPosition = LatLng(widget.initialUserLat!, widget.initialUserLng!);
      _hasRealGps = true;
    }

    _searchFocusNode.addListener(() {
      if (mounted) {
        setState(() {
          _showSearchSuggestions = _searchFocusNode.hasFocus && _searchQuery.isNotEmpty;
        });
      }
    });

    _loadSavedMapStyle();
    _initMapAndLoadData();
  }

  Future<void> _loadSavedMapStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefMapStyleKey);
      if (saved != null && mounted) {
        for (final s in MapTileStyle.values) {
          if (s.name == saved) {
            setState(() => _mapTileStyle = s);
            break;
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _setMapStyle(MapTileStyle style) async {
    setState(() => _mapTileStyle = style);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefMapStyleKey, style.name);
    } catch (_) {}
  }

  @override
  void dispose() {
    _gpsStreamSubscription?.cancel();
    _cardsPageController.dispose();
    _mapController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Color _parseColorHex(String? hex, Color fallback) {
    if (hex == null || hex.isEmpty) return fallback;
    try {
      final clean = hex.replaceAll('#', '');
      if (clean.length == 6) {
        return Color(int.parse('FF$clean', radix: 16));
      }
    } catch (_) {}
    return fallback;
  }

  void _startGpsLiveTracking() {
    _gpsStreamSubscription?.cancel();
    _gpsStreamSubscription = LocationService.instance.getPositionStream(distanceFilter: 2).listen(
      (pos) {
        if (!mounted) return;
        final newPos = LatLng(pos.latitude, pos.longitude);
        final distanceMoved = LocationService.instance.calculateDistance(
          _userPosition.latitude,
          _userPosition.longitude,
          newPos.latitude,
          newPos.longitude,
        );

        _userHeading = (pos.heading > 0 && pos.heading <= 360) ? pos.heading : _userHeading;
        _userAccuracy = pos.accuracy > 0 ? pos.accuracy : _userAccuracy;
        _userSpeed = pos.speed >= 0 ? pos.speed : _userSpeed;

        if (distanceMoved > 1.5 || !_hasRealGps) {
          _userPosition = newPos;
          _hasRealGps = true;

          // Se o modo seguir estiver ativado, move a câmera para a posição do usuário suavemente
          if (_isFollowingUser) {
            _mapController.move(_userPosition, _mapController.camera.zoom);
          }

          // Atualiza as distâncias de todos os mercados em tempo real
          _updateMarketDistances();

          if (distanceMoved > 120.0) {
            _loadMarkets(syncWithCloud: false);
          } else {
            setState(() {});
          }
        }
      },
      onError: (err) {
        debugPrint('📍 Erro no stream do GPS em tempo real: $err');
      },
    );
  }

  void _updateMarketDistances() {
    _allLoadedMarkets = _allLoadedMarkets.map((m) {
      if (m.latitude == null || m.longitude == null) return m;
      final dist = LocationService.instance.calculateDistance(
        _userPosition.latitude,
        _userPosition.longitude,
        m.latitude!,
        m.longitude!,
      );
      return m.copyWith(distanceMeters: dist);
    }).toList();

    _filteredMarkets = _filteredMarkets.map((m) {
      if (m.latitude == null || m.longitude == null) return m;
      final dist = LocationService.instance.calculateDistance(
        _userPosition.latitude,
        _userPosition.longitude,
        m.latitude!,
        m.longitude!,
      );
      return m.copyWith(distanceMeters: dist);
    }).toList();

    if (_selectedMarket != null && _selectedMarket!.latitude != null && _selectedMarket!.longitude != null) {
      final dist = LocationService.instance.calculateDistance(
        _userPosition.latitude,
        _userPosition.longitude,
        _selectedMarket!.latitude!,
        _selectedMarket!.longitude!,
      );
      _selectedMarket = _selectedMarket!.copyWith(distanceMeters: dist);
    }
  }

  Future<void> _initMapAndLoadData({bool forceRefresh = false}) async {
    // 1. Carrega imediatamente os mercados locais sem bloquear no GPS ou rede
    await _loadMarkets(syncWithCloud: forceRefresh);

    if (mounted) {
      setState(() => _isLoading = false);

      if (widget.initialFocusMarket != null && widget.initialFocusMarket!.trim().isNotEmpty) {
        final targetName = widget.initialFocusMarket!.trim();

        // 1. Tenta encontrar no _filteredMarkets (exato ou busca por tokens)
        MarketComparison? match;
        for (final m in _filteredMarkets) {
          if (m.supermarketName.toLowerCase() == targetName.toLowerCase() ||
              DefaultSupermarketsData.matchesSearch(m.supermarketName, targetName)) {
            match = m;
            break;
          }
        }

        // 2. Se não achou em _filteredMarkets, tenta no _allLoadedMarkets
        if (match == null) {
          for (final m in _allLoadedMarkets) {
            if (m.supermarketName.toLowerCase() == targetName.toLowerCase() ||
                DefaultSupermarketsData.matchesSearch(m.supermarketName, targetName)) {
              match = m;
              break;
            }
          }
        }

        // 3. Se ainda não achou, busca no catálogo padrão
        if (match == null) {
          final pre = DefaultSupermarketsData.findMatch(
            targetName,
            userLat: _userPosition.latitude,
            userLng: _userPosition.longitude,
          );
          if (pre != null) {
            MarketComparison? foundInLoaded;
            for (final m in _allLoadedMarkets) {
              if (m.supermarketName.toLowerCase() == pre.name.toLowerCase() ||
                  (m.latitude != null && (m.latitude! - pre.latitude).abs() < 0.001 &&
                   m.longitude != null && (m.longitude! - pre.longitude).abs() < 0.001)) {
                foundInLoaded = m;
                break;
              }
            }

            if (foundInLoaded != null) {
              match = foundInLoaded;
            } else {
              final dist = LocationService.instance.calculateDistance(
                _userPosition.latitude,
                _userPosition.longitude,
                pre.latitude,
                pre.longitude,
              );
              match = MarketComparison(
                supermarketName: pre.name,
                latitude: pre.latitude,
                longitude: pre.longitude,
                distanceMeters: dist,
                itemsCount: 0,
                averageItemPrice: 0.0,
                cheapestCount: 0,
              );
              _allLoadedMarkets.add(match);
            }
          }
        }

        if (match != null) {
          // Se o mercado estiver além do raio atual, expande o raio para exibi-lo no mapa
          if (match.distanceMeters != null && match.distanceMeters! > _radiusKm * 1000) {
            final neededRadius = ((match.distanceMeters! / 1000).ceil() + 5).toDouble();
            if (neededRadius > _radiusKm) {
              _radiusKm = neededRadius;
            }
            _applyFilters(fitCameraIfFiltered: false);
          } else if (!_filteredMarkets.any((m) => m.supermarketName == match!.supermarketName)) {
            _filteredMarkets.insert(0, match);
          }
          _selectMarket(match, openBottomSheet: false);
        } else if (_filteredMarkets.isNotEmpty) {
          _fitAllMarkers();
        }
      }
    }

    // 2. Atualiza o GPS imediatamente e inicia monitoramento contínuo em tempo real
    if (!_hasRealGps || forceRefresh) {
      try {
        final pos = await LocationService.instance.getCurrentPosition();
        if (pos != null && mounted) {
          final newPos = LatLng(pos.latitude, pos.longitude);
          final movedSignificantly = LocationService.instance.calculateDistance(
                _userPosition.latitude,
                _userPosition.longitude,
                newPos.latitude,
                newPos.longitude,
              ) >
              50;
          _userPosition = newPos;
          _hasRealGps = true;
          if (movedSignificantly) {
            await _loadMarkets(syncWithCloud: false);
          } else {
            setState(() {});
          }
        }
      } catch (_) {}
    }

    // Inicia stream contínuo de alta precisão
    _startGpsLiveTracking();
  }

  Future<void> _loadMarkets({bool syncWithCloud = false}) async {
    // Carrega sempre um raio amplo (50km) em memória para permitir busca instantânea por nome/rede,
    // filtrando pelo _radiusKm ativo na camada de exibição.
    final effectiveLoadRadius = _radiusKm > 50.0 ? _radiusKm : 50.0;
    final list = await CommunityPriceService.instance.getCheapestMarketsNearby(
      userLat: _userPosition.latitude,
      userLng: _userPosition.longitude,
      radiusKm: effectiveLoadRadius,
      syncWithCloud: syncWithCloud,
    );

    final withCoords = list.where((m) => m.latitude != null && m.longitude != null).toList();

    if (mounted) {
      _allLoadedMarkets = withCoords;
      _applyFilters(fitCameraIfFiltered: false);
    }
  }

  void _applyFilters({bool fitCameraIfFiltered = false}) {
    final maxMeters = _radiusKm * 1000;
    final hasSearch = _searchQuery.trim().isNotEmpty;
    final hasActiveSearchOrChain = hasSearch || _selectedChain != 'Todas';

    // 1. Filtra por rede, busca por nome e raio
    List<MarketComparison> result = _allLoadedMarkets.where((m) {
      if (!DefaultSupermarketsData.matchesChain(m.supermarketName, _selectedChain)) {
        return false;
      }
      if (hasSearch) {
        if (!DefaultSupermarketsData.matchesSearch(m.supermarketName, _searchQuery)) {
          return false;
        }
      }
      // Se não há pesquisa textual ativa, restringe pela distância do raio
      if (!hasSearch && m.distanceMeters != null && m.distanceMeters! > maxMeters) {
        return false;
      }
      return true;
    }).toList();

    // 2. Se o usuário pesquisou pelo nome ou filtrou uma rede e não havia loja no raio curto,
    // expande automaticamente para exibir todas as lojas daquela busca/rede na região (ou em todo o catálogo MWM)!
    if (result.isEmpty && hasActiveSearchOrChain) {
      result = _allLoadedMarkets.where((m) {
        if (!DefaultSupermarketsData.matchesChain(m.supermarketName, _selectedChain)) {
          return false;
        }
        if (_searchQuery.trim().isNotEmpty) {
          if (!DefaultSupermarketsData.matchesSearch(m.supermarketName, _searchQuery)) {
            return false;
          }
        }
        return true;
      }).toList();

      if (result.isEmpty) {
        for (final pre in DefaultSupermarketsData.all) {
          if (!DefaultSupermarketsData.matchesChain(pre.name, _selectedChain)) continue;
          if (_searchQuery.trim().isNotEmpty &&
              !DefaultSupermarketsData.matchesSearch(pre.name, _searchQuery, preloaded: pre)) {
            continue;
          }
          final dist = LocationService.instance.calculateDistance(
            _userPosition.latitude,
            _userPosition.longitude,
            pre.latitude,
            pre.longitude,
          );
          result.add(MarketComparison(
            supermarketName: pre.name,
            latitude: pre.latitude,
            longitude: pre.longitude,
            distanceMeters: dist,
            itemsCount: 0,
            averageItemPrice: 0.0,
            cheapestCount: 0,
          ));
          if (result.length >= 150) break;
        }
        result.sort((a, b) => (a.distanceMeters ?? double.infinity).compareTo(b.distanceMeters ?? double.infinity));
      }
    }

    setState(() {
      _filteredMarkets = result;
      if (_selectedMarket != null &&
          !_filteredMarkets.any((m) => m.supermarketName == _selectedMarket!.supermarketName)) {
        _selectedMarket = null;
      }
    });

    if (fitCameraIfFiltered && _filteredMarkets.isNotEmpty) {
      if (_filteredMarkets.length == 1) {
        _selectMarket(_filteredMarkets.first, openBottomSheet: false);
      } else {
        _fitAllMarkers();
      }
    }
  }

  void _centerOnUser() {
    setState(() {
      _isFollowingUser = true;
    });
    final targetZoom = _mapController.camera.zoom < 14.5 ? 15.5 : _mapController.camera.zoom;
    _mapController.move(_userPosition, targetZoom);
  }

  /// Seleciona um supermercado no mapa: exibe o nome no pin e sincroniza o card inferior.
  /// Se [openBottomSheet] for true (ex: segundo toque no pin ou clique no balão/card), abre os detalhes completos.
  void _selectMarket(MarketComparison market, {bool openBottomSheet = false}) {
    final alreadySelected = _selectedMarket?.supermarketName == market.supermarketName;

    setState(() {
      _selectedMarket = market;
      _showSearchSuggestions = false;
      _isFollowingUser = false;
    });
    _searchFocusNode.unfocus();

    if (market.latitude != null && market.longitude != null) {
      final targetZoom = _mapController.camera.zoom < 14.5 ? 15.2 : _mapController.camera.zoom;
      _mapController.move(LatLng(market.latitude!, market.longitude!), targetZoom);
    }

    final index = _filteredMarkets.indexWhere((m) => m.supermarketName == market.supermarketName);
    if (index != -1 && _cardsPageController.hasClients) {
      _cardsPageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    }

    _loadDealsForMarket(market.supermarketName);

    if (openBottomSheet || alreadySelected) {
      _showMarketBottomSheet(market);
    }
  }

  Future<void> _loadDealsForMarket(String marketName) async {
    setState(() => _isLoadingDeals = true);
    final deals = await CommunityPriceService.instance.getTopDealsForMarket(
      marketName,
      limit: 15,
      userLat: _userPosition.latitude,
      userLng: _userPosition.longitude,
      syncWithCloud: true,
    );
    if (mounted) {
      setState(() {
        _selectedMarketDeals = deals;
        _isLoadingDeals = false;
      });
    }
  }

  void _fitAllMarkers() {
    setState(() {
      _isFollowingUser = false;
    });
    if (_filteredMarkets.isEmpty) {
      _centerOnUser();
      return;
    }

    final points = <LatLng>[_userPosition];
    for (var m in _filteredMarkets) {
      if (m.latitude != null && m.longitude != null) {
        points.add(LatLng(m.latitude!, m.longitude!));
      }
    }

    if (points.length == 1) {
      _mapController.move(points.first, 14.0);
      return;
    }

    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.only(top: 160, bottom: 180, left: 44, right: 44),
      ),
    );
  }

  void _openFullListModal() {
    final primary = Theme.of(context).colorScheme.primary;
    final cardColor = Theme.of(context).cardColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        String modalSearch = _searchQuery;
        String modalChain = _selectedChain;
        final modalSearchCtrl = TextEditingController(text: modalSearch);

        return StatefulBuilder(
          builder: (context, setModalState) {
            final filtered = _allLoadedMarkets.where((m) {
              if (!DefaultSupermarketsData.matchesChain(m.supermarketName, modalChain)) {
                return false;
              }
              if (modalSearch.isNotEmpty) {
                return DefaultSupermarketsData.matchesSearch(m.supermarketName, modalSearch);
              }
              return true;
            }).toList();

            return Container(
              height: MediaQuery.of(context).size.height * 0.80,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                top: 12,
                left: 16,
                right: 16,
              ),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  TextField(
                    controller: modalSearchCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    decoration: InputDecoration(
                      hintText: 'Pesquisar mercado pelo nome, rede ou bairro...',
                      hintStyle: const TextStyle(fontSize: 13),
                      prefixIcon: Icon(Icons.search_rounded, color: primary),
                      suffixIcon: modalSearch.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 18),
                              onPressed: () {
                                modalSearchCtrl.clear();
                                FocusScope.of(context).unfocus();
                                setModalState(() => modalSearch = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: isDark ? Colors.grey.shade900 : Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (val) {
                      setModalState(() {
                        modalSearch = val.trim();
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  // Filtro horizontal por redes dentro do modal
                  SizedBox(
                    height: 36,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: DefaultSupermarketsData.mainChains.length,
                      itemBuilder: (context, idx) {
                        final chain = DefaultSupermarketsData.mainChains[idx];
                        final isSelected = modalChain == chain;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(chain == 'Todas' ? 'Todas as Redes' : chain),
                            selected: isSelected,
                            showCheckmark: false,
                            selectedColor: primary,
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                              color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                            ),
                            onSelected: (_) {
                              setModalState(() {
                                modalChain = chain;
                              });
                            },
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${filtered.length} supermercados encontrados',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                      ),
                      if (modalChain != 'Todas' || modalSearch.isNotEmpty)
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _selectedChain = modalChain;
                              _searchQuery = modalSearch;
                              _searchController.text = modalSearch;
                            });
                            _applyFilters(fitCameraIfFiltered: true);
                          },
                          child: const Text('Aplicar filtro no mapa', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                            child: Text('Nenhum supermercado encontrado com este filtro.'),
                          )
                        : ListView.separated(
                            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final item = filtered[index];
                              final pre = DefaultSupermarketsData.findMatch(item.supermarketName);
                              final addr = pre?.address;
                              final chain = DefaultSupermarketsData.getChainName(item.supermarketName);
                              final distText = item.formattedDistance.isNotEmpty ? item.formattedDistance : '';
                              final sub = [
                                if (distText.isNotEmpty) distText,
                                if (chain != 'Outras') chain,
                                if (addr != null && addr.isNotEmpty) addr,
                              ].join(' • ');

                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                leading: CircleAvatar(
                                  backgroundColor: _parseColorHex(pre?.colorHex, primary).withValues(alpha: 0.15),
                                  child: Icon(
                                    Icons.location_on_rounded,
                                    color: _parseColorHex(pre?.colorHex, primary),
                                  ),
                                ),
                                title: Text(
                                  item.supermarketName,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                subtitle: Text(
                                  sub.isNotEmpty ? sub : 'Supermercado geolocalizado',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 14),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  setState(() {
                                    _selectedChain = modalChain;
                                    _searchQuery = modalSearch;
                                    _searchController.text = modalSearch;
                                  });
                                  _applyFilters(fitCameraIfFiltered: false);
                                  _selectMarket(item, openBottomSheet: false);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openNavigation(double lat, double lng, String name) async {
    final Uri geoUri = Uri.parse('geo:$lat,$lng?q=$lat,$lng(${Uri.encodeComponent(name)})');
    final Uri webUri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');

    try {
      if (await canLaunchUrl(geoUri)) {
        await launchUrl(geoUri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {}

    try {
      if (await canLaunchUrl(webUri)) {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
        return;
      }
    } catch (_) {}

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o aplicativo de mapas.')),
      );
    }
  }

  void _showMarketBottomSheet(MarketComparison market) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    final cardColor = Theme.of(context).cardColor;
    final isCheapest = market.isCheapest;
    final pre = DefaultSupermarketsData.findMatch(market.supermarketName);
    final chainName = DefaultSupermarketsData.getChainName(market.supermarketName);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.65,
              ),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 20,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 8),
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.grey.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),

                  // Header do Mercado
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            gradient: isCheapest
                                ? const LinearGradient(
                                    colors: [Color(0xFFFFA000), Color(0xFFFF6F00)],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  )
                                : LinearGradient(
                                    colors: [
                                      _parseColorHex(pre?.colorHex, primary),
                                      _parseColorHex(pre?.colorHex, primary).withValues(alpha: 0.8),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            isCheapest ? Icons.workspace_premium_rounded : Icons.storefront_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      market.supermarketName,
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isCheapest)
                                    Container(
                                      margin: const EdgeInsets.only(left: 6),
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFFFA000).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: const Color(0xFFFFA000), width: 1),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text('👑 ', style: TextStyle(fontSize: 10)),
                                          Text(
                                            'Mais Barato',
                                            style: TextStyle(
                                              color: Color(0xFFE65100),
                                              fontWeight: FontWeight.bold,
                                              fontSize: 10,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  if (market.formattedDistance.isNotEmpty)
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.near_me_rounded, size: 13, color: primary),
                                        const SizedBox(width: 3),
                                        Text(
                                          market.formattedDistance,
                                          style: TextStyle(fontSize: 12.5, color: primary, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  if (chainName != 'Outras')
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: primary.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        'Rede $chainName',
                                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: primary),
                                      ),
                                    ),
                                  Text(
                                    market.itemsCount > 0
                                        ? '• ${market.itemsCount} produtos'
                                        : '• Mercado cadastrado',
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                  ),
                                ],
                              ),
                              if (pre?.address != null) ...[
                                const SizedBox(height: 4),
                                Row(
                                  children: [
                                    Icon(Icons.location_on_outlined, size: 12, color: Colors.grey.shade500),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: Text(
                                        pre!.address!,
                                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Divider(height: 1, indent: 20, endIndent: 20),

                  // Preço Médio e Estatísticas
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Preço Médio', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                                const SizedBox(height: 2),
                                Text(
                                  market.averageItemPrice > 0 ? Utils.formatCurrency(market.averageItemPrice) : '--',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: isCheapest ? Colors.green.shade700 : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Itens Campeões', style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                                const SizedBox(height: 2),
                                Text(
                                  '${market.cheapestCount} menores preços',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Ofertas em Destaque no Mercado
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Preços Registrados',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        if (_isLoadingDeals)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                  ),

                  Expanded(
                    child: _isLoadingDeals
                        ? const Center(child: CircularProgressIndicator())
                        : _selectedMarketDeals.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    'Nenhum preço individual cadastrado recentemente para este mercado.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                                  ),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 20),
                                itemCount: _selectedMarketDeals.length,
                                itemBuilder: (ctx, idx) {
                                  final deal = _selectedMarketDeals[idx];
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.grey.shade50,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isDark ? Colors.white.withValues(alpha: 0.06) : Colors.grey.shade200,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(Icons.shopping_bag_outlined, size: 18, color: primary),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            deal.productName,
                                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        Text(
                                          Utils.formatCurrency(deal.price),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 14,
                                            color: Colors.green,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                  ),

                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.pop(ctx);
                                Navigator.pop(context, market.supermarketName);
                              },
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              icon: const Icon(Icons.radar_rounded, size: 20),
                              label: const Text('Ver no Radar', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                if (market.latitude != null && market.longitude != null) {
                                  _openNavigation(market.latitude!, market.longitude!, market.supermarketName);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: primary,
                                foregroundColor: Colors.white,
                                elevation: 2,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              icon: const Icon(Icons.directions_rounded, size: 20),
                              label: const Text('Como Chegar', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static const ColorFilter _darkMapColorFilter = ColorFilter.matrix(<double>[
    0.3311, -1.0728, -0.1083, 0.0, 222.0,
    -0.3189, -0.4228, -0.1083, 0.0, 228.0,
    -0.3189, -1.0728, 0.5417, 0.0, 240.0,
    0.0, 0.0, 0.0, 1.0, 0.0,
  ]);

  Widget _buildTileLayer(bool isDark) {
    switch (_mapTileStyle) {
      case MapTileStyle.googleStandard:
        return TileLayer(
          key: const ValueKey('tile_google_standard'),
          urlTemplate: 'https://mt{s}.google.com/vt/lyrs=m&hl=pt-BR&x={x}&y={y}&z={z}',
          subdomains: const ['0', '1', '2', '3'],
          userAgentPackageName: 'com.example.lista_compras',
        );
      case MapTileStyle.googleClean:
        // Mapa Google oficial sem ícones comerciais de terceiros (apistyle oculta POIs e trânsito), 100% sem API Key
        return TileLayer(
          key: const ValueKey('tile_google_clean'),
          urlTemplate:
              'https://mt{s}.google.com/vt/lyrs=m&hl=pt-BR&apistyle=s.t%3A2%7Cp.v%3Aoff%2Cs.t%3A4%7Cp.v%3Aoff&x={x}&y={y}&z={z}',
          subdomains: const ['0', '1', '2', '3'],
          userAgentPackageName: 'com.example.lista_compras',
        );
      case MapTileStyle.googleHybrid:
        return TileLayer(
          key: const ValueKey('tile_google_hybrid'),
          urlTemplate: 'https://mt{s}.google.com/vt/lyrs=y&hl=pt-BR&x={x}&y={y}&z={z}',
          subdomains: const ['0', '1', '2', '3'],
          userAgentPackageName: 'com.example.lista_compras',
        );
      case MapTileStyle.googleTerrain:
        return TileLayer(
          key: const ValueKey('tile_google_terrain'),
          urlTemplate: 'https://mt{s}.google.com/vt/lyrs=p&hl=pt-BR&x={x}&y={y}&z={z}',
          subdomains: const ['0', '1', '2', '3'],
          userAgentPackageName: 'com.example.lista_compras',
        );
      case MapTileStyle.osmStandard:
        return TileLayer(
          key: const ValueKey('tile_osm_standard'),
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.lista_compras',
        );
      case MapTileStyle.darkNight:
        // Mapa Google Noturno (100% sem API Key) com matriz de inversão cromática preservando azul da água e verde de parques
        return ColorFiltered(
          colorFilter: _darkMapColorFilter,
          child: TileLayer(
            key: const ValueKey('tile_dark_night'),
            urlTemplate:
                'https://mt{s}.google.com/vt/lyrs=m&hl=pt-BR&apistyle=s.t%3A2%7Cp.v%3Aoff%2Cs.t%3A4%7Cp.v%3Aoff&x={x}&y={y}&z={z}',
            subdomains: const ['0', '1', '2', '3'],
            userAgentPackageName: 'com.example.lista_compras',
          ),
        );
    }
  }

  /// Quando o usuário toca (no modo Escolher no Mapa) ou segura em um ponto do mapa desenhado:
  /// 1. Se houver um mercado cadastrado num raio de 220m do toque, seleciona esse mercado automaticamente!
  /// 2. Caso contrário, posiciona um pino no local escolhido e oferece buscar mercados ao redor daquele ponto ou usar o mais próximo.
  void _handleMapPointPicked(LatLng point) {
    // 1. Verifica se clicou diretamente sobre ou muito perto de um mercado (até 220m)
    MarketComparison? nearLoaded;
    double minDist = 220.0;
    for (final m in _allLoadedMarkets) {
      if (m.latitude == null || m.longitude == null) continue;
      final d = LocationService.instance.calculateDistance(
        point.latitude,
        point.longitude,
        m.latitude!,
        m.longitude!,
      );
      if (d < minDist) {
        minDist = d;
        nearLoaded = m;
      }
    }

    if (nearLoaded != null) {
      setState(() {
        _pickOnMapMode = false;
        _pickedMapPoint = null;
      });
      _selectMarket(nearLoaded, openBottomSheet: true);
      return;
    }

    final nearCatalog = DefaultSupermarketsData.findNearestWithinRadius(
      point.latitude,
      point.longitude,
    );
    if (nearCatalog != null) {
      final d = LocationService.instance.calculateDistance(
        point.latitude,
        point.longitude,
        nearCatalog.latitude,
        nearCatalog.longitude,
      );
      final comp = MarketComparison(
        supermarketName: nearCatalog.name,
        latitude: nearCatalog.latitude,
        longitude: nearCatalog.longitude,
        distanceMeters: LocationService.instance.calculateDistance(
          _userPosition.latitude,
          _userPosition.longitude,
          nearCatalog.latitude,
          nearCatalog.longitude,
        ),
        itemsCount: 0,
        averageItemPrice: 0.0,
        cheapestCount: 0,
      );
      setState(() {
        _pickOnMapMode = false;
        _pickedMapPoint = null;
        if (!_filteredMarkets.any((m) => m.supermarketName == comp.supermarketName)) {
          _filteredMarkets = [comp, ..._filteredMarkets];
        }
      });
      if (d <= 250.0) {
        _selectMarket(comp, openBottomSheet: true);
        return;
      }
    }

    // 2. Nenhum mercado colado ao ponto: marca o pino escolhido e abre opções para o ponto
    setState(() {
      _pickedMapPoint = point;
      _pickOnMapMode = false;
    });
    _mapController.move(point, _mapController.camera.zoom < 15.0 ? 15.5 : _mapController.camera.zoom);
    _showPickedPointSheet(point);
  }

  void _showPickedPointSheet(LatLng point) {
    final primary = Theme.of(context).colorScheme.primary;
    final cardColor = Theme.of(context).cardColor;

    // Encontra o mercado mais próximo deste ponto escolhido em todo o catálogo MWM
    PreloadedSupermarket? closestPre;
    double closestDist = double.infinity;
    for (final s in DefaultSupermarketsData.all) {
      final dLat = (s.latitude - point.latitude).abs();
      final dLng = (s.longitude - point.longitude).abs();
      if (dLat > 0.15 || dLng > 0.15) continue;
      final d = LocationService.instance.calculateDistance(
        point.latitude,
        point.longitude,
        s.latitude,
        s.longitude,
      );
      if (d < closestDist) {
        closestDist = d;
        closestPre = s;
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.place_rounded, color: Colors.deepPurple, size: 26),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Local Escolhido no Mapa',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          Text(
                            'Coordenadas: ${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (closestPre != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: primary.withValues(alpha: 0.25)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.storefront_rounded, color: primary, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Mercado mais próximo (${LocationService.instance.formatDistance(closestDist)}):',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                closestPre.name,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                              ),
                              if (closestPre.address != null)
                                Text(
                                  closestPre.address!,
                                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            final comp = MarketComparison(
                              supermarketName: closestPre!.name,
                              latitude: closestPre.latitude,
                              longitude: closestPre.longitude,
                              distanceMeters: LocationService.instance.calculateDistance(
                                _userPosition.latitude,
                                _userPosition.longitude,
                                closestPre.latitude,
                                closestPre.longitude,
                              ),
                              itemsCount: 0,
                              averageItemPrice: 0.0,
                              cheapestCount: 0,
                            );
                            if (!_filteredMarkets.any((m) => m.supermarketName == comp.supermarketName)) {
                              setState(() {
                                _filteredMarkets = [comp, ..._filteredMarkets];
                              });
                            }
                            _selectMarket(comp, openBottomSheet: true);
                          },
                          child: const Text('Selecionar', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openNavigation(point.latitude, point.longitude, 'Local Escolhido');
                        },
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: const Icon(Icons.directions_rounded, size: 18),
                        label: const Text('Ir até aqui', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          setState(() {
                            _userPosition = point;
                            _pickedMapPoint = null;
                          });
                          await _loadMarkets(syncWithCloud: false);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        icon: const Icon(Icons.radar_rounded, size: 18),
                        label: const Text('Buscar daqui', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Abre o menu "Tipo de Mapa e Camadas" igual ao Google Maps, com cards desenhados para o usuário escolher
  void _showMapStyleAndLayersSheet() {
    final primary = Theme.of(context).colorScheme.primary;
    final cardColor = Theme.of(context).cardColor;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            Widget buildStyleCard({
              required MapTileStyle style,
              required String title,
              required String subtitle,
              required IconData icon,
              required List<Color> previewGradient,
              required Color roadColor,
              required Color accentColor,
            }) {
              final selected = _mapTileStyle == style;
              return GestureDetector(
                onTap: () {
                  _setMapStyle(style);
                  setModalState(() {});
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: selected
                        ? primary.withValues(alpha: 0.12)
                        : (isDark ? Colors.white.withValues(alpha: 0.04) : Colors.grey.shade100),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: selected ? primary : Colors.grey.withValues(alpha: 0.25),
                      width: selected ? 2.2 : 1.0,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Miniatura desenhada do estilo de mapa
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: previewGradient,
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Stack(
                            children: [
                              // Traços simulando quadras e avenidas desenhadas do mapa
                              Positioned(
                                top: 14,
                                left: 0,
                                right: 0,
                                child: Container(height: 4, color: roadColor.withValues(alpha: 0.75)),
                              ),
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left: 26,
                                child: Container(width: 4, color: roadColor.withValues(alpha: 0.75)),
                              ),
                              Positioned(
                                bottom: 12,
                                left: 10,
                                right: 8,
                                child: Container(height: 3, color: accentColor.withValues(alpha: 0.85)),
                              ),
                              Center(
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.35),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(icon, color: Colors.white, size: 18),
                                ),
                              ),
                              if (selected)
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: BoxDecoration(
                                      color: primary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(Icons.check_rounded, size: 12, color: Colors.white),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: selected ? primary : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              );
            }

            return Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: SafeArea(
                top: false,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 5,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(Icons.layers_rounded, color: primary, size: 22),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Tipo de Mapa (Estilo Google Maps)',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close_rounded, size: 20),
                            visualDensity: VisualDensity.compact,
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: 1.05,
                        children: [
                          buildStyleCard(
                            style: MapTileStyle.googleStandard,
                            title: 'Padrão Google',
                            subtitle: 'Desenhado + Ruas',
                            icon: Icons.map_rounded,
                            previewGradient: const [Color(0xFFE8F5E9), Color(0xFFE3F2FD)],
                            roadColor: Colors.white,
                            accentColor: const Color(0xFFFBC02D),
                          ),
                          buildStyleCard(
                            style: MapTileStyle.googleHybrid,
                            title: 'Satélite',
                            subtitle: 'Foto real + Ruas',
                            icon: Icons.satellite_alt_rounded,
                            previewGradient: const [Color(0xFF1B5E20), Color(0xFF0D47A1)],
                            roadColor: Colors.white70,
                            accentColor: Colors.amberAccent,
                          ),
                          buildStyleCard(
                            style: MapTileStyle.googleTerrain,
                            title: 'Relevo',
                            subtitle: 'Terreno 3D',
                            icon: Icons.terrain_rounded,
                            previewGradient: const [Color(0xFFC8E6C9), Color(0xFFA5D6A7)],
                            roadColor: Colors.white,
                            accentColor: const Color(0xFF8D6E63),
                          ),
                          buildStyleCard(
                            style: MapTileStyle.googleClean,
                            title: 'Mapa Limpo',
                            subtitle: 'Só nossos pinos',
                            icon: Icons.auto_awesome_rounded,
                            previewGradient: const [Color(0xFFF5F5F5), Color(0xFFE0E0E0)],
                            roadColor: Colors.white,
                            accentColor: primary,
                          ),
                          buildStyleCard(
                            style: MapTileStyle.osmStandard,
                            title: 'OpenStreetMap',
                            subtitle: 'Clássico OSM',
                            icon: Icons.public_rounded,
                            previewGradient: const [Color(0xFFDCEDC8), Color(0xFFB3E5FC)],
                            roadColor: const Color(0xFFFFCC80),
                            accentColor: const Color(0xFFE57373),
                          ),
                          buildStyleCard(
                            style: MapTileStyle.darkNight,
                            title: 'Noturno',
                            subtitle: 'Modo escuro',
                            icon: Icons.dark_mode_rounded,
                            previewGradient: const [Color(0xFF212121), Color(0xFF0D1B2A)],
                            roadColor: Colors.grey.shade700,
                            accentColor: Colors.cyanAccent,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const Divider(height: 1),
                      const SizedBox(height: 8),
                      Text(
                        'Detalhes e Interação sem Conflito',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade600),
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        secondary: Icon(Icons.location_on_rounded, color: primary),
                        title: const Text(
                          'Exibir Pinos dos Mercados',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                        subtitle: const Text(
                          'Desative se quiser ver apenas os ícones desenhados no mapa do Google',
                          style: TextStyle(fontSize: 11.5),
                        ),
                        value: _showMarketPins,
                        onChanged: (val) {
                          setState(() => _showMarketPins = val);
                          setModalState(() {});
                        },
                      ),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        secondary: Icon(Icons.radar_rounded, color: primary),
                        title: const Text(
                          'Exibir Círculo de Alcance',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                        ),
                        value: _showRadiusCircle,
                        onChanged: (val) {
                          setState(() => _showRadiusCircle = val);
                          setModalState(() {});
                        },
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() => _pickOnMapMode = true);
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.touch_app_rounded, size: 18),
                          label: const Text(
                            'Escolher Ponto ou Mercado Tocando no Mapa',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Constrói um Pin leve (sem texto quando não selecionado) para máxima fluidez (60fps) no mapa.
  /// Quando selecionado pelo clique do usuário, exibe o balão superior com o nome do mercado.
  Marker _buildMarketMarker(MarketComparison market, Color primary, Color cardColor, bool isDark) {
    final isCheapest = market.isCheapest;
    final isSelected = _selectedMarket?.supermarketName == market.supermarketName;
    final pre = DefaultSupermarketsData.findMatch(market.supermarketName);
    final pinColor = isCheapest
        ? const Color(0xFFFF8F00)
        : _parseColorHex(pre?.colorHex, primary);

    if (!isSelected) {
      // Pin limpo e leve (sem texto), com RepaintBoundary para evitar re-render durante pan/zoom
      return Marker(
        point: LatLng(market.latitude!, market.longitude!),
        width: 38,
        height: 38,
        alignment: Alignment.center,
        child: RepaintBoundary(
          child: GestureDetector(
            onTap: () => _selectMarket(market, openBottomSheet: false),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: pinColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.2),
              ),
              child: Icon(
                isCheapest ? Icons.workspace_premium_rounded : Icons.location_on_rounded,
                size: 18,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }

    // Quando clicado/selecionado: exibe o balão informativo acima do pin sem alterar o ponto âncora do mapa!
    return Marker(
      point: LatLng(market.latitude!, market.longitude!),
      width: 38,
      height: 38,
      alignment: Alignment.center,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Balão informativo posicionado acima do pin (ancoragem física inalterada)
          Positioned(
            bottom: 42,
            child: GestureDetector(
              onTap: () => _showMarketBottomSheet(market),
              child: Container(
                constraints: const BoxConstraints(maxWidth: 220),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: isCheapest ? const Color(0xFFFF8F00) : primary,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.white, width: 1.8),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCheapest) const Text('👑 ', style: TextStyle(fontSize: 11)),
                    Flexible(
                      child: Text(
                        market.supermarketName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 11.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.info_outline_rounded, size: 13, color: Colors.white70),
                  ],
                ),
              ),
            ),
          ),
          // Pin centralizado com exatidão matemática nas coordenadas geográficas
          GestureDetector(
            onTap: () => _showMarketBottomSheet(market),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: pinColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(
                isCheapest ? Icons.workspace_premium_rounded : Icons.storefront_rounded,
                size: 20,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).primaryColor;
    final cardColor = Theme.of(context).cardColor;
    final double bottomPadding = MediaQuery.of(context).padding.bottom;

    final markers = <Marker>[];

    // 1. Marcador do Usuário em Tempo Real (GPS com radar pulsante e orientação)
    markers.add(
      Marker(
        point: _userPosition,
        width: 72,
        height: 72,
        alignment: Alignment.center,
        child: PulsingUserLocationMarker(
          heading: _userHeading,
          isFollowing: _isFollowingUser,
        ),
      ),
    );

    // 2. Marcadores dos Mercados (não selecionados primeiro, selecionado por último para ficar no topo;
    // limita a 180 pins simultâneos no canvas para manter 60fps constantes em áreas metropolitanas densas)
    MarketComparison? selectedForTop;
    int renderedPins = 0;
    for (var market in _filteredMarkets) {
      if (market.latitude == null || market.longitude == null) continue;
      if (_selectedMarket?.supermarketName == market.supermarketName) {
        selectedForTop = market;
        continue;
      }
      if (_showMarketPins && renderedPins < 180) {
        markers.add(_buildMarketMarker(market, primary, cardColor, isDark));
        renderedPins++;
      }
    }
    if (selectedForTop != null) {
      markers.add(_buildMarketMarker(selectedForTop, primary, cardColor, isDark));
    }

    // 3. Marcador de Ponto Escolhido no Mapa (se o usuário clicou/segurou em um ponto específico)
    if (_pickedMapPoint != null) {
      markers.add(
        Marker(
          point: _pickedMapPoint!,
          width: 46,
          height: 46,
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () => _showPickedPointSheet(_pickedMapPoint!),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.deepPurple,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.6),
              ),
              child: const Icon(Icons.place_rounded, color: Colors.white, size: 22),
            ),
          ),
        ),
      );
    }

    final circles = <CircleMarker>[];
    if (_hasRealGps && _userAccuracy != null && _userAccuracy! > 5 && _userAccuracy! <= 250) {
      circles.add(
        CircleMarker(
          point: _userPosition,
          radius: _userAccuracy!,
          useRadiusInMeter: true,
          color: Colors.blue.withValues(alpha: 0.08),
          borderColor: Colors.blue.withValues(alpha: 0.28),
          borderStrokeWidth: 1.0,
        ),
      );
    }
    if (_showRadiusCircle) {
      circles.add(
        CircleMarker(
          point: _userPosition,
          radius: _radiusKm * 1000,
          useRadiusInMeter: true,
          color: primary.withValues(alpha: 0.06),
          borderColor: primary.withValues(alpha: 0.30),
          borderStrokeWidth: 1.5,
        ),
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 🗺️ MAPA INTERATIVO OTIMIZADO (GOOGLE MAPS DESENHADO / SATÉLITE / RELEVO / OSM)
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _userPosition,
              initialZoom: 13.5,
              minZoom: 4,
              maxZoom: 19,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (camera, hasGesture) {
                if (hasGesture && _isFollowingUser) {
                  setState(() {
                    _isFollowingUser = false;
                  });
                }
              },
              onTap: (_, point) {
                if (_pickOnMapMode) {
                  _handleMapPointPicked(point);
                  return;
                }
                if (_selectedMarket != null || _showSearchSuggestions) {
                  setState(() {
                    _selectedMarket = null;
                    _showSearchSuggestions = false;
                  });
                }
                _searchFocusNode.unfocus();
              },
              onLongPress: (_, point) {
                _handleMapPointPicked(point);
              },
            ),
            children: [
              _buildTileLayer(isDark),
              if (circles.isNotEmpty) CircleLayer(circles: circles),
              MarkerLayer(markers: markers),
            ],
          ),

          // 🔝 BARRA SUPERIOR COM PESQUISA POR NOME E FILTRO POR REDES
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Linha 1: Voltar + Campo de Busca Direto por Nome + Raio + Lista
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    decoration: BoxDecoration(
                      color: cardColor.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded),
                          tooltip: 'Voltar',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                            decoration: InputDecoration(
                              hintText: 'Pesquisar mercado ou bairro...',
                              hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                              prefixIcon: Icon(Icons.search_rounded, size: 20, color: primary),
                              prefixIconConstraints: const BoxConstraints(minWidth: 34),
                              suffixIcon: _searchQuery.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.clear_rounded, size: 18),
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () {
                                        _searchController.clear();
                                        _searchFocusNode.unfocus();
                                        FocusScope.of(context).unfocus();
                                        setState(() {
                                          _searchQuery = '';
                                          _showSearchSuggestions = false;
                                        });
                                        _applyFilters(fitCameraIfFiltered: false);
                                      },
                                    )
                                  : null,
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onChanged: (val) {
                              setState(() {
                                _searchQuery = val.trim();
                                _showSearchSuggestions = _searchQuery.isNotEmpty;
                              });
                              _applyFilters(fitCameraIfFiltered: false);
                            },
                            textInputAction: TextInputAction.search,
                            onSubmitted: (_) {
                              _searchFocusNode.unfocus();
                              FocusScope.of(context).unfocus();
                              setState(() => _showSearchSuggestions = false);
                              _applyFilters(fitCameraIfFiltered: true);
                            },
                          ),
                        ),
                        // Seletor de Raio compacto
                        PopupMenuButton<double>(
                          tooltip: 'Raio de alcance',
                          onSelected: (r) {
                            if (r == -1) {
                              setState(() => _showRadiusCircle = !_showRadiusCircle);
                            } else {
                              setState(() => _radiusKm = r);
                              _applyFilters(fitCameraIfFiltered: false);
                            }
                          },
                          itemBuilder: (ctx) => [
                            ...[5.0, 10.0, 15.0, 25.0, 50.0].map(
                              (r) => PopupMenuItem<double>(
                                value: r,
                                child: Row(
                                  children: [
                                    Icon(
                                      _radiusKm == r ? Icons.radio_button_checked : Icons.radio_button_off,
                                      size: 18,
                                      color: _radiusKm == r ? primary : Colors.grey,
                                    ),
                                    const SizedBox(width: 8),
                                    Text('Raio de ${r.toInt()} km'),
                                  ],
                                ),
                              ),
                            ),
                            const PopupMenuDivider(),
                            PopupMenuItem<double>(
                              value: -1,
                              child: Row(
                                children: [
                                  Icon(
                                    _showRadiusCircle ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(_showRadiusCircle ? 'Ocultar círculo do raio' : 'Mostrar círculo do raio'),
                                ],
                              ),
                            ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.radar_rounded, size: 14, color: primary),
                                const SizedBox(width: 4),
                                Text(
                                  '${_radiusKm.toInt()}km',
                                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold, color: primary),
                                ),
                              ],
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.format_list_bulleted_rounded, size: 20),
                          tooltip: 'Ver lista de mercados e redes',
                          visualDensity: VisualDensity.compact,
                          onPressed: _openFullListModal,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Linha 2: Filtro Horizontal por Redes (Guanabara, Supermarket, Assaí, Rede Economia, etc.)
                  SizedBox(
                    height: 36,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: DefaultSupermarketsData.mainChains.length,
                      itemBuilder: (context, idx) {
                        final chain = DefaultSupermarketsData.mainChains[idx];
                        final isSelected = _selectedChain == chain;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            selected: isSelected,
                            showCheckmark: false,
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              chain == 'Todas' ? 'Todas as Redes (${_filteredMarkets.length})' : chain,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                                fontSize: 12,
                                color: isSelected ? Colors.white : (isDark ? Colors.white70 : Colors.black87),
                              ),
                            ),
                            backgroundColor: cardColor.withValues(alpha: 0.92),
                            selectedColor: primary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                              side: BorderSide(
                                color: isSelected ? primary : Colors.grey.withValues(alpha: 0.3),
                              ),
                            ),
                            onSelected: (_) {
                              setState(() {
                                _selectedChain = (_selectedChain == chain && chain != 'Todas') ? 'Todas' : chain;
                              });
                              _applyFilters(fitCameraIfFiltered: true);
                            },
                          ),
                        );
                      },
                    ),
                  ),

                  // Banner de instrução quando o modo "Escolher no Mapa" está ativo
                  if (_pickOnMapMode)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple,
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.touch_app_rounded, color: Colors.white, size: 18),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Toque em qualquer mercado ou ponto desenhado no mapa para escolhê-lo',
                              style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setState(() => _pickOnMapMode = false),
                            child: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
                          ),
                        ],
                      ),
                    ),

                  // Sugestões de busca rápida quando o usuário está digitando
                  if (_showSearchSuggestions && _filteredMarkets.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      constraints: const BoxConstraints(maxHeight: 210),
                      decoration: BoxDecoration(
                        color: cardColor.withValues(alpha: 0.97),
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        itemCount: _filteredMarkets.length > 6 ? 6 : _filteredMarkets.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, idx) {
                          final m = _filteredMarkets[idx];
                          final pre = DefaultSupermarketsData.findMatch(m.supermarketName);
                          return ListTile(
                            dense: true,
                            leading: Icon(Icons.location_on_rounded, color: primary, size: 20),
                            title: Text(
                              m.supermarketName,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: pre?.address != null
                                ? Text(
                                    pre!.address!,
                                    style: const TextStyle(fontSize: 11),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : null,
                            trailing: m.formattedDistance.isNotEmpty
                                ? Text(
                                    m.formattedDistance,
                                    style: TextStyle(fontSize: 11, color: primary, fontWeight: FontWeight.bold),
                                  )
                                : null,
                            onTap: () => _selectMarket(m, openBottomSheet: false),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),

          // 🔘 BOTÕES FLUTUANTES LATERAIS (CAMADAS GOOGLE MAPS, ESCOLHER NO MAPA, ENQUADRAR & GPS)
          Positioned(
            right: 16,
            bottom: (_filteredMarkets.isNotEmpty ? 136 : 30) + bottomPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'fab_map_layers',
                  backgroundColor: cardColor,
                  foregroundColor: primary,
                  tooltip: 'Tipo de Mapa (Google Padrão / Satélite / Relevo)',
                  onPressed: _showMapStyleAndLayersSheet,
                  child: const Icon(Icons.layers_rounded),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'fab_pick_on_map',
                  backgroundColor: _pickOnMapMode ? Colors.deepPurple : cardColor,
                  foregroundColor: _pickOnMapMode ? Colors.white : Colors.deepPurple,
                  tooltip: 'Escolher ponto ou mercado tocando no mapa',
                  onPressed: () {
                    setState(() => _pickOnMapMode = !_pickOnMapMode);
                  },
                  child: const Icon(Icons.touch_app_rounded),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'fab_fit_bounds',
                  backgroundColor: cardColor,
                  foregroundColor: primary,
                  tooltip: 'Enquadrar mercados no mapa',
                  onPressed: _fitAllMarkers,
                  child: const Icon(Icons.zoom_out_map_rounded),
                ),
                const SizedBox(height: 10),
                FloatingActionButton(
                  heroTag: 'fab_my_gps',
                  backgroundColor: _isFollowingUser ? Colors.blue.shade600 : cardColor,
                  foregroundColor: _isFollowingUser ? Colors.white : primary,
                  tooltip: _isFollowingUser ? 'Seguindo sua localização ao vivo (GPS)' : 'Centralizar e seguir (GPS)',
                  onPressed: _centerOnUser,
                  child: Icon(_isFollowingUser
                      ? Icons.navigation_rounded
                      : (_hasRealGps ? Icons.my_location_rounded : Icons.location_searching_rounded)),
                ),
              ],
            ),
          ),

          // 📍 BADGE AO VIVO DE SEGUIR LOCALIZAÇÃO EM TEMPO REAL
          if (_isFollowingUser)
            Positioned(
              right: 14,
              top: MediaQuery.of(context).padding.top + 98,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.blue.shade600,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Seguindo GPS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 🎠 CARROSSEL HORIZONTAL DE MERCADOS NO RODAPÉ
          if (_filteredMarkets.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14 + bottomPadding,
              height: 112,
              child: PageView.builder(
                controller: _cardsPageController,
                itemCount: _filteredMarkets.length,
                onPageChanged: (idx) {
                  final m = _filteredMarkets[idx];
                  setState(() => _selectedMarket = m);
                  if (m.latitude != null && m.longitude != null) {
                    _mapController.move(LatLng(m.latitude!, m.longitude!), _mapController.camera.zoom);
                  }
                },
                itemBuilder: (ctx, idx) {
                  final m = _filteredMarkets[idx];
                  final isCheapest = m.isCheapest;
                  final isSelected = _selectedMarket?.supermarketName == m.supermarketName;
                  final pre = DefaultSupermarketsData.findMatch(m.supermarketName);

                  return GestureDetector(
                    onTap: () => _selectMarket(m, openBottomSheet: true),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: cardColor.withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(18),
                        border: isCheapest
                            ? Border.all(color: const Color(0xFFFFA000), width: 1.8)
                            : isSelected
                                ? Border.all(color: primary, width: 1.6)
                                : Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.12),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: isCheapest
                                  ? const Color(0xFFFFA000).withValues(alpha: 0.15)
                                  : _parseColorHex(pre?.colorHex, primary).withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              isCheapest ? Icons.workspace_premium_rounded : Icons.storefront_rounded,
                              color: isCheapest ? const Color(0xFFFFA000) : _parseColorHex(pre?.colorHex, primary),
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        m.supermarketName,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (isCheapest) const Text('👑', style: TextStyle(fontSize: 12)),
                                  ],
                                ),
                                if (pre?.address != null) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    pre!.address!,
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    if (m.formattedDistance.isNotEmpty) ...[
                                      Icon(Icons.near_me_outlined, size: 12, color: primary),
                                      const SizedBox(width: 2),
                                      Text(
                                        m.formattedDistance,
                                        style: TextStyle(fontSize: 11, color: primary, fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    if (m.averageItemPrice > 0)
                                      Text(
                                        'Média: ${Utils.formatCurrency(m.averageItemPrice)}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: isCheapest ? Colors.green.shade700 : Colors.grey.shade600,
                                        ),
                                      )
                                    else
                                      Text(
                                        'Toque para ver detalhes',
                                        style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            icon: Icon(Icons.directions_rounded, color: primary, size: 22),
                            tooltip: 'Como Chegar',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              if (m.latitude != null && m.longitude != null) {
                                _openNavigation(m.latitude!, m.longitude!, m.supermarketName);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          if (_isLoading)
            Container(
              color: Colors.black.withValues(alpha: 0.20),
              child: const Center(
                child: Card(
                  elevation: 8,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(width: 16),
                        Text('Carregando mapa...', style: TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
