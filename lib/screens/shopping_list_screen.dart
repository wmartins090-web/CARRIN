import 'market_map_screen.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:vibration/vibration.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/item.dart';
import '../providers/item_provider.dart';
import '../services/utils.dart';
import '../widgets/item_search_delegate.dart';
import '../widgets/cart_loading_indicator.dart';
import '../widgets/counting_text.dart';
import '../widgets/skeleton_loader.dart';
import '../widgets/sync_indicator.dart';
import '../widgets/floating_calculator_popup.dart';
import '../widgets/shopping_filter_bottom_sheet.dart';
import '../widgets/weight_calculator_dialog.dart';
import '../widgets/pdf_export_dialog.dart';
import '../widgets/assistive_calculator_button.dart';
import '../widgets/market_lock_overlay.dart';
import '../widgets/market_and_purpose_widgets.dart';

import 'barcode_scanner_screen.dart';
import 'receipt_scanner_screen.dart';
import '../services/barcode_lookup_service.dart';

/// The main shopping list view for a specific month.
/// 
/// Features a complex layout using Slivers for performance and sticky headers.
/// Supports batch editing (long press to select), barcode scanning, 
/// categorization, and PDF export.
class ShoppingListScreen extends StatefulWidget {
  const ShoppingListScreen({super.key});

  @override
  State<ShoppingListScreen> createState() => _ShoppingListScreenState();
}

class _ShoppingListScreenState extends State<ShoppingListScreen> with SingleTickerProviderStateMixin {
  final currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
  bool _readyToRefresh = false;
  bool _manualLoading = false;
  
  SortOption _currentSort = SortOption.category; 
  bool _isAscending = true; 
  bool _hideZeroQuantity = false;
  List<String> _selectedCategories = [];

  bool _isSelectionMode = false;
  final Set<int> _selectedItemIndexes = {};

