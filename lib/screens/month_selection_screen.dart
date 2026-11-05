import 'main_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import '../providers/item_provider.dart';
import '../widgets/cart_loading_indicator.dart';
import '../widgets/skeleton_loader.dart';
import '../widgets/counting_text.dart';
import '../services/utils.dart';
import 'shopping_list_screen.dart';
import 'receipt_scanner_screen.dart';
import '../widgets/join_shared_list_sheet.dart';

class MonthSelectionScreen extends StatefulWidget {
  const MonthSelectionScreen({super.key});

  @override
  State<MonthSelectionScreen> createState() => _MonthSelectionScreenState();
}

class _MonthSelectionScreenState extends State<MonthSelectionScreen> with AutomaticKeepAliveClientMixin {
  bool _readyToRefresh = false;
  bool _manualLoading = false;
  String? _openingMonth;
  
  bool _shouldShowContent = false;
  bool _isDescending = true;
  int _animEpoch = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadSortPreference();
    _loadData();
    MainScreen.activeTabNotifier.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (MainScreen.activeTabNotifier.value == 1 && mounted) {
      final provider = Provider.of<ItemProvider>(context, listen: false);
      final useAnimations = provider.animationSettings['list_animations'] ?? true;
      if (useAnimations) {
        setState(() {
          _animEpoch++;
        });
      }
    }
  }

  @override
  void dispose() {
    MainScreen.activeTabNotifier.removeListener(_onTabChanged);
    super.dispose();
  }

  Future<void> _loadSortPreference() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDescending = prefs.getBool('month_sort_descending') ?? true;
      });
    }
  }

  Future<void> _toggleSort() async {
    setState(() {
      _isDescending = !_isDescending;
      _animEpoch++;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('month_sort_descending', _isDescending);
  }

  Future<void> _loadData() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    
    if (provider.months.isNotEmpty && provider.cachedSummary.isNotEmpty) {
      if (mounted) setState(() { _shouldShowContent = true; });
    }

    await provider.loadMonths();
    await provider.getAllMonthsSummary();
    
    if (mounted) setState(() { _shouldShowContent = true; });
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = Provider.of<ItemProvider>(context);
    final bool showLoader = provider.isMonthsLoading || _manualLoading;
    final bool hasData = provider.months.isNotEmpty;
    final bool useAnimations = provider.animationSettings['list_animations'] ?? true;

    return LayoutBuilder(
      builder: (context, constraints) {
        final int crossAxisCount = constraints.maxWidth < 600 ? 1 : (constraints.maxWidth < 900 ? 2 : 3);
        final double padding = constraints.maxWidth < 600 ? 16 : 40;

        return Scaffold(
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          appBar: AppBar(
            title: const Text('Meus Carrinhos', style: TextStyle(fontWeight: FontWeight.bold)),
            centerTitle: true,
            backgroundColor: Colors.transparent,
            elevation: 0,
            actions: [
              IconButton(
                icon: const Icon(Icons.qr_code_scanner_rounded),
                tooltip: 'Entrar em Lista Compartilhada',
                onPressed: () => JoinSharedListSheet.show(context),
              ),
              IconButton(
                icon: Icon(_isDescending ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded),
                tooltip: _isDescending ? 'Mais recentes no topo' : 'Mais antigas no topo',
                onPressed: _toggleSort,
              ),
              IconButton(icon: const Icon(Icons.refresh), tooltip: 'Atualizar', onPressed: () => _loadData())
            ],
            bottom: showLoader ? PreferredSize(
              preferredSize: const Size.fromHeight(2),
              child: LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                minHeight: 2,
              ),
            ) : null,
          ),
          body: AnimatedSwitcher(
            duration: useAnimations ? const Duration(milliseconds: 400) : Duration.zero,
            child: !_shouldShowContent && !hasData && provider.isMonthsLoading
                ? const Center(child: CartLoadingIndicator(key: ValueKey('carrinhos_loader'), message: 'Buscando seus carrinhos...'))
                : provider.months.isEmpty
                    ? SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(padding, 40, padding, 110),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 500),
                            child: Column(
                              children: [
                                const Icon(Icons.shopping_cart_outlined, size: 64, color: Colors.grey),
                                const SizedBox(height: 16),
                                const Text(
                                  'Nenhum carrinho criado',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Crie seu primeiro carrinho para começar a organizar suas compras.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey, fontSize: 13.5),
                                ),
                                const SizedBox(height: 20),
                                ElevatedButton.icon(
                                  onPressed: () => _showCreateMonthDialog(context),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Criar Primeiro Carrinho'),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: () => JoinSharedListSheet.show(context),
                                  icon: const Icon(Icons.qr_code_scanner_rounded),
                                  label: const Text('Entrar em Lista de Outra Pessoa'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : Stack(
                        children: [
                          NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is ScrollEndNotification) {
                                if (_readyToRefresh && !showLoader) {
                                  setState(() => _manualLoading = true);
                                  provider.loadMonths().then((_) { if (mounted) setState(() => _manualLoading = false); });
                                  _readyToRefresh = false;
                                }
                              }
                              if (notification is ScrollUpdateNotification) { if (notification.metrics.pixels < -50) _readyToRefresh = true; }
                              return false;
                            },
                            child: AnimationLimiter(
                              key: ValueKey('carrinhos_limiter_' + _isDescending.toString() + '_' + _animEpoch.toString()),
                              child: GridView.builder(
                                key: ValueKey('carrinhos_grid_' + _isDescending.toString() + '_' + _animEpoch.toString()),
                                physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                                padding: EdgeInsets.fromLTRB(padding, 8, padding, 100),
                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 16,
                                  mainAxisSpacing: 16,
                                  mainAxisExtent: 140,
                                ),
                                itemCount: (_isDescending ? provider.sortedMonthsDescending : provider.sortedMonthsAscending).length,
                                itemBuilder: (context, index) {
                                  final monthsList = _isDescending ? provider.sortedMonthsDescending : provider.sortedMonthsAscending;
                                  final monthTitle = monthsList[index];
                                      final summary = provider.getCachedSummaryForMonth(monthTitle);
                                      final card = _buildMonthCard(context, monthTitle, summary, provider);
                                      if (!useAnimations) return card;
                                      return AnimationConfiguration.staggeredGrid(
                                        position: index,
                                        duration: const Duration(milliseconds: 600),
                                        delay: const Duration(milliseconds: 50),
                                        columnCount: crossAxisCount,
                                        child: SlideAnimation(verticalOffset: 30.0, child: FadeInAnimation(child: card)),
                                      );
                                    },
                                  ),
                            ),
                          ),
                        ],
                      ),
          ),
          floatingActionButton: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FloatingActionButton.extended(
                heroTag: 'fab_join_shared_list',
                onPressed: () => JoinSharedListSheet.show(context),
                label: const Text('Entrar em Lista', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                backgroundColor: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1E293B)
                    : Colors.grey[850],
                foregroundColor: const Color(0xFF10B981),
              ),
              const SizedBox(width: 10),
              FloatingActionButton.extended(
                heroTag: 'fab_new_month',
                onPressed: () => _showCreateMonthDialog(context),
                label: const Text('Novo Carrinho', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                icon: const Icon(Icons.add_shopping_cart, size: 20),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMonthCard(BuildContext context, String title, Map<String, double>? summary, ItemProvider provider) {
    final bool isDataReady = summary != null;
    final budget = summary?['budget'] ?? 0.0;
    final total = summary?['total'] ?? 0.0;
    final balance = budget - total;
    final percent = budget > 0 ? (total / budget).clamp(0.0, 1.1) : 0.0;
    final double boughtItems = summary?['boughtItems'] ?? 0.0;
    Color statusColor = balance < 0 ? Colors.redAccent : (balance < 100 ? Colors.orangeAccent : Colors.green);
    
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor, 
        borderRadius: BorderRadius.circular(24), 
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))]
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () async {
            if (_openingMonth != null) return;
            setState(() {
              _openingMonth = title;
            });
            try {
              await provider.switchMonth(title);
              if (context.mounted) {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ShoppingListScreen()),
                );
              }
            } finally {
              if (mounted) {
                setState(() {
                  _openingMonth = null;
                });
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8), 
                            decoration: BoxDecoration(
                              color: provider.isMonthFinalized(title)
                                ? Colors.green.withValues(alpha: 0.1)
                                : Colors.blueAccent.withValues(alpha: 0.1), 
                              shape: BoxShape.circle
                            ), 
                            child: _openingMonth == title
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  provider.isMonthFinalized(title) ? Icons.lock : Icons.calendar_month, 
                                  color: provider.isMonthFinalized(title) ? Colors.green : Colors.blueAccent, 
                                  size: 20
                                )
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    title, 
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold), 
                                    overflow: TextOverflow.ellipsis
                                  ),
                                ),
                                if (provider.isMonthFinalized(title)) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Colors.green.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      'CONCLUÍDO', 
                                      style: TextStyle(color: Colors.green, fontSize: 8, fontWeight: FontWeight.bold)
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    _buildMoreMenu(context, title, provider),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _buildMiniMetric('Gasto', total, Colors.blueAccent, Icons.shopping_cart_outlined, isLoading: !isDataReady),
                    _buildMiniMetric(balance < 0 ? 'Excedido' : 'Saldo', balance.abs(), statusColor, balance < 0 ? Icons.trending_up : Icons.trending_down, isLoading: !isDataReady),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end, 
                      children: [
                        Text(
                          (boughtItems.ceil() == 1) ? '1 item' : '${boughtItems.ceil()} itens', 
                          style: const TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold),
                        ), 
                        const SizedBox(height: 2),
                        if (!isDataReady)
                          const SkeletonLoader(width: 32, height: 32, borderRadius: 16)
                        else
                          Stack(
                            alignment: Alignment.center, 
                            children: [
                              SizedBox(width: 32, height: 32, child: CircularProgressIndicator(value: percent > 1.0 ? 1.0 : percent, strokeWidth: 4, backgroundColor: Colors.grey[200], valueColor: AlwaysStoppedAnimation<Color>(statusColor))), 
                              Text('${(percent * 100).toInt()}%', style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold))
                            ]
                          )
                      ]
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniMetric(String label, double value, Color color, IconData icon, {bool isLoading = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start, 
      children: [
        Row(children: [Icon(icon, size: 10, color: Colors.grey), const SizedBox(width: 4), Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10))]), 
        const SizedBox(height: 2), 
        if (isLoading) const SkeletonLoader(width: 60, height: 16, borderRadius: 4)
        else CountingText(value: value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color))
      ]
    );
  }

  Widget _buildMoreMenu(BuildContext context, String title, ItemProvider provider) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Colors.grey, size: 20),
      padding: EdgeInsets.zero,
      onSelected: (value) async { 
        if (value == 'edit') {
          _showRenameMonthDialog(context, title, provider); 
        } else if (value == 'delete') {
          _confirmDeleteMonth(context, title, provider);
        } else if (value == 'receipt') {
          await provider.switchMonth(title);
          if (context.mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const ReceiptScannerScreen()));
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'receipt', child: ListTile(leading: Icon(Icons.receipt_long_outlined), title: Text('Escanear Nota'), dense: true)),
        const PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Editar Nome'), dense: true)), 
        const PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: Colors.red), title: Text('Excluir', style: TextStyle(color: Colors.red)), dense: true))
      ],
    );
  }

  void _showRenameMonthDialog(BuildContext context, String oldTitle, ItemProvider provider) {
    final controller = TextEditingController(text: oldTitle);
    _showAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Renomear Carrinho', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Digite o novo nome:'),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Novo nome', border: UnderlineInputBorder()),
            )
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              final newTitle = controller.text.trim();
              if (newTitle.isNotEmpty && newTitle != oldTitle) {
                try {
                  await provider.renameMonth(oldTitle, newTitle);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Erro ao renomear na nuvem: $e'),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                  }
                }
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Renomear', style: TextStyle(fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  void _confirmDeleteMonth(BuildContext context, String title, ItemProvider provider) {
    _showAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: const Text('Excluir Carrinho', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Deseja excluir o carrinho "$title"? Esta ação não pode ser desfeita.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              try {
                await provider.deleteMonth(title);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro ao excluir na nuvem: $e'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Excluir', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          )
        ],
      ),
    );
  }

  void _showCreateMonthDialog(BuildContext context) {
    final titleController = TextEditingController();
    final provider = Provider.of<ItemProvider>(context, listen: false);
    final budgetController = TextEditingController(
      text: provider.defaultBudget > 0 ? Utils.formatCurrencyInput(provider.defaultBudget) : '',
    );
    String selectedPurpose = 'geral';

    final List<Map<String, dynamic>> purposeList = [
      {
        'id': 'geral',
        'title': 'Geral / Padrão',
        'subtitle': 'Compras do dia a dia',
        'icon': Icons.shopping_cart_outlined,
        'color': Colors.indigo,
      },
      {
        'id': 'churrasco',
        'title': 'Churrasco & Eventos',
        'subtitle': 'Carnes, bebidas e divisão',
        'icon': Icons.outdoor_grill_rounded,
        'color': Colors.deepOrange,
      },
      {
        'id': 'abastecimento',
        'title': 'Abastecimento',
        'subtitle': 'Compra grande de atacarejo',
        'icon': Icons.inventory_2_outlined,
        'color': Colors.teal,
      },
      {
        'id': 'conveniencia',
        'title': 'Reposição Rápida',
        'subtitle': 'Feira, padaria e caixa express',
        'icon': Icons.bolt_rounded,
        'color': Colors.amber[800] ?? Colors.amber,
      },
    ];

    _showAnimatedDialog(
      context,
      StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isDark = Theme.of(ctx).brightness == Brightness.dark;

          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            title: const Text('Novo Carrinho', style: TextStyle(fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Nome do carrinho:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: selectedPurpose == 'churrasco' ? 'Ex: Churrasco de Domingo' : 'Ex: Rancho Mensal',
                        filled: true,
                        fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.withValues(alpha: 0.1),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const Text('FINALIDADE DA COMPRA', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                    const SizedBox(height: 8),
                    ...purposeList.map((p) {
                      final isSelected = selectedPurpose == p['id'];
                      final color = p['color'] as Color;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: InkWell(
                          onTap: () {
                            setDialogState(() {
                              selectedPurpose = p['id'] as String;
                              if (titleController.text.trim().isEmpty) {
                                if (selectedPurpose == 'churrasco') {
                                  titleController.text = 'Churrasco';
                                } else if (selectedPurpose == 'abastecimento') {
                                  titleController.text = 'Compra do Mês';
                                } else if (selectedPurpose == 'conveniencia') {
                                  titleController.text = 'Reposição Feira';
                                }
                              }
                            });
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? color.withValues(alpha: 0.12) : Colors.transparent,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isSelected ? color : Colors.grey.withValues(alpha: 0.2),
                                width: isSelected ? 2 : 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 16,
                                  backgroundColor: color.withValues(alpha: 0.2),
                                  child: Icon(p['icon'] as IconData, size: 18, color: color),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        p['title'] as String,
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isSelected ? color : null),
                                      ),
                                      Text(
                                        p['subtitle'] as String,
                                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isSelected) Icon(Icons.check_circle_rounded, size: 18, color: color),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                    const Text('Orçamento (Opcional):', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: budgetController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [CurrencyInputFormatter()],
                      decoration: InputDecoration(
                        hintText: '0,00',
                        prefixText: 'R\$ ',
                        filled: true,
                        fillColor: isDark ? Colors.white.withValues(alpha: 0.05) : Colors.grey.withValues(alpha: 0.1),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
                onPressed: () async {
                  final title = titleController.text.trim();
                  if (title.isEmpty) return;
                  final double b = Utils.parseCurrency(budgetController.text);
                  double? initialBudget = b > 0 ? b : null;
                  Navigator.pop(ctx);
                  _askTemplateOption(context, title, provider, initialBudget, selectedPurpose);
                },
                child: const Text('Próximo', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _askTemplateOption(
    BuildContext context, 
    String title, 
    ItemProvider provider, 
    double? initialBudget, 
    String purpose
  ) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color primaryColor = Theme.of(context).primaryColor;
    final Color textColor = isDark ? Colors.white : primaryColor;
    final bool isChurrasco = purpose == 'churrasco';

    _showAnimatedDialog(
      context, 
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)), 
        title: const Text('Configuração Inicial', style: TextStyle(fontWeight: FontWeight.bold)), 
        content: Column(
          mainAxisSize: MainAxisSize.min, 
          children: [
            Text('Como deseja iniciar "$title"?'), 
            const SizedBox(height: 20), 
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async { 
                      Navigator.of(context).pop(); 
                      try { 
                        await provider.createNewMonth(title, false, initialBudget: initialBudget, purpose: purpose); 
                        if (isChurrasco) {
                          await provider.importTemplateItems(ItemProvider.barbecueTemplateItems);
                        } else {
                          await provider.importEssentials(); 
                        }
                        if (context.mounted) { 
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShoppingListScreen())); 
                        } 
                      } catch (e) { 
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Erro ao criar carrinho: $e'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      } 
                    }, 
                    icon: Icon(
                      isChurrasco ? Icons.outdoor_grill_rounded : Icons.auto_awesome_outlined, 
                      size: 18, 
                      color: isChurrasco ? Colors.deepOrange : textColor
                    ), 
                    label: Text(
                      isChurrasco ? 'Carregar Itens de Churrasco' : 'Importar Essenciais', 
                      style: TextStyle(
                        color: isChurrasco ? Colors.deepOrange : textColor, 
                        fontWeight: FontWeight.bold
                      )
                    ), 
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12), 
                      side: BorderSide(color: isChurrasco ? Colors.deepOrange : primaryColor, width: 1.5),
                      backgroundColor: isDark ? (isChurrasco ? Colors.deepOrange.withValues(alpha: 0.1) : primaryColor.withValues(alpha: 0.1)) : Colors.transparent,
                    )
                  )
                )
              ]
            )
          ]
        ), 
        actions: [
          TextButton(
            onPressed: () async { 
              Navigator.of(context).pop(); 
              try { 
                await provider.createNewMonth(title, false, initialBudget: initialBudget, purpose: purpose); 
                if (context.mounted) { 
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShoppingListScreen())); 
                } 
              } catch (e) { 
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro ao criar carrinho: $e'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              } 
            }, 
            child: const Text('Em Branco', style: TextStyle(color: Colors.grey))
          ), 
          ElevatedButton(
            onPressed: () async { 
              Navigator.of(context).pop(); 
              try { 
                await provider.createNewMonth(title, true, initialBudget: initialBudget, purpose: purpose); 
                if (context.mounted) { 
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShoppingListScreen())); 
                } 
              } catch (e) { 
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Erro ao criar carrinho: $e'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              } 
            }, 
            child: const Text('Copiar do Anterior', style: TextStyle(fontWeight: FontWeight.bold))
          )
        ]
      )
    );
  }
}
