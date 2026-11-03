import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'dart:math' as math;
import '../providers/item_provider.dart';
import '../theme/app_themes.dart';
import '../widgets/cart_loading_indicator.dart';
import '../services/utils.dart';
import 'shopping_list_screen.dart';
import 'buyer_profile_screen.dart';

class StatisticsScreen extends StatefulWidget {
  const StatisticsScreen({super.key});

  @override
  State<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends State<StatisticsScreen> with AutomaticKeepAliveClientMixin {
  int _selectedFilterIndex = 0; // Padrão: 3 meses
  bool _isAscending = true; // Padrão: Ordem crescente
  bool _shouldShowContent = false;
  bool _isInteractingWithChart = false;
  int? _activeSpotIndex;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        Provider.of<ItemProvider>(context, listen: false).setInteractingWithChart(false);
      }
    });
    super.dispose();
  }

  Future<void> _loadData() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    if (provider.cachedSummary.isNotEmpty) {
      if (mounted) setState(() { _shouldShowContent = true; });
    }
    await provider.getAllMonthsSummary();
    if (mounted) setState(() { _shouldShowContent = true; });
  }

  List<String> _getFilteredMonths(List<String> allMonths) {
    if (allMonths.isEmpty) return [];
    int count = allMonths.length;
    switch (_selectedFilterIndex) {
      case 0: count = 3; break;
      case 1: count = 6; break;
      case 2: count = 12; break;
      case 3: count = allMonths.length; break;
    }
    if (count > allMonths.length) count = allMonths.length;
    return allMonths.sublist(allMonths.length - count);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = Provider.of<ItemProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final cardColor = Theme.of(context).cardColor;
    final textColor = isDarkMode ? Colors.white : Colors.black87;
    final bool useListAnimations = provider.animationSettings['list_animations'] ?? true;
    final bool useChartAnimations = provider.animationSettings['chart_animations'] ?? true;

    final allMonths = provider.months;
    final filteredMonths = _getFilteredMonths(allMonths);
    final monthsForList = _isAscending ? filteredMonths : filteredMonths.reversed.toList();

    return Scaffold(
      backgroundColor: isDarkMode ? null : const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: Text('Estatísticas', style: TextStyle(color: textColor, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.psychology_alt_rounded),
            tooltip: 'Perfil de Comprador',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BuyerProfileScreen()),
            ),
          ),
          IconButton(icon: const Icon(Icons.bar_chart_rounded), tooltip: 'Resumo Geral', onPressed: () => _showCartsSummaryDialog(context, provider)),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () { setState(() { _shouldShowContent = false; }); _loadData(); })
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: AnimatedSwitcher(
            duration: useListAnimations ? const Duration(milliseconds: 400) : Duration.zero,
            child: (!_shouldShowContent && provider.cachedSummary.isEmpty)
              ? const Center(child: CartLoadingIndicator(key: ValueKey('stats_loader'), message: 'Analisando planilhas...'))
              : filteredMonths.isEmpty 
                ? SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 500),
                        child: Column(
                          children: [
                            _buildBuyerProfileBanner(isDarkMode, cardColor, textColor),
                            const SizedBox(height: 32),
                            const Icon(Icons.bar_chart_rounded, size: 64, color: Colors.grey),
                            const SizedBox(height: 16),
                            const Text(
                              'Sem dados para exibir',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Crie e finalize carrinhos para acompanhar o histórico de gastos e gráficos da sua família.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey, fontSize: 13.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  : SingleChildScrollView(
                    key: const ValueKey('stats_content'),
                    physics: _isInteractingWithChart 
                        ? const NeverScrollableScrollPhysics() 
                        : const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                    child: AnimationLimiter(
                      key: const ValueKey('stats_limiter_once'),
                      child: Column(
                        children: AnimationConfiguration.toStaggeredList(
                          duration: useListAnimations ? const Duration(milliseconds: 600) : Duration.zero,
                          delay: useListAnimations ? const Duration(milliseconds: 80) : Duration.zero,
                          childAnimationBuilder: (widget) => useListAnimations ? ScaleAnimation(scale: 0.8, curve: Curves.easeOutBack, child: SlideAnimation(verticalOffset: 40.0, curve: Curves.easeOutCubic, child: FadeInAnimation(child: widget))) : widget,
                          children: [
                            _buildFilterTabs(isDarkMode, cardColor, textColor, provider),
                            const SizedBox(height: 20),
                            _buildBuyerProfileBanner(isDarkMode, cardColor, textColor),
                            const SizedBox(height: 20),
                            _buildChartCard(filteredMonths, cardColor, provider.cachedSummary, useChartAnimations, themeProvider.seedColor, provider),
                            const SizedBox(height: 24),
                            _buildSummaryCards(filteredMonths, cardColor, textColor, provider.cachedSummary),
                            const SizedBox(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Histórico Detalhado', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)),
                                IconButton(icon: Icon(_isAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 18, color: isDarkMode ? Colors.white70 : Theme.of(context).primaryColor), onPressed: () => setState(() => _isAscending = !_isAscending)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _buildMonthsList(monthsForList, cardColor, textColor, provider.cachedSummary, useListAnimations),
                            const SizedBox(height: 80),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterTabs(bool isDarkMode, Color cardColor, Color textColor, ItemProvider provider) {
    return Container(
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(20), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 2))]),
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildTabItem('3 Meses', 0, provider),
          _buildTabItem('6 Meses', 1, provider),
          _buildTabItem('1 Ano', 2, provider),
          _buildTabItem('Todos', 3, provider),
        ],
      ),
    );
  }

  Widget _buildTabItem(String title, int index, ItemProvider provider) {
    bool isSelected = _selectedFilterIndex == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _selectedFilterIndex = index;
          _activeSpotIndex = null;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: isSelected ? Theme.of(context).primaryColor : Colors.transparent, borderRadius: BorderRadius.circular(16)),
          child: Text(title, textAlign: TextAlign.center, style: TextStyle(color: isSelected ? Colors.white : Colors.grey, fontWeight: isSelected ? FontWeight.bold : FontWeight.w500)),
        ),
      ),
    );
  }

  Widget _buildChartCard(List<String> months, Color cardColor, Map<String, Map<String, double>> data, bool useAnimations, Color seedColor, ItemProvider provider) {
    if (months.isEmpty) return const SizedBox.shrink();
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    List<FlSpot> spots = [];
    double minTotal = double.infinity;
    double maxTotal = 0;

    for (int i = 0; i < months.length; i++) {
      final total = data[months[i]]?['total'] ?? 0.0;
      spots.add(FlSpot(i.toDouble(), total));
      if (total < minTotal) minTotal = total;
      if (total > maxTotal) maxTotal = total;
    }
    if (minTotal == double.infinity) minTotal = 0;
    double minY = math.max(0, minTotal - (maxTotal - minTotal) * 0.2);
    double maxY = maxTotal + (maxTotal - minTotal) * 0.2;
    if (minY == maxY) { minY = 0; maxY += 100; }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!_isInteractingWithChart) {
          setState(() => _isInteractingWithChart = true);
          provider.setInteractingWithChart(true);
        }
      },
      onPointerUp: (_) {
        if (_isInteractingWithChart) {
          setState(() => _isInteractingWithChart = false);
          provider.setInteractingWithChart(false);
        }
      },
      onPointerCancel: (_) {
        if (_isInteractingWithChart) {
          setState(() => _isInteractingWithChart = false);
          provider.setInteractingWithChart(false);
        }
      },
      child: Container(
        height: 380,
        padding: const EdgeInsets.only(top: 18, bottom: 10, left: 16, right: 24),
        decoration: BoxDecoration(
          color: cardColor, 
          borderRadius: BorderRadius.circular(20), 
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05), 
              blurRadius: 10, 
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Row(
                children: [
                  Icon(Icons.touch_app_rounded, size: 16, color: Theme.of(context).primaryColor),
                  const SizedBox(width: 8),
                  Text(
                    'Arraste o dedo pelo gráfico para ver os valores de cada mês',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TweenAnimationBuilder<double>(
                key: ValueKey('chart_anim_${months.length}_$_selectedFilterIndex'),
                tween: Tween<double>(begin: 0.0, end: 1.0),
                duration: useAnimations ? const Duration(milliseconds: 1500) : Duration.zero,
                curve: Curves.easeOutQuart,
                builder: (context, animValue, child) {
                  final Color barColor = Theme.of(context).primaryColor;
                  return LineChart(
                    LineChartData(
                      lineTouchData: LineTouchData(
                        enabled: true,
                        handleBuiltInTouches: true,
                        touchSpotThreshold: 50,
                        touchCallback: (FlTouchEvent event, LineTouchResponse? touchResponse) {
                          if (event is FlPanUpdateEvent || event is FlPanStartEvent || event is FlTapDownEvent) {
                            if (!_isInteractingWithChart) {
                              setState(() => _isInteractingWithChart = true);
                              provider.setInteractingWithChart(true);
                            }
                            if (touchResponse != null && touchResponse.lineBarSpots != null && touchResponse.lineBarSpots!.isNotEmpty) {
                              final spot = touchResponse.lineBarSpots!.first;
                              final idx = spot.x.toInt();
                              if (idx >= 0 && idx < months.length && idx != _activeSpotIndex) {
                                _activeSpotIndex = idx;
                                HapticFeedback.mediumImpact();
                              }
                            }
                          } else if (event is FlPanEndEvent || event is FlTapUpEvent || event is FlPointerExitEvent) {
                            if (_isInteractingWithChart) {
                              setState(() => _isInteractingWithChart = false);
                              provider.setInteractingWithChart(false);
                            }
                          }
                        },
                        getTouchedSpotIndicator: (LineChartBarData barData, List<int> indicators) {
                          return indicators.map((int index) {
                            final line = FlLine(
                              color: Theme.of(context).primaryColor.withValues(alpha: 0.7),
                              strokeWidth: 2,
                              dashArray: [4, 4],
                            );
                            return TouchedSpotIndicatorData(
                              line,
                              FlDotData(
                                show: true,
                                getDotPainter: (spot, percent, bar, idx) {
                                  return FlDotCirclePainter(
                                    radius: 7,
                                    color: Theme.of(context).primaryColor,
                                    strokeWidth: 3,
                                    strokeColor: isDarkMode ? const Color(0xFF0D0E15) : Colors.white,
                                  );
                                },
                              ),
                            );
                          }).toList();
                        },
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipColor: (spot) => (isDarkMode ? const Color(0xFF1E2235) : AppColors.navy).withValues(alpha: 0.95),
                          fitInsideHorizontally: true,
                          fitInsideVertically: true,
                          tooltipPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              final idx = spot.x.toInt();
                              final monthName = (idx >= 0 && idx < months.length) ? months[idx] : '';
                              final monthSummary = (idx >= 0 && idx < months.length) ? data[monthName] : null;
                              final budgetVal = monthSummary?['budget'] ?? 0.0;
                              final balVal = monthSummary?['balance'] ?? (budgetVal > 0 ? budgetVal - spot.y : 0.0);
                              return LineTooltipItem(
                                '$monthName\n',
                                const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.normal),
                                children: [
                                  TextSpan(
                                    text: 'Gasto: ${Utils.formatCurrency(spot.y)}\n',
                                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
                                  if (budgetVal > 0)
                                    TextSpan(
                                      text: 'Saldo: ${Utils.formatCurrency(balVal)}',
                                      style: TextStyle(
                                        color: balVal < 0 ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                ],
                              );
                            }).toList();
                          },
                        ),
                      ),
                      gridData: FlGridData(
                        show: true, 
                        drawVerticalLine: false, 
                        horizontalInterval: (maxY - minY) / 4 == 0 ? 1 : (maxY - minY) / 4, 
                        getDrawingHorizontalLine: (v) => FlLine(color: Colors.grey.withValues(alpha: 0.1), strokeWidth: 1, dashArray: [5, 5]),
                      ),
                      titlesData: FlTitlesData(
                        show: true, 
                        rightTitles: const AxisTitles(), 
                        topTitles: const AxisTitles(),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true, 
                            reservedSize: 30, 
                            interval: 1, 
                            getTitlesWidget: (v, m) {
                              int idx = v.toInt();
                              if (idx < 0 || idx >= months.length) return const SizedBox.shrink();
                              String name = months[idx].split(' ').first;
                              return Padding(
                                padding: const EdgeInsets.only(top: 10), 
                                child: Text(name.length > 3 ? name.substring(0, 3) : name, style: TextStyle(color: Colors.grey[400], fontSize: 11)),
                              );
                            },
                          ),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true, 
                            interval: (maxY - minY) / 4 == 0 ? 1 : (maxY - minY) / 4, 
                            reservedSize: 50, 
                            getTitlesWidget: (v, m) => Text(v > 1000 ? '${(v/1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0), style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5), fontSize: 11)),
                          ),
                        ),
                      ),
                      borderData: FlBorderData(show: false), 
                      minX: 0, 
                      maxX: (months.length - 1).toDouble(), 
                      minY: minY, 
                      maxY: maxY,
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots.map((s) {
                            if (!useAnimations) return s;
                            final double delay = (s.x / (spots.length > 1 ? spots.length - 1 : 1)) * 0.4;
                            return FlSpot(s.x, minY + (s.y - minY) * Curves.easeInOutCubic.transform(((animValue - delay) / (1.0 - delay)).clamp(0.0, 1.0)));
                          }).toList(),
                          isCurved: true, 
                          color: barColor, 
                          barWidth: 4, 
                          isStrokeCapRound: true,
                          dotData: FlDotData(
                            show: true, 
                            getDotPainter: (s, p, b, i) => FlDotCirclePainter(radius: 4, color: barColor, strokeWidth: 2, strokeColor: isDarkMode ? const Color(0xFF0D0E15) : Colors.white),
                          ),
                          belowBarData: BarAreaData(
                            show: true, 
                            gradient: LinearGradient(
                              colors: [barColor.withValues(alpha: 0.3 * animValue), barColor.withValues(alpha: 0.0)], 
                              begin: Alignment.topCenter, 
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                      ],
                    ),
                    duration: Duration.zero,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCards(List<String> months, Color cardColor, Color textColor, Map<String, Map<String, double>> data) {
    if (months.isEmpty) return const SizedBox.shrink();
    double totalSum = 0; double maxT = 0; double minT = double.infinity;
    for (String m in months) { double t = data[m]?['total'] ?? 0; totalSum += t; if (t > maxT) maxT = t; if (t < minT) minT = t; }
    if (minT == double.infinity) minT = 0;
    double avg = totalSum / months.length;
    double change = 0.0; bool isDown = false;
    if (months.length >= 2) { double last = data[months.last]?['total'] ?? 0; double prev = data[months[months.length - 2]]?['total'] ?? 0; if (prev > 0) { change = ((last - prev) / prev) * 100; isDown = change <= 0; } }

    return Container(
      decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4))]),
      padding: const EdgeInsets.all(28), 
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_selectedFilterIndex == 3 ? 'Geral' : 'Filtro Ativo', style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)), Text(months.length > 1 ? '${months.first} a ${months.last}' : months.first, style: const TextStyle(color: Colors.grey, fontSize: 12))]),
        const SizedBox(height: 32),
        Row(children: [
          Expanded(child: _buildInfoMetric('Média de Gasto', Utils.formatCurrency(avg), textColor)),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('% Mudança', style: TextStyle(color: Colors.grey, fontSize: 12)), const SizedBox(height: 10), Row(children: [Icon(isDown ? Icons.arrow_downward : Icons.arrow_upward, color: isDown ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error, size: 20), const SizedBox(width: 6), Text('${change.abs().toStringAsFixed(1)}%', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: isDown ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error))])]))
        ]),
        const SizedBox(height: 32),
        Row(children: [Expanded(child: _buildInfoMetric('Máximo', Utils.formatCurrency(maxT), textColor)), Expanded(child: _buildInfoMetric('Mínimo', Utils.formatCurrency(minT), textColor))])
      ]),
    );
  }

  Widget _buildInfoMetric(String title, String value, Color textColor) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(color: Colors.grey, fontSize: 12)), const SizedBox(height: 10), Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textColor))]);
  }

  Widget _buildMonthsList(List<String> months, Color cardColor, Color textColor, Map<String, Map<String, double>> data, bool useAnimations) {
    return AnimationLimiter(child: Column(children: AnimationConfiguration.toStaggeredList(
      duration: useAnimations ? const Duration(milliseconds: 600) : Duration.zero, delay: useAnimations ? const Duration(milliseconds: 50) : Duration.zero,
      childAnimationBuilder: (w) => useAnimations ? SlideAnimation(verticalOffset: 20.0, child: FadeInAnimation(child: w)) : w,
      children: months.map((m) {
        final b = data[m]?['budget'] ?? 0.0; final t = data[m]?['total'] ?? 0.0; final bal = b - t;
        Color statusC = bal < 1.0 ? Theme.of(context).colorScheme.error : (bal <= 100.0 ? Colors.orangeAccent : Theme.of(context).colorScheme.primary);
        return Container(margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: cardColor, borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4))]), child: Material(color: Colors.transparent, child: InkWell(onTap: () => _showMonthDetail(m, b, t), borderRadius: BorderRadius.circular(24), child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(m, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)), const Icon(Icons.chevron_right, color: Colors.grey, size: 22)]), const SizedBox(height: 20), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [_buildListMetric('Orçamento', Utils.formatCurrency(b), null), _buildListMetric('Gasto', Utils.formatCurrency(t), Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Theme.of(context).primaryColor), _buildListMetric('Saldo', Utils.formatCurrency(bal), statusC)])])))));
      }).toList(),
    )));
  }

  Widget _buildListMetric(String label, String value, Color? color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)), const SizedBox(height: 6), Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color))]);
  }

  void _showCartsSummaryDialog(BuildContext context, ItemProvider provider) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    _showGeneralAnimatedDialog(
      context,
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        title: Text(
          'Resumo Geral',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isDarkMode ? Colors.white : Theme.of(context).primaryColor,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Builder(
            builder: (context) {
              final monthsList = provider.months;
              return ListView.builder(
                shrinkWrap: true,
                itemCount: monthsList.length,
                itemBuilder: (context, index) {
                  final m = monthsList[index];
              final s = provider.getCachedSummaryForMonth(m);
              final b = s?['budget'] ?? 0.0;
              final t = s?['total'] ?? 0.0;
              final bal = b - t;
              final isEx = t > b && b > 0;

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isEx ? Icons.warning_rounded : Icons.check_circle_rounded,
                          color: isEx ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          m,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: isDarkMode ? Colors.white : Theme.of(context).primaryColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.shopping_cart_outlined,
                              size: 14,
                              color: Theme.of(context).primaryColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Gasto: ${Utils.formatCurrency(t)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Icon(
                              isEx ? Icons.trending_up : Icons.trending_down,
                              size: 14,
                              color: isEx ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isEx ? 'Excedido: ${Utils.formatCurrency(bal.abs())}' : 'Saldo: ${Utils.formatCurrency(bal)}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: isEx ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Divider(),
                  ],
                ),
              );
            },
          );
        },
      ),
    ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Fechar',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showGeneralAnimatedDialog(BuildContext context, Widget dialog) {
    showGeneralDialog(context: context, barrierDismissible: true, barrierLabel: '', transitionDuration: const Duration(milliseconds: 300), pageBuilder: (context, anim1, anim2) => dialog, transitionBuilder: (context, anim1, anim2, child) {
      final curve = Curves.easeOutBack.transform(anim1.value);
      return Transform.scale(scale: curve, child: Opacity(opacity: anim1.value, child: child));
    });
  }

  void _showMonthDetail(String month, double budget, double total) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    final balance = budget - total;
    final percent = budget > 0 ? (total / budget) : (total > 0 ? 1.1 : 0.0);
    Color statusC = balance < 1.0 ? Theme.of(context).colorScheme.error : (balance <= 100.0 ? Colors.orangeAccent : Theme.of(context).colorScheme.primary);
    
    final Color buttonBg = Theme.of(context).primaryColor;
    final Color buttonFg = buttonBg.computeLuminance() > 0.5 ? Colors.black : Colors.white;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(
              'Detalhamento: $month',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 130,
                      height: 130,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).cardColor,
                        boxShadow: [
                          BoxShadow(
                            color: statusC.withValues(alpha: 0.15),
                            blurRadius: 20,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 115,
                      height: 115,
                      child: CircularProgressIndicator(
                        value: math.min(1.0, percent),
                        strokeWidth: 10,
                        backgroundColor: statusC.withValues(alpha: 0.1),
                        valueColor: AlwaysStoppedAnimation<Color>(statusC),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    Column(
                      children: [
                        Text(
                          '${(percent * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: statusC,
                          ),
                        ),
                        const Text(
                          'do total',
                          style: TextStyle(fontSize: 10, color: Colors.grey),
                        ),
                      ],
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHybridDetailItem('Previsto', budget, Colors.grey, Icons.flag_outlined),
                    const SizedBox(height: 16),
                    _buildHybridDetailItem(
                      'Gasto Real',
                      total,
                      isDarkMode ? Colors.white70 : Theme.of(context).primaryColor,
                      Icons.shopping_cart_outlined,
                    ),
                    const SizedBox(height: 16),
                    _buildHybridDetailItem(
                      balance < 0 ? 'Excedido' : 'Economia',
                      balance.abs(),
                      statusC,
                      balance < 0 ? Icons.trending_up : Icons.trending_down,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: statusC.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: statusC.withValues(alpha: 0.3)),
              ),
              child: Text(
                balance < 1.0
                    ? 'Orçamento Excedido'
                    : (balance <= 100.0 ? 'Próximo ao Limite' : 'Dentro do Orçamento'),
                style: TextStyle(
                  color: statusC,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.list_alt, size: 20),
                label: const Text(
                  'Ver Itens desta Lista',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: buttonBg,
                  foregroundColor: buttonFg,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () async {
                  Navigator.pop(context);
                  final provider = Provider.of<ItemProvider>(context, listen: false);
                  await provider.switchMonth(month);
                  if (context.mounted) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ShoppingListScreen()),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHybridDetailItem(String label, double value, Color color, IconData icon) {
    return Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle), child: Icon(icon, color: color, size: 16)), const SizedBox(width: 12), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.w500)), Text(Utils.formatCurrency(value), style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: color == Colors.grey ? null : color))])]);
  }

  Widget _buildBuyerProfileBanner(bool isDarkMode, Color cardColor, Color textColor) {
    final primaryColor = Theme.of(context).primaryColor;
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(20),
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.06),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const BuyerProfileScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: primaryColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.psychology_alt_rounded, color: primaryColor, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Perfil de Comprador',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Descubra seus hábitos de compra, arquétipo e economia.',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDarkMode ? Colors.white60 : Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios_rounded, size: 15, color: primaryColor),
            ],
          ),
        ),
      ),
    );
  }
}