  bool _marketMode = false;
  bool _isMarketLocked = false;
  Timer? _marketInactivityTimer;
  Key _limiterKey = UniqueKey();
  int? _expandedIndex;
  final _inlinePriceController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = Provider.of<ItemProvider>(context, listen: false);
      if (provider.items.isEmpty) {
        provider.loadItems();
      }
    });
  }

  @override
  void dispose() {
    _marketInactivityTimer?.cancel();
    if (_marketMode) {
      WakelockPlus.disable();
    }
    _inlinePriceController.dispose();
    super.dispose();
  }

  void _onUserInteraction() {
    if (!_marketMode || _isMarketLocked) return;
    _resetMarketInactivityTimer();
  }

  void _resetMarketInactivityTimer() {
    _marketInactivityTimer?.cancel();
    if (_marketMode && !_isMarketLocked) {
      _marketInactivityTimer = Timer(const Duration(seconds: 15), () {
        if (mounted && _marketMode && !_isMarketLocked && (ModalRoute.of(context)?.isCurrent ?? true)) {
          setState(() {
            _isMarketLocked = true;
          });
          try {
            Vibration.vibrate(duration: 40);
          } catch (_) {
            HapticFeedback.mediumImpact();
          }
        }
      });
    }
  }

  void _unlockMarketMode() {
    setState(() {
      _isMarketLocked = false;
    });
    _resetMarketInactivityTimer();
  }

  void _triggerListAnimation() {
    if (mounted) {
      setState(() {
        _limiterKey = UniqueKey();
      });
    }
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) _selectedItemIndexes.clear();
    });
  }

  void _toggleItemSelection(int index) {
    setState(() {
      if (_selectedItemIndexes.contains(index)) {
        _selectedItemIndexes.remove(index);
        if (_selectedItemIndexes.isEmpty) _isSelectionMode = false;
      } else {
        _selectedItemIndexes.add(index);
        _isSelectionMode = true;
      }
    });
  }

  void _handleBatchAction(String action) async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    final itemsToProcess = provider.items.where((it) => _selectedItemIndexes.contains(it.index)).toList();

    if (action == 'delete') {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: const Text('Excluir Itens'),
          content: Text('Tem certeza que deseja excluir ${itemsToProcess.length} itens?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir', style: TextStyle(color: Colors.red))),
          ],
        ),
      );
      if (proceed != true) return;

      for (var it in itemsToProcess) {
        await provider.removeItem(it.index!);
      }
    } else if (action == 'bought') {
      for (var it in itemsToProcess) {
        if (!it.isBought) await provider.toggleBought(it);
      }
    } else if (action == 'not_bought') {
      for (var it in itemsToProcess) {
        if (it.isBought) await provider.toggleBought(it);
      }
    }

    _toggleSelectionMode();
  }

  void _showAnimatedDialog(BuildContext context, Widget dialog) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, anim1, anim2) => dialog,
      transitionBuilder: (context, anim1, anim2, child) {
        final curve = Curves.easeOutBack.transform(anim1.value);
        return Transform.scale(
          scale: curve,
          child: Opacity(
            opacity: anim1.value,
            child: child,
          ),
        );
      },
    );
  }

  void _toggleFinalizeStatus(BuildContext context, ItemProvider provider) {
    final bool isFinalized = provider.isCurrentMonthFinalized;
    if (isFinalized) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: const Text('Reabrir Compra', style: TextStyle(fontWeight: FontWeight.bold)),
          content: const Text('Deseja reabrir esta lista para edições? As alterações serão sincronizadas.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                provider.finalizeMonth(provider.currentMonth, finalize: false);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Compra reaberta com sucesso!'))
                );
              },
              child: const Text('Reabrir'),
            ),
          ],
        ),
      );
    } else {
      final double total = provider.totalCost;
      final double budget = provider.budget;
      final int totalItems = provider.items.length;
      final int boughtItems = provider.items.where((it) => it.isBought).length;

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          title: const Text('Finalizar Compra', style: TextStyle(fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Deseja concluir e fechar esta lista de compras? Ela ficará em modo leitura para evitar edições acidentais.'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Total Gasto:', style: TextStyle(fontSize: 13, color: Colors.grey)),
                        Text(Utils.formatCurrency(total), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Orçamento:', style: TextStyle(fontSize: 13, color: Colors.grey)),
                        Text(Utils.formatCurrency(budget), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.grey)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Itens Comprados:', style: TextStyle(fontSize: 13, color: Colors.grey)),
                        Text('$boughtItems / $totalItems', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.fact_check_outlined, size: 16, color: Colors.teal),
              label: const Text('Conferir Cupom', style: TextStyle(color: Colors.teal)),
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReceiptScannerScreen(
                      cartItemsToCompare: provider.items,
                      isVerificationMode: true,
                    ),
                  ),
                );
              },
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                provider.finalizeMonth(provider.currentMonth, finalize: true);
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Compra finalizada com sucesso!'))
                );
              },
              child: const Text('Finalizar'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final itemProvider = Provider.of<ItemProvider>(context);
    final bool showLoader = itemProvider.isLoading;
    final bool isSyncingBg = itemProvider.isSyncingBackground || _manualLoading;

    List<Item> filteredItems = List.from(itemProvider.items);
    
    if (_hideZeroQuantity) {
      filteredItems = filteredItems.where((it) => it.quantity > 0).toList();
    }
    
    if (_selectedCategories.isNotEmpty) {
      filteredItems = filteredItems.where((it) => _selectedCategories.contains(it.category)).toList();
    }

    filteredItems.sort((a, b) {
      int result;
      switch (_currentSort) {
        case SortOption.name:
          result = Utils.normalize(a.name).compareTo(Utils.normalize(b.name));
          break;
        case SortOption.quantity:
          result = a.quantity.compareTo(b.quantity);
          break;
        case SortOption.price:
          result = a.unitPrice.compareTo(b.unitPrice);
          break;
        case SortOption.category:
          result = a.category.compareTo(b.category);
          if (result == 0) result = Utils.normalize(a.name).compareTo(Utils.normalize(b.name));
          break;
      }
      return _isAscending ? result : -result;
    });

    final groupedItems = <String, List<Item>>{};
    if (_currentSort == SortOption.category) {
      for (var it in filteredItems) {
        groupedItems.putIfAbsent(it.category, () => []).add(it);
      }
    }

    final List<dynamic> flatList = [];
    double precomputedTotal = 0.0;
    double precomputedTotalItems = 0.0;
    double precomputedBoughtItems = 0.0;
    double estimatedRemaining = 0.0;
    for (var it in filteredItems) {
      precomputedTotalItems += it.quantity;
      if (it.isBought) {
        precomputedBoughtItems += it.quantity;
        precomputedTotal += it.totalPrice;
      } else {
        if (it.unitPrice > 0) {
          estimatedRemaining += (it.quantity > 0 ? it.quantity : 1) * it.unitPrice;
        } else {
          final hist = itemProvider.getPriceHistorySync(it.name, barcode: it.barcode);
          if (hist.isNotEmpty) {
            final lastP = (hist.last['price'] as num?)?.toDouble() ?? 0.0;
            if (lastP > 0) {
              estimatedRemaining += (it.quantity > 0 ? it.quantity : 1) * lastP;
            }
          }
        }
      }
    }
    final double projectedTotal = precomputedTotal + estimatedRemaining;

    if (_currentSort == SortOption.category) {
      groupedItems.forEach((category, items) {
        flatList.add(category); 
        flatList.addAll(items);
      });
    } else {
      flatList.addAll(filteredItems);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = Theme.of(context).cardColor;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: cardColor,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _onUserInteraction(),
        onPointerMove: (_) => _onUserInteraction(),
        child: Stack(
          children: [
            Scaffold(
              extendBody: true,
            body: SafeArea(
              bottom: false,
              child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollEndNotification) {
                      if (_readyToRefresh && !showLoader) {
                        setState(() => _manualLoading = true);
                        itemProvider.loadItems(force: true).then((_) {
                          if (mounted) {
                            setState(() => _manualLoading = false);
                            _triggerListAnimation();
                          }
                        });
                        _readyToRefresh = false;
                      }
                    }
                    if (notification is ScrollUpdateNotification) {
                      if (notification.metrics.pixels < -50) _readyToRefresh = true;
                    }
                    return false;
                  },
                  child: AbsorbPointer(
                    absorbing: showLoader,
                    child: CustomScrollView(
                        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                        cacheExtent: 200, 
                        slivers: [
                           SliverAppBar(
                            pinned: true,
                            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
                            surfaceTintColor: Colors.transparent,
                            scrolledUnderElevation: 0,
                            title: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(itemProvider.currentMonth, style: const TextStyle(fontWeight: FontWeight.bold)),
                                if (itemProvider.selectedSupermarketFilter != null || itemProvider.detectedSupermarket != null)
                                  InkWell(
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(builder: (_) => const MarketMapScreen()),
                                      );
                                    },
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                      child: Text(
                                        '📍 ${itemProvider.selectedSupermarketFilter ?? itemProvider.detectedSupermarket!['name']}',
                                        style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.w600),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            centerTitle: true,
                            actions: [
                              const SyncIndicator(),
                              IconButton(
                                icon: const Icon(Icons.search),
                                onPressed: showLoader ? null : () {
                                  showSearch(
                                    context: context,
                                    delegate: ItemSearchDelegate(
                                      itemProvider,
                                      onEdit: (item) => _showEditDialog(context, item),
                                      onDelete: (index) => _confirmDelete(context, index),
                                    ),
                                  );
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  _marketMode ? Icons.store_rounded : Icons.store_outlined,
                                  color: _marketMode ? Colors.amber : null,
                                ),
                                tooltip: _marketMode ? 'Modo Mercado Ativo (Tela Ligada & Bloqueio Ocioso)' : 'Ativar Modo Mercado',
                                onPressed: () {
                                  setState(() {
                                    _marketMode = !_marketMode;
                                    if (_marketMode) {
                                      WakelockPlus.enable();
                                      Vibration.vibrate(duration: 40);
                                      _isMarketLocked = false;
                                      _resetMarketInactivityTimer();
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Row(
                                            children: [
                                              Icon(Icons.storefront_rounded, color: Colors.amber),
                                              SizedBox(width: 8),
                                              Expanded(child: Text('Modo Mercado ativo! A tela ficará ligada e bloqueará toques após 15s ocioso.')),
                                            ],
                                          ),
                                          duration: Duration(seconds: 4),
                                        ),
                                      );
                                    } else {
                                      _isMarketLocked = false;
                                      _marketInactivityTimer?.cancel();
                                      WakelockPlus.disable();
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Modo Mercado desativado.'),
                                          duration: Duration(seconds: 2),
                                        ),
                                      );
                                    }
                                  });
                                },
                              ),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                tooltip: 'Mais opções',
                                onSelected: (value) async {
                                  if (value == 'receipt') {
                                    if (context.mounted) {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => const ReceiptScannerScreen()));
                                    }
                                  } else if (value == 'verify_receipt') {
                                    if (context.mounted) {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => ReceiptScannerScreen(
                                            cartItemsToCompare: itemProvider.items,
                                            isVerificationMode: true,
                                          ),
                                        ),
                                      );
                                    }
                                  } else if (value == 'share') {
                                    _shareList(context, itemProvider);
                                  } else if (value == 'finalize') {
                                    _toggleFinalizeStatus(context, itemProvider);
                                  } else if (value == 'purpose_caps') {
                                    showDialog(
                                      context: context,
                                      builder: (_) => PurposeAndCapsDialog(provider: itemProvider),
                                    );
                                  } else if (value == 'rateio') {
                                    showDialog(
                                      context: context,
                                      builder: (_) => RateioDialog(
                                        totalSpent: itemProvider.totalCost,
                                        listTitle: itemProvider.currentMonth,
                                      ),
                                    );
                                  } else if (value == 'gps_market') {
                                    showDialog(
                                      context: context,
                                      builder: (_) => SaveCurrentMarketDialog(provider: itemProvider),
                                    );
                                  }
                                },
                                itemBuilder: (context) => [
                                  const PopupMenuItem(
                                    value: 'purpose_caps',
                                    child: ListTile(
                                      leading: Icon(Icons.tune_rounded),
                                      title: Text('Finalidade & Metas'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'rateio',
                                    child: ListTile(
                                      leading: Icon(Icons.groups_rounded, color: Colors.deepOrange),
                                      title: Text('Rateio / Divisão por Pessoa'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'gps_market',
                                    child: ListTile(
                                      leading: Icon(Icons.add_location_alt_outlined, color: Colors.blue),
                                      title: Text('Salvar Mercado por GPS'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'verify_receipt',
                                    child: ListTile(
                                      leading: Icon(Icons.fact_check_outlined, color: Colors.teal),
                                      title: Text('Conferir Cupom Fiscal (vs Carrinho)'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'receipt',
                                    child: ListTile(
                                      leading: Icon(Icons.receipt_long_outlined),
                                      title: Text('Escanear Nota Fiscal'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'share',
                                    child: ListTile(
                                      leading: Icon(Icons.share_outlined),
                                      title: Text('Compartilhar Lista'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'finalize',
                                    child: ListTile(
                                      leading: Icon(
                                        itemProvider.isCurrentMonthFinalized ? Icons.lock_open : Icons.lock_outline,
                                        color: itemProvider.isCurrentMonthFinalized ? Colors.orange : Colors.green,
                                      ),
                                      title: Text(itemProvider.isCurrentMonthFinalized ? 'Reabrir Compra' : 'Finalizar Compra'),
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _StickyHealthHeaderDelegate(
                              provider: itemProvider,
                              onEditBudget: () {
                                if (itemProvider.isCurrentMonthFinalized) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Esta lista está finalizada e não pode ser editada.'))
                                  );
                                } else {
                                  _showEditBudgetDialog(context, itemProvider);
                                }
                              },
                              totalItems: precomputedTotalItems,
                              boughtItems: precomputedBoughtItems,
                              totalCost: precomputedTotal,
                              projectedTotal: projectedTotal,
                            ),
                          ),
                          if (itemProvider.isCurrentMonthFinalized)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.green.withValues(alpha: 0.25)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.lock_outline, color: Colors.green, size: 20),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Text(
                                          'Compra Finalizada. A lista está em modo de leitura.',
                                          style: TextStyle(
                                            color: Colors.green[800],
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                 ),
                              ),
                            ),

                          if (_marketMode)
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.store_rounded, color: Colors.amber, size: 22),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Modo Mercado Ativo • Tela Sempre Ligada',
                                              style: TextStyle(
                                                color: Theme.of(context).brightness == Brightness.dark
                                                    ? Colors.amberAccent
                                                    : Colors.amber[900],
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            Text(
                                              '${itemProvider.items.where((it) => it.isBought).length} de ${itemProvider.items.length} itens no carrinho',
                                              style: const TextStyle(fontSize: 11, color: Colors.grey),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.close, size: 18),
                                        tooltip: 'Sair do Modo Mercado',
                                        onPressed: () {
                                          setState(() {
                                            _marketMode = false;
                                            _isMarketLocked = false;
                                            _marketInactivityTimer?.cancel();
                                            WakelockPlus.disable();
                                          });
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                          if (itemProvider.items.isEmpty && showLoader)
                            const SliverFillRemaining(
                              child: ListSkeleton(),
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.only(bottom: 120),
                              sliver: SliverList(
                                key: _limiterKey,
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    if (index >= flatList.length) return null;
                                    final element = flatList[index];

                                    if (element is String) {
                                      final categoryItems = groupedItems[element]!;
                                      return _buildCategoryHeader(context, element, categoryItems.length);
                                    } else {
                                      return _buildItemTile(element as Item, itemProvider);
                                    }
                                  },
                                  childCount: flatList.length,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ),
                ),
                if (showLoader)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: CartLoadingIndicator(message: 'Carregando...'),
                    ),
                  ),
                // Subtle top indicator for background sync
                if (isSyncingBg && !showLoader)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(
                      minHeight: 2,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).primaryColor.withValues(alpha: 0.5)),
                    ),
                  ),
                
                if (_isSelectionMode)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).primaryColor,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10, offset: const Offset(0, -2))],
                      ),
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                          child: Row(
                            children: [
                              Text('${_selectedItemIndexes.length} selecionados', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary, fontWeight: FontWeight.bold)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.check_circle_outline, color: Colors.greenAccent),
                                onPressed: () => _handleBatchAction('bought'),
                                tooltip: 'Marcar Comprados',
                              ),
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.orangeAccent),
                                onPressed: () => _handleBatchAction('not_bought'),
                                tooltip: 'Desmarcar Comprados',
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                onPressed: () => _handleBatchAction('delete'),
                                tooltip: 'Excluir Selecionados',
                              ),
                              const SizedBox(width: 8),
                              TextButton(
                                onPressed: _toggleSelectionMode,
                                child: Text('CANCELAR', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.8), fontSize: 12)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _isSelectionMode ? null : Builder(
        builder: (context) {
          final double bottomPadding = MediaQuery.of(context).padding.bottom;
          final double totalHeight = 100.0 + bottomPadding;

          return SizedBox(
            height: totalHeight,
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                CustomPaint(
                  size: Size(MediaQuery.of(context).size.width, totalHeight),
                  painter: _WavyFooterPainter(Theme.of(context).cardColor),
                ),
                Positioned(
                  bottom: bottomPadding,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 75,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    alignment: Alignment.center,
                    child: Row(
                      children: [
                        Expanded(
                          child: _buildFooterButton(
                            context, 
                            icon: Icons.edit_note_rounded, 
                            label: 'Novo Item', 
                            onTap: showLoader || itemProvider.isCurrentMonthFinalized ? null : () => _showEditDialog(context, null)
                          ),
                        ),
                        const SizedBox(width: 80), 
                        Expanded(
                          child: _buildFooterButton(
                            context, 
                            icon: Icons.filter_list_rounded, 
                            label: 'Filtros', 
                            iconColor: (_hideZeroQuantity || _selectedCategories.isNotEmpty) ? Colors.orangeAccent : null,
                            onTap: showLoader ? null : () => _showFilterBottomSheet(context)
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  bottom: 12 + bottomPadding, 
                  child: FloatingActionButton(
                    heroTag: 'scan_fab_wavy',
                    onPressed: showLoader || itemProvider.isCurrentMonthFinalized ? null : () async {
                  if (itemProvider.priceHistoryCache.isEmpty) {
                    itemProvider.loadFullPriceHistory();
                  }
                  if (!context.mounted) return;
                  final result = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()));
                  
                  if (result != null) {
                    final cleanBarcode = Item.parseBarcode(result) ?? result.trim();
                    if (cleanBarcode.isEmpty) return;

                    // 1. Procura se o item já está na lista atual com esse barcode direto
                    Item? matchedItem;
                    for (var it in itemProvider.items) {
                      if (Item.parseBarcode(it.barcode) == cleanBarcode) {
                        matchedItem = it;
                        break;
                      }
                    }

                    // 2. Verifica cache síncrono (local ou API já em memória) sem bloquear
                    final cachedInfo = BarcodeLookupService.instance.getCachedOrLocal(
                      cleanBarcode,
                      itemProvider: itemProvider,
                    );

                    if (matchedItem == null && cachedInfo != null) {
                      final prodNormalized = Utils.normalize(cachedInfo.name);
                      for (var it in itemProvider.items) {
                        if (Utils.normalize(it.name) == prodNormalized) {
                          matchedItem = it;
                          if (it.barcode == null || it.barcode!.trim().isEmpty) {
                            final updatedWithBarcode = it.copyWith(barcode: cleanBarcode);
                            itemProvider.updateItem(updatedWithBarcode);
                            matchedItem = updatedWithBarcode;
                          }
                          break;
                        }
                      }
                    }

                    if (!context.mounted) return;

                    if (matchedItem != null) {
                      // Item já existe na lista: abre diretamente no menu de edição
                      _showEditDialog(
                        context,
                        matchedItem,
                        scannedBarcode: cleanBarcode,
                      );
                    } else {
                      // Vai direto para o menu de edição de produto (se ainda não estiver no cache local, busca na API em tempo real dentro do modal!)
                      final lastPrice = cachedInfo?.lastPrice;
                      _showEditDialog(
                        context,
                        null,
                        scannedBarcode: cleanBarcode,
                        prefilledName: cachedInfo?.name,
                        prefilledCategory: cachedInfo?.category,
                        prefilledPrice: (lastPrice != null && lastPrice > 0) ? lastPrice : null,
                        lookupOnlineOnOpen: cachedInfo == null,
                      );
                    }
                  }
                },
                backgroundColor: itemProvider.isCurrentMonthFinalized ? Colors.grey : Theme.of(context).primaryColor,
                elevation: 6,
                shape: const CircleBorder(),
                child: const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 28),
              ),
            ),
          ],
        ),
      );
    },
  ),
),
if (!_isSelectionMode)
  const AssistiveCalculatorButton(),
