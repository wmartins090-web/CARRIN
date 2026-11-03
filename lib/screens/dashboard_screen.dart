import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/item_provider.dart';
import '../theme/app_themes.dart';
import '../widgets/cart_loading_indicator.dart';
import '../widgets/counting_text.dart';
import '../widgets/sync_indicator.dart';
import '../services/utils.dart';
import 'month_selection_screen.dart';
import 'statistics_screen.dart';
import 'shopping_list_screen.dart';
import 'accounts_screen.dart';
import '../widgets/supermarket_avatar.dart';
import 'package:reorderable_grid_view/reorderable_grid_view.dart';

/// The primary landing screen of the application.
/// 
/// Displays a high-level financial summary of the current month using an animated
/// gauge and provides quick access to other parts of the app via a reorderable grid.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  bool _readyToRefresh = false;
  bool _manualLoading = false; 
  
  /// The order of cards in the reorderable grid.
  List<String> _cardOrder = ['saldo', 'orcamento', 'estatisticas', 'carrinhos'];
  
  AnimationController? _gaugeController;
  late Animation<double> _gaugeAnimation;
  
  bool _shouldShowContent = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadCardOrder();
    
    // Setup for the animated circular progress gauge
    _gaugeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    
    _gaugeAnimation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _gaugeController!, curve: Curves.fastOutSlowIn)
    );

    _loadData();
  }

  Future<void> _loadData({bool force = false}) async {
    if (mounted) setState(() { _manualLoading = force; });
    
    final provider = Provider.of<ItemProvider>(context, listen: false);
    await provider.loadDashboardData(force: force);
    
    if (mounted) {
      final data = provider.dashboardData;
      final bool hasMonth = provider.months.contains(provider.realCurrentMonthName);
      final double budget = hasMonth ? (data['budget'] ?? 0.0) : 0.0;
      final double total = hasMonth ? (data['total'] ?? 0.0) : 0.0;
      final double percent = budget > 0 ? (total / budget).clamp(0.0, 1.0) : 0.0;

      _gaugeAnimation = Tween<double>(begin: 0, end: percent).animate(
        CurvedAnimation(parent: _gaugeController!, curve: Curves.fastOutSlowIn)
      );
      
      _gaugeController!.forward(from: 0);
      
      setState(() {
        _shouldShowContent = true;
        _manualLoading = false;
      });
    }
  }

  /// Retrieves the user's custom card order from local storage.
  Future<void> _loadCardOrder() async {
    final prefs = await SharedPreferences.getInstance();
    final savedOrder = prefs.getStringList('dashboard_card_order');
    if (savedOrder != null && savedOrder.length == 4) {
      setState(() { _cardOrder = savedOrder; });
    }
  }

  /// Saves the current card order to local storage.
  Future<void> _saveCardOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('dashboard_card_order', _cardOrder);
  }

  @override
  void dispose() {
    _gaugeController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = Provider.of<ItemProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);

    final bool showLoader = provider.isLoading || _manualLoading;

    return Scaffold(
      body: SafeArea(
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollEndNotification && _readyToRefresh && !showLoader) {
              _loadData(force: true);
              _readyToRefresh = false;
            }
            if (notification is ScrollUpdateNotification && notification.metrics.pixels < -60) {
              _readyToRefresh = true;
            }
            return false;
          },
          child: Stack(
            children: [
              CustomScrollView(
                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                slivers: [
                  SliverAppBar(
                    floating: true,
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    centerTitle: false,
                    title: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('CARRIN', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
                        if (provider.detectedSupermarket != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.blue.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.location_on_rounded, size: 12, color: Colors.blue),
                                const SizedBox(width: 4),
                                Text(
                                  provider.detectedSupermarket!['name'] ?? '',
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    actions: [
                      const SyncIndicator(),
                      IconButton(
                        icon: Icon(themeProvider.isDarkMode ? Icons.wb_sunny : Icons.nightlight_round),
                        tooltip: 'Alternar Tema',
                        onPressed: () => themeProvider.toggleTheme(),
                      ),
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (context) => const AccountsScreen()),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.only(right: 16, left: 8),
                          child: Center(
                            child: SupermarketAvatarWidget(
                              photoUrl: provider.activeUserPhotoUrl,
                              displayName: provider.activeUserDisplayName,
                              radius: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  SliverToBoxAdapter(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: !_shouldShowContent && provider.dashboardData['total'] == 0 && !provider.months.isNotEmpty
                        ? SizedBox(
                            height: MediaQuery.of(context).size.height * 0.7,
                            child: const Center(child: CartLoadingIndicator(message: 'Iniciando painel...')),
                          )
                        : _buildDashboardContent(provider),
                    ),
                  ),
                ],
              ),
              if (showLoader)
                const Positioned.fill(
                  child: IgnorePointer(
                    child: CartLoadingIndicator(message: 'Sincronizando...'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardContent(ItemProvider provider) {
    final data = provider.dashboardData;
    final bool hasMonth = provider.months.contains(provider.realCurrentMonthName);
    final double budget = hasMonth ? (data['budget'] ?? 0.0) : 0.0;
    final double total = hasMonth ? (data['total'] ?? 0.0) : 0.0;
    final double percent = budget > 0 ? total / budget : 0.0;
    final bool isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = Theme.of(context).primaryColor;
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return Column(
      children: [
        // Seletor de Espaço: Meu Carrinho vs Família
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: isDarkMode ? Colors.white.withValues(alpha: 0.08) : Colors.grey[200],
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => provider.setWorkspace('personal'),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: !provider.isFamilyWorkspace
                            ? primaryColor
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.person_rounded,
                            size: 16,
                            color: !provider.isFamilyWorkspace
                                ? onPrimary
                                : (isDarkMode ? Colors.white60 : Colors.grey[700]),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Meu Carrinho',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: !provider.isFamilyWorkspace
                                  ? onPrimary
                                  : (isDarkMode ? Colors.white60 : Colors.grey[700]),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () => provider.setWorkspace('family'),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: provider.isFamilyWorkspace
                            ? primaryColor
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.family_restroom_rounded,
                            size: 16,
                            color: provider.isFamilyWorkspace
                                ? onPrimary
                                : (isDarkMode ? Colors.white60 : Colors.grey[700]),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Família',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: provider.isFamilyWorkspace
                                  ? onPrimary
                                  : (isDarkMode ? Colors.white60 : Colors.grey[700]),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Monitor de Gastos', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                if (hasMonth && provider.isMonthFinalized(provider.realCurrentMonthName)) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline, color: Theme.of(context).colorScheme.primary, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          'COMPRA CONCLUÍDA',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        _buildGauge(total, percent, provider),
        const SizedBox(height: 40),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ReorderableGridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 1.4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            dragWidgetBuilderV2: DragWidgetBuilderV2(
              builder: (int index, Widget child, ImageProvider? screenshot) {
                return Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  elevation: 8,
                  shadowColor: Colors.black.withValues(alpha: 0.25),
                  child: child,
                );
              },
            ),
            onReorder: (oldIdx, newIdx) {
              setState(() {
                final item = _cardOrder.removeAt(oldIdx);
                _cardOrder.insert(newIdx, item);
              });
              _saveCardOrder();
            },
            children: _cardOrder.map((id) => _buildReorderableCard(id, data, isDarkMode, provider)).toList(),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  Widget _buildReorderableCard(String id, Map<String, double> data, bool isDarkMode, ItemProvider provider) {
    final bool hasMonth = provider.months.contains(provider.realCurrentMonthName);
    switch (id) {
      case 'saldo':
        final double balanceVal = hasMonth ? (data['balance'] ?? 0.0) : 0.0;
        return _buildStatCard(
          key: const ValueKey('saldo'),
          title: 'Saldo Restante',
          value: balanceVal,
          icon: Icons.account_balance_wallet_outlined,
          color: balanceVal >= 0 ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
          onTap: () => _showBalanceHistoryDialog(context, provider),
        );
      case 'orcamento':
        return _buildStatCard(
          key: const ValueKey('orcamento'),
          title: 'Orçamento Total',
          value: hasMonth ? (data['budget'] ?? 0.0) : 0.0,
          icon: Icons.savings_outlined,
          color: Colors.blueAccent,
          onTap: () => _showBudgetHistoryDialog(context, provider),
        );
      case 'estatisticas':
        return _buildActionCard(
          key: const ValueKey('estatisticas'),
          title: 'Análise Anual',
          subtitle: 'Ver tendências',
          icon: Icons.auto_graph_rounded,
          onTap: () {
             Navigator.push(context, MaterialPageRoute(builder: (_) => const StatisticsScreen()));
          },
        );
      case 'carrinhos':
        return _buildActionCard(
          key: const ValueKey('carrinhos'),
          title: 'Meus Carrinhos',
          subtitle: 'Histórico mensal',
          icon: Icons.shopping_cart_checkout_rounded,
          onTap: () {
            Navigator.push(context, MaterialPageRoute(builder: (_) => const MonthSelectionScreen()));
          },
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildGauge(double total, double percent, ItemProvider provider) {
    final bool useAnimations = provider.animationSettings['gauge_animations'] ?? true;
    final statusColor = percent > 1.0 ? Colors.redAccent : (percent > 0.8 ? Colors.orangeAccent : Theme.of(context).primaryColor);

    return InkWell(
      onTap: () async {
        final targetMonth = provider.realCurrentMonthName;
        if (provider.months.contains(targetMonth)) {
          await provider.switchMonth(targetMonth);
          if (mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ShoppingListScreen()),
            );
          }
        } else if (provider.months.isNotEmpty) {
          final currentSelected = provider.currentMonth;
          if (currentSelected.isNotEmpty && provider.months.contains(currentSelected)) {
            await provider.switchMonth(currentSelected);
          } else {
            await provider.switchMonth(provider.months.last);
          }
          if (mounted) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ShoppingListScreen()),
            );
          }
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Crie um carrinho primeiro para acessar a lista.')),
            );
          }
        }
      },
      borderRadius: BorderRadius.circular(110),
      child: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 220, height: 220,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).cardColor, boxShadow: [BoxShadow(color: statusColor.withValues(alpha: 0.12), blurRadius: 25, spreadRadius: 8)]),
            ),
            SizedBox(
              width: 195, height: 195,
              child: useAnimations
                ? AnimatedBuilder(
                    animation: _gaugeAnimation,
                    builder: (context, child) => CircularProgressIndicator(value: _gaugeAnimation.value, strokeWidth: 16, backgroundColor: statusColor.withValues(alpha: 0.1), valueColor: AlwaysStoppedAnimation<Color>(statusColor), strokeCap: StrokeCap.round),
                  )
                : CircularProgressIndicator(value: percent.clamp(0.0, 1.0), strokeWidth: 16, backgroundColor: statusColor.withValues(alpha: 0.1), valueColor: AlwaysStoppedAnimation<Color>(statusColor), strokeCap: StrokeCap.round),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (provider.months.contains(provider.realCurrentMonthName)) Text(
                  provider.realCurrentMonthName,
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                ),
                const SizedBox(height: 4),
                CountingText(
                  value: provider.months.contains(provider.realCurrentMonthName) ? total : 0.0, 
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold)
                ),
                const Text('Total Gasto', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 12),
                if (useAnimations && _gaugeController != null && provider.months.contains(provider.realCurrentMonthName))
                  ScaleTransition(
                    scale: CurvedAnimation(parent: _gaugeController!, curve: const Interval(0.0, 1.0, curve: Curves.elasticOut)),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
                      child: Text('${(percent * 100).toStringAsFixed(1)}%', style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildStatCard({required Key key, required String title, required double value, required IconData icon, required Color color, VoidCallback? onTap}) {
    return Container(
      key: key,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Icon(icon, color: color.withValues(alpha: 0.6), size: 20), Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle))]),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    CountingText(value: value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color == Colors.redAccent ? Colors.redAccent : null)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showBalanceHistoryDialog(BuildContext context, ItemProvider provider) {
    _showGeneralAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Economia Mensal', style: TextStyle(fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: double.maxFinite,
          child: () {
            final monthsList = provider.months;
            return monthsList.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                    child: Text(
                      'Nenhum dado registrado. Crie um carrinho na aba "Carrinhos" para começar a acumular seu histórico de saldo.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 14, height: 1.4),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: monthsList.length,
                    itemBuilder: (context, index) {
                      final month = monthsList[index];
                      final summary = provider.getCachedSummaryForMonth(month);
                      final balance = summary?['balance'] ?? 0.0;
                      final isPositive = balance >= 0;

                      return ListTile(
                        leading: Icon(
                          isPositive ? Icons.sentiment_very_satisfied_rounded : Icons.sentiment_dissatisfied_rounded,
                          color: isPositive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
                        ),
                        title: Text(month, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(isPositive ? 'Sobrou do orçamento' : 'Ultrapassou o limite'),
                        trailing: Text(
                          Utils.formatCurrency(balance),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: isPositive ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
                          ),
                        ),
                      );
                    },
                  );
          }(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
        ],
      ),
    );
  }

  void _showBudgetHistoryDialog(BuildContext context, ItemProvider provider) {
    _showGeneralAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Histórico de Orçamentos', style: TextStyle(fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: double.maxFinite,
          child: () {
            final monthsList = provider.months;
            return monthsList.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                    child: Text(
                      'Nenhum dado registrado. Defina um orçamento ao criar um carrinho para acompanhar seu histórico.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 14, height: 1.4),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: monthsList.length,
                    itemBuilder: (context, index) {
                      final month = monthsList[index];
                      final summary = provider.getCachedSummaryForMonth(month);
                      final budget = summary?['budget'] ?? 0.0;

                      return ListTile(
                        leading: const Icon(Icons.savings_outlined, color: Colors.blueAccent),
                        title: Text(month, style: const TextStyle(fontWeight: FontWeight.bold)),
                        trailing: Text(
                          Utils.formatCurrency(budget),
                          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent),
                        ),
                      );
                    },
                  );
          }(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
        ],
      ),
    );
  }



  void _showGeneralAnimatedDialog(BuildContext context, Widget dialog) {
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

  Widget _buildActionCard({required Key key, required String title, required String subtitle, required IconData icon, required VoidCallback onTap}) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color iconColor = isDark ? const Color(0xFFAEB2FF) : Theme.of(context).primaryColor;

    return Container(
      key: key,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.05)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: iconColor.withValues(alpha: 0.9), size: 24),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                    Text(subtitle, style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
