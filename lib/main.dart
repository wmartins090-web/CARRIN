import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'providers/item_provider.dart';
import 'theme/app_themes.dart';
import 'screens/splash_screen.dart';
import 'services/notification_service.dart';
import 'services/auth_service.dart';
import 'services/app_update_service.dart';
import 'services/background_update_checker.dart';
import 'services/fcm_service.dart';

/// Entry point for the CARRIN application.
/// 
/// Initializes core services (Localizations, Notifications) and sets up
/// the global state providers.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Trava a orientação sempre em modo retrato (vertical)
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  final themeProvider = ThemeProvider();

  // Initialize pt_BR locale for currency and date formatting
  try {
    await initializeDateFormatting('pt_BR', null);
  } catch (e) {
    debugPrint("Erro ao inicializar date formatting: $e");
  }

  // Setup local notification channels
  try {
    await NotificationService().init();
  } catch (e) {
    debugPrint("Erro ao inicializar notificações: $e");
  }

  // Carrega informações da versão do aplicativo instalada
  try {
    await AppUpdateService.initPackageInfo();
  } catch (_) {}

  // Setup background update checker (WorkManager periódico)
  try {
    await BackgroundUpdateChecker.initialize();
  } catch (e) {
    debugPrint("Erro ao inicializar BackgroundUpdateChecker: $e");
  }

  // Setup Firebase Cloud Messaging (Push Notifications mesmo com app fechado)
  try {
    await FcmService.instance.initialize();
  } catch (e) {
    debugPrint("Erro ao inicializar FcmService: $e");
  }

  // Initialize Theme synchronously before rendering (sempre garantido)
  try {
    await themeProvider.init();
  } catch (e) {
    debugPrint("Erro ao inicializar tema e tamanho de fonte: $e");
  }

  // Initialize Google Auth
  try {
    await AuthService().init();
  } catch (e) {
    debugPrint("Erro ao inicializar Google Auth: $e");
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AuthService()),
        ChangeNotifierProvider(create: (_) => ItemProvider()),
        ChangeNotifierProvider.value(value: themeProvider),
      ],
      child: const MyApp(),
    ),
  );
}

/// Root widget of the application.
/// 
/// Manages the app lifecycle to handle notification cleanup and 
/// applies the user's selected theme.
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Pede permissão logo após o app carregar a interface e já engatilha o progresso
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Verifica se o aplicativo foi aberto a partir de uma notificação de atualização
      await NotificationService().handleAppLaunchNotification();

      final granted = await NotificationService().requestPermissions();
      if (granted && mounted) {
        Provider.of<ItemProvider>(context, listen: false).refreshNotification();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService().cancelProgress();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Reativa/atualiza o monitor de compras ao voltar para o app
      Provider.of<ItemProvider>(context, listen: false).refreshNotification();
    } else if (state == AppLifecycleState.detached) {
      // Cancela apenas o monitor de compras, preservando notificações de atualização
      NotificationService().cancelProgress();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'CARRIN',
      debugShowCheckedModeBanner: false,
      theme: AppThemes.getTheme(themeProvider.seedColor, false, colorBlindMode: themeProvider.colorBlindMode),
      darkTheme: AppThemes.getTheme(themeProvider.seedColor, true, colorBlindMode: themeProvider.colorBlindMode),
      themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        Widget app = MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(themeProvider.fontScale),
          ),
          child: child!,
        );

        final matrix = themeProvider.colorBlindMatrix;
        if (matrix != null) {
          return ColorFiltered(
            key: ValueKey(themeProvider.colorBlindMode),
            colorFilter: ColorFilter.matrix(matrix),
            child: app,
          );
        }
        return app;
      },
      home: const SplashScreen(), // Alterado para a SplashScreen animada
    );
  }
}