if (_isMarketLocked)
  MarketLockOverlay(
    onUnlock: _unlockMarketMode,
    totalCost: itemProvider.totalCost,
    boughtItemsCount: itemProvider.items.where((it) => it.isBought).length,
    totalItemsCount: itemProvider.items.length,
    budget: itemProvider.budget,
  ),
],
),
),
);
  }

  Widget _buildFooterButton(BuildContext context, {
    required IconData icon, 
    required String label, 
    required VoidCallback? onTap,
    Color? iconColor,
  }) {
    final foregroundColor = iconColor ?? Theme.of(context).colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: foregroundColor, size: 24),
          const SizedBox(height: 2),
          Text(
            label, 
            style: TextStyle(
              color: foregroundColor, 
              fontSize: 10, 
              fontWeight: FontWeight.bold
            )
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryHeader(BuildContext context, String category, int count) {
    final emoji = ItemProvider.categoryEmojis[category] ?? '📦';
    
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Row(
        children: [
          Text('$emoji ', style: const TextStyle(fontSize: 18)),
          Text(category.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey[500], letterSpacing: 1.2)),
          const Spacer(),
          Text('$count itens', style: TextStyle(fontSize: 12, color: Colors.grey[400])),
        ],
      ),
    );
  }

  void _saveCurrentExpandedItemPrice(ItemProvider itemProvider) {
    if (_expandedIndex != null) {
      try {
        final item = itemProvider.items.firstWhere((it) => it.index == _expandedIndex);
        final priceText = _inlinePriceController.text.trim();
        final newPrice = Utils.parseCurrency(priceText);
        if (newPrice != item.unitPrice) {
          final updatedItem = item.copyWith(unitPrice: newPrice);
          itemProvider.updateItem(updatedItem);
        }
      } catch (_) {}
    }
  }

  void _saveInlinePriceAndCollapse(Item item, ItemProvider itemProvider) {
    final priceText = _inlinePriceController.text.trim();
    final newPrice = Utils.parseCurrency(priceText);
    if (newPrice != item.unitPrice) {
      final updatedItem = item.copyWith(unitPrice: newPrice);
      itemProvider.updateItem(updatedItem);
    }
    setState(() {
      _expandedIndex = null;
    });
  }

  void _updateItemQty(Item item, ItemProvider itemProvider, double newQty) {
    double price = item.unitPrice;
    if (_expandedIndex == item.index && _inlinePriceController.text.trim().isNotEmpty) {
      price = Utils.parseCurrency(_inlinePriceController.text);
    }
    final updatedItem = item.copyWith(
      quantity: newQty,
      unitPrice: price,
    );
    itemProvider.updateItem(updatedItem);
  }

  void _updateItemUnit(Item item, ItemProvider itemProvider, bool isKg) {
    double price = item.unitPrice;
    if (_expandedIndex == item.index && _inlinePriceController.text.trim().isNotEmpty) {
      price = Utils.parseCurrency(_inlinePriceController.text);
    }
    final updatedItem = item.copyWith(
      isKg: isKg,
      unitPrice: price,
    );
    itemProvider.updateItem(updatedItem);
  }

  Widget _buildItemTile(Item item, ItemProvider itemProvider) {
    final bool isSelected = _selectedItemIndexes.contains(item.index);
    final bool isExpanded = _expandedIndex == item.index;
    
    final badgeInfo = itemProvider.getPriceBadgeInfo(item);
    final String status = badgeInfo['status'] as String;
    final Color statusColor = (status == 'Barato' || status == 'Na Média')
        ? Theme.of(context).colorScheme.primary
        : (status == 'Caro' ? Theme.of(context).colorScheme.error : (badgeInfo['color'] as Color));

    return Material(
      color: isSelected ? Theme.of(context).primaryColor.withValues(alpha: 0.15) : Colors.transparent,
      child: InkWell(
        onTap: () {
          if (_isSelectionMode) {
            _toggleItemSelection(item.index!);
          } else {
            setState(() {
              if (isExpanded) {
                _saveInlinePriceAndCollapse(item, itemProvider);
              } else {
                _saveCurrentExpandedItemPrice(itemProvider);
                _expandedIndex = item.index;
                _inlinePriceController.text = item.unitPrice > 0 ? Utils.formatCurrencyInput(item.unitPrice) : '';
                _inlinePriceController.selection = TextSelection.collapsed(offset: _inlinePriceController.text.length);
              }
            });
          }
        },
        onLongPress: itemProvider.isCurrentMonthFinalized ? null : () {
          Vibration.vibrate(duration: 50);
          _toggleItemSelection(item.index!);
        },
        child: Opacity(
          opacity: item.isBought ? 0.5 : 1.0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: _marketMode ? 16 : 12),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.05)))
                ),
                child: Row(
                  children: [
                    if (_isSelectionMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: Icon(
                          isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                          color: isSelected ? Theme.of(context).primaryColor : Colors.grey,
                        ),
                      )
                    else
                      SizedBox(
                        width: _marketMode ? 48 : 40,
                        height: _marketMode ? 48 : 40,
                        child: Checkbox(
                          value: item.isBought,
                          onChanged: itemProvider.isCurrentMonthFinalized ? null : (_) {
                            Vibration.vibrate(duration: 40);
                            itemProvider.toggleBought(item);
                          },
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(_marketMode ? 8 : 6)),
                          activeColor: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name, 
                            style: TextStyle(
                              fontSize: _marketMode ? 18 : 16, 
                              fontWeight: FontWeight.bold, 
                              decoration: item.isBought ? TextDecoration.lineThrough : null
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 6,
                            children: [
                              Text('${Utils.formatNumber(item.quantity)}${item.isKg ? "kg" : " un"} x ${Utils.formatCurrency(item.unitPrice)}', style: TextStyle(color: Colors.grey[500], fontSize: _marketMode ? 13 : 12)),
                              if (item.supermarket != null && item.supermarket!.trim().isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                                  ),
                                  child: Text(
                                    item.supermarket!,
                                    style: const TextStyle(fontSize: 10, color: Colors.blue, fontWeight: FontWeight.bold),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          Utils.formatCurrency(item.totalPrice),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        InkWell(
                          onTap: () => _showPriceHistory(context, item, itemProvider),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(status, style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.bold)),
                              const SizedBox(width: 2),
                              Icon(Icons.info, size: 12, color: statusColor.withValues(alpha: 0.7)),
                            ],
                          ),
                        )
                      ],
                    )
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                child: isExpanded
                    ? GestureDetector(
                        onTap: () {}, // Prevents tapping on the panel from bubbling up to InkWell
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                          decoration: BoxDecoration(
                            color: Theme.of(context).brightness == Brightness.dark
                                ? Colors.white.withValues(alpha: 0.03)
                                : Theme.of(context).primaryColor.withValues(alpha: 0.03),
                            border: Border(bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.08))),
                          ),
                          child: Row(
                            children: [
                              // Quantity Controls
                              IconButton(
                                icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 24),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: itemProvider.isCurrentMonthFinalized ? null : () {
                                  double step = item.isKg ? 0.5 : 1.0;
                                  double newVal = (item.quantity - step).clamp(0.0, 9999.0);
                                  _updateItemQty(item, itemProvider, newVal);
                                },
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                child: Text(
                                  Utils.formatNumber(item.quantity),
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add_circle_outline, color: Colors.green, size: 24),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: itemProvider.isCurrentMonthFinalized ? null : () {
                                  double step = item.isKg ? 0.5 : 1.0;
                                  double newVal = (item.quantity + step).clamp(0.0, 9999.0);
                                  _updateItemQty(item, itemProvider, newVal);
                                },
                              ),
                              const SizedBox(width: 12),
                              // Kg/Un Toggle
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.grey.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    GestureDetector(
                                      onTap: itemProvider.isCurrentMonthFinalized ? null : () => _updateItemUnit(item, itemProvider, false),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: !item.isKg ? Theme.of(context).primaryColor.withValues(alpha: 0.2) : Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text('Un', style: TextStyle(fontWeight: !item.isKg ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: itemProvider.isCurrentMonthFinalized ? null : () => _updateItemUnit(item, itemProvider, true),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: item.isKg ? Theme.of(context).primaryColor.withValues(alpha: 0.2) : Colors.transparent,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text('Kg', style: TextStyle(fontWeight: item.isKg ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Price Field
                              Expanded(
                                child: SizedBox(
                                  height: 38,
                                  child: TextField(
                                    controller: _inlinePriceController,
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [CurrencyInputFormatter()],
                                    style: const TextStyle(fontSize: 14),
                                    readOnly: itemProvider.isCurrentMonthFinalized,
                                    decoration: InputDecoration(
                                      prefixText: 'R\$ ',
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                      hintText: '0,00',
                                      suffixIcon: itemProvider.isCurrentMonthFinalized ? null : IconButton(
                                        icon: const Icon(Icons.check, size: 16, color: Colors.green),
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          final priceText = _inlinePriceController.text.trim();
                                          final newPrice = Utils.parseCurrency(priceText);
                                          final updatedItem = item.copyWith(unitPrice: newPrice);
                                          itemProvider.updateItem(updatedItem);
                                          FocusScope.of(context).unfocus();
                                        },
                                      ),
                                    ),
                                    onSubmitted: itemProvider.isCurrentMonthFinalized ? null : (_) {
                                      final priceText = _inlinePriceController.text.trim();
                                      final newPrice = Utils.parseCurrency(priceText);
                                      final updatedItem = item.copyWith(unitPrice: newPrice);
                                      itemProvider.updateItem(updatedItem);
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Editar Tudo Button
                              IconButton(
                                icon: Icon(Icons.edit_note, color: itemProvider.isCurrentMonthFinalized ? Colors.grey : Theme.of(context).primaryColor, size: 24),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: itemProvider.isCurrentMonthFinalized ? null : () {
                                  // Save price first
                                  final priceText = _inlinePriceController.text.trim();
                                  final newPrice = Utils.parseCurrency(priceText);
                                  final updatedItem = item.copyWith(unitPrice: newPrice);
                                  _showEditDialog(context, updatedItem);
                                },
                                tooltip: 'Editar Tudo',
                              )
                            ],
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showPriceHistory(BuildContext context, Item item, ItemProvider provider) async {
    final existingHistory = provider.getPriceHistorySync(item.name, barcode: item.barcode);
    if (provider.priceHistoryCache.isEmpty || existingHistory.isEmpty) {
      showDialog(
        context: context, 
        barrierDismissible: false,
        builder: (context) => const Center(child: CircularProgressIndicator())
      );
      try {
        await provider.loadFullPriceHistory();
      } finally {
        if (context.mounted) Navigator.pop(context);
      }
    }
    
    final activeMonth = provider.currentMonth;
    final scrollController = ScrollController();

    if (context.mounted) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent, 
        builder: (ctx) => Consumer<ItemProvider>(
          builder: (context, itemProvider, _) {
            final history = itemProvider.getPriceHistorySync(item.name, barcode: item.barcode, sorted: true);
            int currentIndex = history.indexWhere((entry) => 
              Utils.normalize(entry['month'].toString()) == Utils.normalize(activeMonth)
            );

            if (currentIndex != -1) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (scrollController.hasClients) {
                    scrollController.animateTo(
                      currentIndex * 72.0, 
                      duration: const Duration(seconds: 1),
                      curve: Curves.easeInOutCubic,
                    );
                  }
                });
              });
            }

            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
              ),
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  Text('Histórico: ${item.name}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
                  const SizedBox(height: 24),
                  if (history.isEmpty) 
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: Text('Nenhum registro anterior encontrado.', style: TextStyle(color: Colors.grey))),
                    )
                  else
                    Builder(
                      builder: (context) {
                        final positivePrices = history
                            .map((e) => (e['price'] as num?)?.toDouble() ?? 0.0)
                            .where((p) => p > 0.01)
                            .toList();
                    final double minPrice = positivePrices.isNotEmpty
                        ? positivePrices.reduce((a, b) => a < b ? a : b)
                        : 0.0;
                    final double maxPrice = positivePrices.isNotEmpty
                        ? positivePrices.reduce((a, b) => a > b ? a : b)
                        : 0.0;
                    final double priceDiff = maxPrice - minPrice;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (positivePrices.length > 1)
                          Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).cardColor,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.insights, size: 16, color: Colors.amber),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Menor: ${Utils.formatCurrency(minPrice)}',
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green),
                                    ),
                                  ],
                                ),
                                Text(
                                  'Maior: ${Utils.formatCurrency(maxPrice)}',
                                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                                ),
                                Text(
                                  'Dif: ${Utils.formatCurrency(priceDiff)}',
                                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor),
                                ),
                              ],
                            ),
                          ),
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
                          child: ListView.separated(
                            controller: scrollController,
                            shrinkWrap: true,
                            itemCount: history.length,
                            separatorBuilder: (context, index) => Divider(color: Colors.grey.withValues(alpha: 0.05), height: 1),
                            itemBuilder: (context, index) {
                              final entry = history[index];
                              final month = entry['month'] as String;
                              final price = (entry['price'] as num?)?.toDouble() ?? 0.0;
                              final isCurrent = Utils.normalize(month) == Utils.normalize(activeMonth);
                              final isBestPrice = price > 0.01 && (price - minPrice).abs() < 0.005;

                              final isHigher = price > item.unitPrice && item.unitPrice > 0.01;
                              final isLower = price < item.unitPrice && item.unitPrice > 0.01;

                              return TweenAnimationBuilder<double>(
                                duration: const Duration(milliseconds: 1500),
                                curve: Curves.easeOutExpo,
                                tween: Tween(begin: isCurrent ? 1.0 : 0.0, end: 0.0),
                                builder: (context, value, child) {
                                  return Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).primaryColor.withValues(alpha: 0.15 * value),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: ListTile(
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: (isBestPrice ? Colors.amber : (isCurrent ? Theme.of(context).primaryColor : (isHigher ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary))).withValues(alpha: 0.12),
                                          shape: BoxShape.circle,
                                        ),
                                        child: Icon(
                                          isBestPrice ? Icons.star_rounded : (isCurrent ? Icons.gps_fixed : (isHigher ? Icons.trending_up : (isLower ? Icons.trending_down : Icons.trending_flat))), 
                                          color: isBestPrice ? Colors.amber[800] : (isCurrent ? Theme.of(context).primaryColor : (isHigher ? Theme.of(context).colorScheme.error : (isLower ? Theme.of(context).colorScheme.primary : Colors.grey))), 
                                          size: 18,
                                        ),
                                      ),
                                      title: Row(
                                        children: [
                                          Text(
                                            month, 
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.w500,
                                              color: isCurrent ? Theme.of(context).primaryColor : null,
                                            ),
                                          ),
                                          if (isBestPrice && positivePrices.length > 1) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: Colors.amber.withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: const Text(
                                                'MELHOR',
                                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.amber),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      trailing: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            Utils.formatCurrency(price), 
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: isBestPrice ? Theme.of(context).colorScheme.primary : (isCurrent ? Theme.of(context).primaryColor : null),
                                            ),
                                          ),
                                          if (isCurrent)
                                            Text('ESTE MÊS', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Theme.of(context).primaryColor.withValues(alpha: 0.6)))
                                          else if (item.unitPrice > 0)
                                            Text(
                                              isHigher ? '+ ${Utils.formatCurrency(price - item.unitPrice)}' : (isLower ? '- ${Utils.formatCurrency(item.unitPrice - price)}' : 'Mesmo preço'),
                                              style: TextStyle(fontSize: 10, color: isHigher ? Theme.of(context).colorScheme.error : (isLower ? Theme.of(context).colorScheme.primary : Colors.grey)),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                ],
              ),
            );
          },
        ),
      );
    }
  }

  void _showFilterBottomSheet(BuildContext context) {
    ShoppingFilterBottomSheet.show(
      context,
      isAscending: _isAscending,
      hideZeroQuantity: _hideZeroQuantity,
      currentSort: _currentSort,
      selectedCategories: _selectedCategories,
      onAscendingChanged: (val) {
        setState(() {
          _isAscending = val;
          _triggerListAnimation();
        });
      },
      onHideZeroQuantityChanged: (val) {
        setState(() {
          _hideZeroQuantity = val;
          _triggerListAnimation();
        });
      },
      onSortChanged: (val) {
        setState(() {
          _currentSort = val;
          _triggerListAnimation();
        });
      },
      onCategoriesChanged: (val) {
        setState(() {
          _selectedCategories = val;
          _triggerListAnimation();
        });
      },
    );
  }

  void _showEditDialog(
    BuildContext context, 
    Item? item, {
    String? scannedBarcode, 
    String? prefilledName, 
    String? prefilledCategory,
    double? prefilledPrice,
    bool lookupOnlineOnOpen = false,
  }) {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    provider.loadFullPriceHistory();

    Item? activeItem = item;
    final cleanScannedBarcode = Item.parseBarcode(scannedBarcode);
    final productFromBc = cleanScannedBarcode != null ? provider.findProductByBarcode(cleanScannedBarcode) : null;
    
    final initialName = activeItem?.name ?? prefilledName ?? (productFromBc != null ? productFromBc['name'] as String : '');
    final initialPrice = (activeItem != null && activeItem.unitPrice != 0) 
        ? Utils.formatCurrencyInput(activeItem.unitPrice) 
        : (prefilledPrice != null && prefilledPrice > 0)
            ? Utils.formatCurrencyInput(prefilledPrice)
            : (productFromBc != null && (productFromBc['price'] as num) > 0 ? Utils.formatCurrencyInput((productFromBc['price'] as num).toDouble()) : '');
    final nameController = TextEditingController(text: initialName);
    final priceController = TextEditingController(text: initialPrice);
    final qtyController = TextEditingController(text: activeItem != null ? ((activeItem.quantity != 0) ? Utils.formatNumber(activeItem.quantity) : '') : '1');
    bool isKg = activeItem?.isKg ?? (productFromBc?['isKg'] ?? false);
    String category = activeItem?.category ?? prefilledCategory ?? (productFromBc?['category'] ?? (initialName.isNotEmpty ? ItemProvider.suggestCategoryForName(initialName) : 'Mercearia'));
    
    String? currentBarcode = (activeItem != null && activeItem.barcode != null && activeItem.barcode!.trim().isNotEmpty)
        ? Item.parseBarcode(activeItem.barcode)
        : cleanScannedBarcode;
    if ((currentBarcode == null || currentBarcode.isEmpty) && activeItem != null) {
      currentBarcode = provider.findBarcodeForProductName(activeItem.name);
    }
    final barcodeController = TextEditingController(text: currentBarcode ?? '');
    final initialSupermarket = activeItem?.supermarket ?? provider.selectedSupermarketFilter ?? provider.detectedSupermarket?['name'] ?? '';
    final supermarketController = TextEditingController(text: initialSupermarket);

    // Garante que o cursor comece colapsado no final do texto para evitar seleção de bloco ao tocar
    if (nameController.text.isNotEmpty) nameController.selection = TextSelection.collapsed(offset: nameController.text.length);
    if (barcodeController.text.isNotEmpty) barcodeController.selection = TextSelection.collapsed(offset: barcodeController.text.length);
    if (supermarketController.text.isNotEmpty) supermarketController.selection = TextSelection.collapsed(offset: supermarketController.text.length);
    if (priceController.text.isNotEmpty) priceController.selection = TextSelection.collapsed(offset: priceController.text.length);
    if (qtyController.text.isNotEmpty) qtyController.selection = TextSelection.collapsed(offset: qtyController.text.length);

    final nameFocusNode = FocusNode();
    final barcodeFocusNode = FocusNode();
    final priceFocusNode = FocusNode();
    final qtyFocusNode = FocusNode();

    bool isLookingUpBarcode = lookupOnlineOnOpen && cleanScannedBarcode != null && initialName.isEmpty;
    bool onlineLookupStarted = false;
    bool filledFromBarcode = initialName.isNotEmpty && cleanScannedBarcode != null;

    _showAnimatedDialog(
      context,
      StatefulBuilder(
        builder: (dialogContext, setState) {
          if (isLookingUpBarcode && !onlineLookupStarted && cleanScannedBarcode != null) {
            onlineLookupStarted = true;
            BarcodeLookupService.instance
                .lookup(cleanScannedBarcode, itemProvider: provider)
                .then((onlineInfo) {
              if (!dialogContext.mounted) return;
              setState(() {
                isLookingUpBarcode = false;
                if (onlineInfo != null) {
                  filledFromBarcode = true;
                  if (nameController.text.trim().isEmpty) {
                    nameController.text = onlineInfo.name;
                    nameController.selection = TextSelection.collapsed(offset: onlineInfo.name.length);
                  }
                  category = onlineInfo.category;
                  if (priceController.text.trim().isEmpty &&
                      onlineInfo.lastPrice != null &&
                      onlineInfo.lastPrice! > 0) {
                    final formatted = Utils.formatCurrencyInput(onlineInfo.lastPrice!);
                    priceController.text = formatted;
                    priceController.selection = TextSelection.collapsed(offset: formatted.length);
                  }
                  if (activeItem == null) {
                    final normName = Utils.normalize(onlineInfo.name);
                    for (final it in provider.items) {
                      if (Utils.normalize(it.name) == normName) {
                        activeItem = it;
                        if (priceController.text.trim().isEmpty && it.unitPrice > 0) {
                          final formatted = Utils.formatCurrencyInput(it.unitPrice);
                          priceController.text = formatted;
                          priceController.selection = TextSelection.collapsed(offset: formatted.length);
                        }
                        if (it.quantity > 0) {
                          final formattedQty = Utils.formatNumber(it.quantity);
                          qtyController.text = formattedQty;
                          qtyController.selection = TextSelection.collapsed(offset: formattedQty.length);
                        }
                        isKg = it.isKg;
                        break;
                      }
                    }
                  }
                }
              });
            });
          }

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            title: Text(activeItem == null ? 'Novo Item' : 'Editar Item', style: const TextStyle(fontWeight: FontWeight.bold)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isLookingUpBarcode) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.teal),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Buscando produto na API...',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.teal),
                          ),
                        ],
                      ),
                    ),
                  ] else if (filledFromBarcode) ...[
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.teal.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.qr_code_scanner_rounded, size: 15, color: Colors.teal),
                          SizedBox(width: 6),
                          Text(
                            'Preenchido via código de barras',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.teal),
                          ),
                        ],
                      ),
                    ),
                  ],
                  TextField(
                    controller: nameController, 
                    focusNode: nameFocusNode,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => barcodeFocusNode.requestFocus(),
                    autofocus: activeItem == null && scannedBarcode == null, 
                    onChanged: (val) => setState(() {
                      category = ItemProvider.suggestCategoryForName(val);
                      if (barcodeController.text.isEmpty) {
                        final foundBc = provider.findBarcodeForProductName(val);
                        if (foundBc != null && foundBc.isNotEmpty) {
                          currentBarcode = foundBc;
                          barcodeController.text = foundBc;
                          barcodeController.selection = TextSelection.collapsed(offset: foundBc.length);
                        }
                      }
                    }),
                    style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black),
                    decoration: const InputDecoration(labelText: 'Nome do Produto', floatingLabelBehavior: FloatingLabelBehavior.always, border: UnderlineInputBorder())
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: supermarketController,
                    textInputAction: TextInputAction.next,
                    style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black),
                    decoration: InputDecoration(
                      labelText: 'Supermercado / Loja (Opcional)',
                      hintText: 'Ex: Supermercados Guanabara, Açougue...',
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      border: const UnderlineInputBorder(),
                      prefixIcon: const Icon(Icons.storefront_outlined, size: 20),
                      suffixIcon: provider.supermarkets.isNotEmpty
                          ? PopupMenuButton<String>(
                              icon: const Icon(Icons.arrow_drop_down),
                              tooltip: 'Escolher mercado salvo',
                              onSelected: (val) {
                                setState(() {
                                  supermarketController.text = val;
                                });
                              },
                              itemBuilder: (ctx) => provider.supermarkets.map((m) {
                                final mName = m['name'] as String;
                                return PopupMenuItem(
                                  value: mName,
                                  child: Text(mName),
                                );
                              }).toList(),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: barcodeController,
                    focusNode: barcodeFocusNode,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => priceFocusNode.requestFocus(),
                    onChanged: (v) => currentBarcode = v.trim(),
                    style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black),
                    decoration: InputDecoration(
                      labelText: 'Código de Barras',
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      border: const UnderlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(Icons.qr_code_scanner, size: 20, color: Theme.of(context).colorScheme.primary),
                        onPressed: () async {
                          final prov = Provider.of<ItemProvider>(context, listen: false);
                          if (prov.priceHistoryCache.isEmpty) prov.loadFullPriceHistory();
                          if (!context.mounted) return;
                          final result = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const BarcodeScannerScreen()));
                          if (result != null) {
                            final cleanBc = Item.parseBarcode(result) ?? result.trim();
                            final cached = BarcodeLookupService.instance.getCachedOrLocal(cleanBc, itemProvider: prov);
                            setState(() {
                              currentBarcode = cleanBc;
                              barcodeController.text = cleanBc;
                              barcodeController.selection = TextSelection.collapsed(offset: cleanBc.length);
                              if (cached != null) {
                                filledFromBarcode = true;
                                nameController.text = cached.name;
                                nameController.selection = TextSelection.collapsed(offset: cached.name.length);
                                category = cached.category;
                                if (cached.lastPrice != null && cached.lastPrice! > 0) {
                                  priceController.text = Utils.formatCurrencyInput(cached.lastPrice!);
                                  priceController.selection = TextSelection.collapsed(offset: priceController.text.length);
                                }
                              } else {
                                isLookingUpBarcode = true;
                              }
                            });
                            if (cached == null) {
                              final onlineInfo = await BarcodeLookupService.instance.lookup(cleanBc, itemProvider: prov);
                              if (!dialogContext.mounted) return;
                              setState(() {
                                isLookingUpBarcode = false;
                                if (onlineInfo != null) {
                                  filledFromBarcode = true;
                                  nameController.text = onlineInfo.name;
                                  nameController.selection = TextSelection.collapsed(offset: onlineInfo.name.length);
                                  category = onlineInfo.category;
                                  if (onlineInfo.lastPrice != null && onlineInfo.lastPrice! > 0) {
                                    priceController.text = Utils.formatCurrencyInput(onlineInfo.lastPrice!);
                                    priceController.selection = TextSelection.collapsed(offset: priceController.text.length);
                                  }
                                }
                              });
                            }
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('CATEGORIA', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                  DropdownButton<String>(
                    value: category, isExpanded: true,
                    dropdownColor: Theme.of(context).cardColor,
                    style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black),
                    underline: Container(height: 1, color: Colors.grey.withValues(alpha: 0.2)),
                    items: ItemProvider.categories.map((String value) => DropdownMenuItem<String>(value: value, child: Text(value))).toList(),
                    onChanged: (v) => setState(() => category = v!),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: priceController, 
                          focusNode: priceFocusNode,
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => qtyFocusNode.requestFocus(),
                          keyboardType: TextInputType.number,
                          inputFormatters: [CurrencyInputFormatter()],
                          style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black), 
                          decoration: InputDecoration(
                            labelText: 'Preço Unit.', 
                            hintText: '0,00', 
                            prefixText: 'R\$ ', 
                            prefixStyle: const TextStyle(fontSize: 16), 
                            floatingLabelBehavior: FloatingLabelBehavior.always,
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.calculate_outlined, size: 20),
                              tooltip: 'Calculadora',
                              onPressed: () {
                                FloatingCalculatorPopup.show(context, onUseValue: (val) {
                                  setState(() {
                                    priceController.text = Utils.formatCurrencyInput(val);
                                    priceController.selection = TextSelection.collapsed(offset: priceController.text.length);
                                  });
                                });
                              },
                            ),
                          ), 
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: qtyController, 
                          focusNode: qtyFocusNode,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => FocusScope.of(context).unfocus(),
                          style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black), 
                          decoration: const InputDecoration(labelText: 'Quantidade', floatingLabelBehavior: FloatingLabelBehavior.always), 
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Vendido por Peso (kg)', style: TextStyle(color: Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black)),
                    value: isKg, 
                    activeThumbColor: const Color(0xFFAEB2FF),
                    onChanged: (v) => setState(() => isKg = v)
                  ),
                  if (isKg) ...[
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => _showWeightCalculator(context, priceController, qtyController),
                      icon: Icon(Icons.calculate_outlined, size: 18, color: Theme.of(context).colorScheme.primary),
                      label: Text(
                        'Calcular peso pelo preço total',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary),
                      ),
                      style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    ),
                  ],
                  Builder(
                    builder: (context) {
                      final provider = Provider.of<ItemProvider>(context, listen: false);
                      final query = nameController.text.trim();
                      if (query.length < 3) return const SizedBox.shrink();
                      final history = provider.getPriceHistorySync(query, barcode: currentBarcode);
                      if (history.isEmpty) return const SizedBox.shrink();
                      
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 16),
                          const Text('HISTÓRICO DE PREÇOS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 54,
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              shrinkWrap: true,
                              itemCount: history.length,
                              itemBuilder: (context, idx) {
                                final entry = history[idx];
                                final month = entry['month'] as String;
                                final price = (entry['price'] as num).toDouble();
                                return Card(
                                  elevation: 0,
                                  color: Theme.of(context).primaryColor.withValues(alpha: 0.05),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    side: BorderSide(color: Theme.of(context).primaryColor.withValues(alpha: 0.15)),
                                  ),
                                  margin: const EdgeInsets.only(right: 8),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      setState(() {
                                        priceController.text = Utils.formatCurrencyInput(price);
                                        priceController.selection = TextSelection.collapsed(offset: priceController.text.length);
                                      });
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(month, style: TextStyle(fontSize: 10, color: Colors.grey[600], fontWeight: FontWeight.bold)),
                                          const SizedBox(height: 2),
                                          Text(Utils.formatCurrency(price), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      );
                    }
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
              ElevatedButton(
                onPressed: () async {
                  final name = nameController.text.trim();
                  if (name.isEmpty) return;
                  final provider = Provider.of<ItemProvider>(context, listen: false);

                  final double parsedQty = qtyController.text.trim().isEmpty 
                      ? 1.0 
                      : (double.tryParse(qtyController.text.replaceAll(',', '.')) ?? 1.0);
                  final String? finalBarcode = (currentBarcode != null && currentBarcode!.trim().isNotEmpty)
                      ? Item.parseBarcode(currentBarcode)
                      : Item.parseBarcode(barcodeController.text);
                  final double parsedPrice = Utils.parseCurrency(priceController.text);

                  if (activeItem == null) {
                    final normalizedNewName = Utils.normalize(name);
                    Item? existingItem;
                    for (var it in provider.items) {
                      if (Utils.normalize(it.name) == normalizedNewName || 
                          (finalBarcode != null && Item.parseBarcode(it.barcode) == finalBarcode)) {
                        existingItem = it;
                        break;
                      }
                    }

                    if (existingItem != null) {
                      // Se veio do scanner de código de barras, atualiza direto sem exibir popup de confirmação!
                      if (scannedBarcode != null) {
                        final finalSupermarket = supermarketController.text.trim().isNotEmpty
                            ? supermarketController.text.trim()
                            : null;
                        if (finalSupermarket != null) {
                          provider.addOrUpdateSupermarket(name: finalSupermarket);
                        }
                        final updated = existingItem.copyWith(
                          unitPrice: parsedPrice > 0 ? parsedPrice : existingItem.unitPrice,
                          quantity: parsedQty,
                          barcode: finalBarcode ?? existingItem.barcode,
                          category: category,
                          supermarket: finalSupermarket ?? existingItem.supermarket,
                        );
                        provider.updateItem(updated);
                        if (context.mounted) Navigator.pop(context);
                        return;
                      }

                      final proceed = await showDialog<String>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                          title: const Text('Item Já Existe na Lista'),
                          content: Text('O item "${existingItem!.name}" já está na lista de compras.\n\nDeseja atualizar o item existente em vez de criar um duplicado?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
                            TextButton(onPressed: () => Navigator.pop(ctx, 'duplicate'), child: const Text('Criar Duplicado')),
                            ElevatedButton(onPressed: () => Navigator.pop(ctx, 'update'), child: const Text('Atualizar Existente', style: TextStyle(fontWeight: FontWeight.bold))),
                          ],
                        ),
                      );
                      if (proceed == null || proceed == 'cancel') {
                        return;
                      }
                      if (proceed == 'update') {
                        final finalSupermarket = supermarketController.text.trim().isNotEmpty
                            ? supermarketController.text.trim()
                            : null;
                        if (finalSupermarket != null) {
                          provider.addOrUpdateSupermarket(name: finalSupermarket);
                        }
                        final updated = existingItem.copyWith(
                          unitPrice: parsedPrice > 0 ? parsedPrice : existingItem.unitPrice,
                          quantity: parsedQty,
                          barcode: finalBarcode ?? existingItem.barcode,
                          category: category,
                          supermarket: finalSupermarket ?? existingItem.supermarket,
                        );
                        provider.updateItem(updated);
                        if (context.mounted) Navigator.pop(context);
                        return;
                      }
                    }
                  }

                  final finalSupermarket = supermarketController.text.trim().isNotEmpty
                      ? supermarketController.text.trim()
                      : null;
                  if (finalSupermarket != null) {
                    provider.addOrUpdateSupermarket(name: finalSupermarket);
                  }

                  final newItem = Item(
                    index: activeItem?.index, 
                    name: name, 
                    unitPrice: parsedPrice,
                    quantity: parsedQty, 
                    isKg: isKg, 
                    category: category, 
                    isBought: activeItem?.isBought ?? false,
                    barcode: finalBarcode,
                    supermarket: finalSupermarket,
                  );
                  if (activeItem == null) { provider.addItem(newItem); } else { provider.updateItem(newItem); }
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Salvar', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context, int index) {
    _showAnimatedDialog(context, AlertDialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)), title: const Text('Remover Item'), content: const Text('Tem certeza que deseja remover este item permanentemente?'), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))), TextButton(onPressed: () { Provider.of<ItemProvider>(context, listen: false).removeItem(index); Navigator.pop(context); }, child: const Text('Remover', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)))]));
  }

  void _showWeightCalculator(BuildContext context, TextEditingController unitPriceCtrl, TextEditingController qtyCtrl) {
    WeightCalculatorDialog.show(context, unitPriceCtrl: unitPriceCtrl, qtyCtrl: qtyCtrl);
  }

  void _showEditBudgetDialog(BuildContext context, ItemProvider provider) {
    final controller = TextEditingController(text: Utils.formatCurrencyInput(provider.budget));
    if (controller.text.isNotEmpty) controller.selection = TextSelection.collapsed(offset: controller.text.length);
    _showAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Orçamento Disponível', style: TextStyle(fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [CurrencyInputFormatter()],
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Novo Valor',
            hintText: '0,00',
            prefixText: 'R\$ ',
            prefixStyle: TextStyle(fontSize: 16),
            floatingLabelBehavior: FloatingLabelBehavior.always,
            border: UnderlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              final newValue = Utils.parseCurrency(controller.text);
              provider.updateBudget(newValue);
              Navigator.pop(context);
            },
            child: const Text('Salvar', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _shareList(BuildContext context, ItemProvider provider) {
    if (provider.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A lista está vazia!')),
      );
      return;
    }

    _showAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Compartilhar Lista', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.chat_bubble_outline, color: Colors.green),
              ),
              title: const Text('WhatsApp / Texto', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Texto formatado com emojis, status e resumo financeiro', style: TextStyle(fontSize: 12)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onTap: () {
                Navigator.pop(context);
                _shareViaWhatsApp(context, provider);
              },
            ),
            const Divider(height: 16),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.deepPurple.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.picture_as_pdf_outlined, color: Colors.deepPurple),
              ),
              title: const Text('Documento PDF', style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: const Text('Relatório visual para impressão ou arquivamento', style: TextStyle(fontSize: 12)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              onTap: () {
                Navigator.pop(context);
                _showPdfExportDialog(context, provider);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  void _shareViaWhatsApp(BuildContext context, ItemProvider provider) {
    if (provider.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A lista está vazia!')),
      );
      return;
    }

    final buffer = StringBuffer();
    final monthName = provider.currentMonth;
    buffer.writeln('🛒 *Lista de Compras: $monthName*');
    buffer.writeln('─────────────────────────');

    final grouped = <String, List<Item>>{};
    for (var it in provider.items) {
      final cat = (it.category.isNotEmpty) ? it.category : 'Outros';
      grouped.putIfAbsent(cat, () => []).add(it);
    }

    String getCategoryEmoji(String cat) {
      final c = cat.toLowerCase();
      if (c.contains('açougue') || c.contains('carne') || c.contains('frango') || c.contains('peixe')) return '🥩';
      if (c.contains('hortifruti') || c.contains('fruta') || c.contains('legume') || c.contains('verdura')) return '🍎';
      if (c.contains('padaria') || c.contains('pão') || c.contains('bolo')) return '🥖';
      if (c.contains('laticínio') || c.contains('leite') || c.contains('queijo') || c.contains('iogurte')) return '🧀';
      if (c.contains('bebida') || c.contains('refrigerante') || c.contains('suco') || c.contains('cerveja')) return '🥤';
      if (c.contains('limpeza') || c.contains('sabão') || c.contains('detergente')) return '🧹';
      if (c.contains('higiene') || c.contains('perfumaria') || c.contains('banho') || c.contains('shampoo')) return '🧴';
      if (c.contains('congelado')) return '🧊';
      if (c.contains('mercearia') || c.contains('despensa') || c.contains('grãos') || c.contains('arroz')) return '🥫';
      if (c.contains('doce') || c.contains('sobremesa') || c.contains('snack') || c.contains('biscoito')) return '🍫';
      if (c.contains('pet') || c.contains('ração')) return '🐾';
      return '📦';
    }

    int boughtCount = 0;
    double totalSpent = 0.0;

    grouped.forEach((category, items) {
      buffer.writeln();
      buffer.writeln('${getCategoryEmoji(category)} *${category.toUpperCase()}*');
      for (var item in items) {
        final check = item.isBought ? '✅' : '⬜';
        final qtyStr = '${Utils.formatNumber(item.quantity)}${item.isKg ? "kg" : " un"}';
        String priceStr = '';
        if (item.unitPrice > 0) {
          priceStr = ' • ${Utils.formatCurrency(item.totalPrice)}';
        }
        buffer.writeln('$check ${item.name} ($qtyStr)$priceStr');
        if (item.isBought) {
          boughtCount++;
          totalSpent += item.totalPrice;
        }
      }
    });

    buffer.writeln();
    buffer.writeln('─────────────────────────');
    buffer.writeln('📊 *Resumo:*');
    buffer.writeln('• Carrinho: $boughtCount de ${provider.items.length} itens comprados');
    buffer.writeln('• Total no Carrinho: ${Utils.formatCurrency(totalSpent)}');
    if (provider.budget > 0) {
      final remaining = provider.budget - totalSpent;
      buffer.writeln('• Orçamento: ${Utils.formatCurrency(provider.budget)}');
      if (remaining >= 0) {
        buffer.writeln('• Saldo Restante: ${Utils.formatCurrency(remaining)}');
      } else {
        buffer.writeln('• Excedente: ${Utils.formatCurrency(remaining.abs())} ⚠️');
      }
    }
    buffer.writeln('\n_Gerado pelo Carrin_ 🛒');

    Share.share(buffer.toString(), subject: 'Lista de Compras: $monthName');
  }

  void _showPdfExportDialog(BuildContext context, ItemProvider provider) {
    PdfExportDialog.show(context, provider);
  }
}

class _StickyHealthHeaderDelegate extends SliverPersistentHeaderDelegate {
  final ItemProvider provider;
  final VoidCallback onEditBudget;
  final double totalItems;
  final double boughtItems;
  final double totalCost;
  final double projectedTotal;

  _StickyHealthHeaderDelegate({
    required this.provider,
    required this.onEditBudget,
    required this.totalItems,
    required this.boughtItems,
    required this.totalCost,
    required this.projectedTotal,
  });

  @override double get minExtent => 95.0;
  @override double get maxExtent => 215.0;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final double percent = (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0);
    final total = provider.items.isNotEmpty ? totalCost : provider.totalFromSheet;
    final budget = provider.budget;
    final healthPercent = budget > 0 ? total / budget : 0.0;
    
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color primary = Theme.of(context).primaryColor;
    final Color startColor = isDark ? Color.lerp(Theme.of(context).cardColor, primary, 0.15)! : Color.lerp(Colors.white, primary, 0.06)!;
    final Color currentColor = Color.lerp(startColor, Theme.of(context).scaffoldBackgroundColor, percent)!;

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: EdgeInsets.symmetric(horizontal: 16 * (1 - percent)),
      child: Center(
        child: Container(
          padding: EdgeInsets.all(20 - (10 * percent)),
          decoration: BoxDecoration(
            color: currentColor,
            borderRadius: BorderRadius.circular(24 * (1 - percent)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04 * (1 - percent)), blurRadius: 20 * (1 - percent), offset: Offset(0, 4 * (1 - percent)))]
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CountingText(value: total, style: TextStyle(fontSize: 34 - (14 * percent), fontWeight: FontWeight.bold)),
                      if (percent < 0.5) Opacity(opacity: (1 - percent * 2).clamp(0.0, 1.0), child: const Text('Total Gasto', style: TextStyle(color: Colors.grey, fontSize: 11))),
                    ],
                  ),
                  InkWell(
                    onTap: onEditBudget,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(mainAxisSize: MainAxisSize.min, children: [CountingText(value: budget, style: TextStyle(fontSize: 18 - (4 * percent), fontWeight: FontWeight.bold, color: Colors.grey)), const SizedBox(width: 4), const Icon(Icons.edit, size: 12, color: Colors.grey)]),
                        if (percent < 0.5) Opacity(opacity: (1 - percent * 2).clamp(0.0, 1.0), child: const Text('Orçamento', style: TextStyle(color: Colors.grey, fontSize: 11))),
                      ],
                    ),
                  ),
                ],
              ),
              if ((1 - percent * 1.5).clamp(0.0, 1.0) > 0.01)
                Opacity(
                  opacity: (1 - percent * 1.5).clamp(0.0, 1.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 16),
                      Builder(builder: (ctx) {
                        final primarySuccess = Theme.of(ctx).colorScheme.primary;
                        final dangerError = Theme.of(ctx).colorScheme.error;
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: healthPercent.clamp(0.0, 1.0), minHeight: 8, backgroundColor: Colors.grey[200], valueColor: AlwaysStoppedAnimation<Color>(healthPercent > 1.0 ? dangerError : (healthPercent > 0.8 ? Colors.orangeAccent : primarySuccess)))),
                            const SizedBox(height: 4),
                            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Seguro', style: TextStyle(fontSize: 9, color: primarySuccess, fontWeight: FontWeight.bold)), const Text('Atenção', style: TextStyle(fontSize: 9, color: Colors.orange, fontWeight: FontWeight.bold)), Text('Crítico', style: TextStyle(fontSize: 9, color: dangerError, fontWeight: FontWeight.bold))]),
                          ],
                        );
                      }),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          CountingText(value: boughtItems, isInteger: true, prefix: '', suffix: boughtItems == 1 ? ' item no carrinho' : ' itens no carrinho', style: TextStyle(fontSize: 11, color: Theme.of(context).primaryColor, fontWeight: FontWeight.bold)),
                          if (projectedTotal > 0 && (projectedTotal - total).abs() > 0.01)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Previsão: ',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: (budget > 0 && projectedTotal > budget) ? Colors.redAccent : Colors.grey[600],
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                CountingText(
                                  value: projectedTotal,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: (budget > 0 && projectedTotal > budget) ? Colors.redAccent : Theme.of(context).primaryColor,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override bool shouldRebuild(_StickyHealthHeaderDelegate oldDelegate) =>
      provider != oldDelegate.provider ||
      totalItems != oldDelegate.totalItems ||
      boughtItems != oldDelegate.boughtItems ||
      totalCost != oldDelegate.totalCost ||
      projectedTotal != oldDelegate.projectedTotal;
}

class _WavyFooterPainter extends CustomPainter {
  final Color color;
  _WavyFooterPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..style = PaintingStyle.fill;
    final path = Path();
    const double bH = 45.0; 
    const double pH = 20.0;  
    path.moveTo(0, bH);
    path.lineTo(size.width * 0.28, bH);
    path.cubicTo(size.width * 0.38, bH, size.width * 0.40, pH, size.width * 0.50, pH);
    path.cubicTo(size.width * 0.60, pH, size.width * 0.62, bH, size.width * 0.72, bH);
    path.lineTo(size.width, bH);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    canvas.drawShadow(path.shift(const Offset(0, -2)), Colors.black.withValues(alpha: 0.12), 8.0, true);
    canvas.drawPath(path, paint);
  }

  @override bool shouldRepaint(covariant _WavyFooterPainter oldDelegate) => color != oldDelegate.color;
}
