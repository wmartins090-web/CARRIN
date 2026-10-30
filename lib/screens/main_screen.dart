import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dashboard_screen.dart';
import 'month_selection_screen.dart';
import 'statistics_screen.dart';
import 'settings_screen.dart';
import '../providers/item_provider.dart';
import '../widgets/interactive_tab_tutorial.dart';
import '../services/app_update_service.dart';
import '../widgets/app_update_dialog.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => MainScreenState();
}

class MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;
  late PageController _pageController;
  Timer? _tutorialSettleTimer;
  int? _programmaticTargetIndex;

  TutorialSection _sectionForTab(int index) {
    switch (index) {
      case 0:
        return TutorialSection.dashboard;
      case 1:
        return TutorialSection.carts;
      case 2:
        return TutorialSection.statistics;
      case 3:
      default:
        return TutorialSection.settings;
    }
  }

  void _scheduleTabTutorial(int index, {Duration delay = const Duration(milliseconds: 240)}) {
    // Mantém o tutorial automático apenas no Início (0) e nas Configurações (3)
    if (index != 0 && index != 3) return;
    _tutorialSettleTimer?.cancel();
    _tutorialSettleTimer = Timer(delay, () {
      if (!mounted || _currentIndex != index) return;
      if (_programmaticTargetIndex != null && _programmaticTargetIndex != index) return;
      final itemProvider = Provider.of<ItemProvider>(context, listen: false);
      InteractiveTabTutorial.checkAndShowIfFirstTime(
        context,
        _sectionForTab(index),
        userEmail: itemProvider.activeUserEmail,
      );
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(initialPage: _currentIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final itemProvider = Provider.of<ItemProvider>(context, listen: false);
      // Detecção silenciosa e invisível em segundo plano logo na inicialização
      itemProvider.detectNearbySupermarket(
        notify: false,
      );
      _scheduleTabTutorial(_currentIndex, delay: const Duration(milliseconds: 220));

      // Checagem automática e download silencioso em segundo plano de nova versão
      Future.delayed(const Duration(milliseconds: 2000), () {
        if (!mounted) return;
        AppUpdateService.instance.checkForUpdate().then((info) {
          if (info != null && mounted) {
            // O app baixa silenciosamente em background e só avisa quando estiver 100% baixado e pronto
            AppUpdateService.instance.downloadInBackground(
              info,
              onReady: (readyInfo, apkPath) {
                if (mounted) {
                  AppUpdateDialog.showReady(context, readyInfo, apkPath);
                }
              },
            );
          }
        });
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reavalia o GPS silenciosamente sempre que o usuário reabrir o app
      Provider.of<ItemProvider>(context, listen: false).detectNearbySupermarket(
        notify: false,
      );
    }
  }

  @override
  void dispose() {
    _tutorialSettleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    super.dispose();
  }

  void switchTab(int index) {
    if (mounted) {
      _onItemTapped(index);
    }
  }

  void _onPageChanged(int index) {
    final itemProvider = Provider.of<ItemProvider>(context, listen: false);
    itemProvider.setInteractingWithChart(false);
    setState(() {
      _currentIndex = index;
    });
    if (_programmaticTargetIndex != null && _programmaticTargetIndex != index) {
      return;
    }
    _scheduleTabTutorial(index, delay: const Duration(milliseconds: 240));
  }

  Future<void> _onItemTapped(int index) async {
    if (index == _currentIndex) return;
    _tutorialSettleTimer?.cancel();
    _programmaticTargetIndex = index;
    await _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    _programmaticTargetIndex = null;
    _scheduleTabTutorial(index, delay: const Duration(milliseconds: 80));
  }

  @override
  Widget build(BuildContext context) {
    final itemProvider = Provider.of<ItemProvider>(context);
    final isChartInteracting = itemProvider.isInteractingWithChart;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = Theme.of(context).cardColor;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        systemNavigationBarColor: cardColor,
        systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: PopScope(
        canPop: _currentIndex == 0,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) {
            return;
          }
          _onItemTapped(0);
        },
        child: Scaffold(
          body: PageView(
            controller: _pageController,
            onPageChanged: _onPageChanged,
            physics: isChartInteracting
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            children: const [
              DashboardScreen(),
              MonthSelectionScreen(),
              StatisticsScreen(),
              SettingsScreen(),
            ],
          ),
          bottomNavigationBar: Container(
            decoration: BoxDecoration(
              color: cardColor,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              left: false,
              right: false,
              bottom: true,
              child: BottomNavigationBar(
                currentIndex: _currentIndex,
                elevation: 0,
                onTap: _onItemTapped,
                type: BottomNavigationBarType.fixed,
                backgroundColor: cardColor,
                selectedItemColor: Theme.of(context).primaryColor,
                unselectedItemColor: isDark ? Colors.grey : Colors.grey.shade600,
                showSelectedLabels: true,
                showUnselectedLabels: true,
                selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 11),
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home_outlined),
                    activeIcon: Icon(Icons.home),
                    label: 'Início',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.shopping_cart_outlined),
                    activeIcon: Icon(Icons.shopping_cart),
                    label: 'Carrinhos',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.bar_chart_outlined),
                    activeIcon: Icon(Icons.bar_chart),
                    label: 'Análises',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings_outlined),
                    activeIcon: Icon(Icons.settings),
                    label: 'Ajustes',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
