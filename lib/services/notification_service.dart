import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../services/utils.dart';
import '../services/app_update_service.dart';
import '../widgets/app_update_dialog.dart';

/// Service responsible for managing local notifications.
/// 
/// Handles initialization of notification channels, requesting permissions,
/// showing real-time shopping progress with progress bar, budget limit alerts,
/// and background app update notifications.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  /// Channel ID for shopping progress notifications.
  static const String channelId = 'shopping_list_progress_v5';
  static const String channelName = 'Monitor de Compras';
  static const String channelDescription = 'Mostra o total gasto e progresso com barra de status';

  /// Channel ID for high-importance budget alerts.
  static const String budgetChannelId = 'budget_alerts_v2';
  static const String budgetChannelName = 'Alertas de Orçamento';

  /// Channel ID for app updates notifications.
  static const String updateChannelId = 'app_updates_v1';
  static const String updateChannelName = 'Atualizações do CARRIN';
  static const String updateChannelDescription = 'Notificações de novas versões e atualizações prontas para instalar';

  /// Notification IDs
  static const int progressNotificationId = 0;
  static const int budgetNotificationId = 1;
  static const int updateAvailableNotificationId = 2;
  static const int updateReadyNotificationId = 3;

  /// Ícones oficiais para notificações nativas (res/drawable)
  static const String cartNotificationIcon = 'ic_notification_cart';
  static const String appLogoIcon = 'ic_carrin_logo';

  /// Initializes notification plugins and creates necessary Android channels.
  Future<void> init() async {
    try {
      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings(cartNotificationIcon); 

      const InitializationSettings initializationSettings = InitializationSettings(
        android: initializationSettingsAndroid,
      );

      try {
        await _notificationsPlugin.initialize(
          initializationSettings,
          onDidReceiveNotificationResponse: _onNotificationTapped,
        );
      } catch (initErr) {
        debugPrint('Fallback de inicialização com @mipmap/launcher_icon: $initErr');
        const AndroidInitializationSettings fallbackInit =
            AndroidInitializationSettings('@mipmap/launcher_icon');
        await _notificationsPlugin.initialize(
          const InitializationSettings(android: fallbackInit),
          onDidReceiveNotificationResponse: _onNotificationTapped,
        );
      }

      // Progress Channel (Prioridade padrão: exibe na barra de status e tela de bloqueio sem som repetitivo)
      const AndroidNotificationChannel progressChannel = AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.defaultImportance,
        enableVibration: false,
        playSound: false,
        showBadge: true,
      );

      // Alert Channel (High Importance para estouro de orçamento)
      const AndroidNotificationChannel budgetChannel = AndroidNotificationChannel(
        budgetChannelId,
        budgetChannelName,
        description: 'Notifica quando o orçamento limite for ultrapassado',
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
      );

      // App Updates Channel (High Importance para novidades e download pronto)
      const AndroidNotificationChannel updateChannel = AndroidNotificationChannel(
        updateChannelId,
        updateChannelName,
        description: updateChannelDescription,
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
        showBadge: true,
      );

      final androidImpl = _notificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.createNotificationChannel(progressChannel);
      await androidImpl?.createNotificationChannel(budgetChannel);
      await androidImpl?.createNotificationChannel(updateChannel);
    } catch (e) {
      debugPrint('Aviso ao inicializar NotificationService: $e');
    }
  }

  /// Trata toques em notificações (especialmente para instalação de APK baixado)
  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.startsWith('install_apk:')) {
      final filePath = payload.substring('install_apk:'.length);
      if (filePath.isNotEmpty) {
        AppUpdateService.instance.installApk(filePath);
      }
    } else if (payload == 'check_update') {
      AppUpdateDialog.openFromNotification(autoStartDownload: true);
    }
  }

  /// Verifica se o aplicativo foi aberto através de um clique em notificação
  Future<void> handleAppLaunchNotification() async {
    try {
      final details = await _notificationsPlugin.getNotificationAppLaunchDetails();
      if (details != null && details.didNotificationLaunchApp) {
        final payload = details.notificationResponse?.payload;
        if (payload != null && payload.startsWith('install_apk:')) {
          final filePath = payload.substring('install_apk:'.length);
          if (filePath.isNotEmpty) {
            Future.delayed(const Duration(milliseconds: 600), () {
              AppUpdateService.instance.installApk(filePath);
            });
          }
        } else if (payload == 'check_update') {
          Future.delayed(const Duration(milliseconds: 800), () {
            AppUpdateDialog.openFromNotification(autoStartDownload: true);
          });
        }
      }
    } catch (e) {
      debugPrint('Erro ao verificar notificação de inicialização: $e');
    }
  }

  /// Triggers a high-priority budget alert notification.
  Future<void> showBudgetAlert(String title, String body) async {
    try {
      try {
        const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
          budgetChannelId,
          budgetChannelName,
          channelDescription: 'Notifica quando o orçamento limite for ultrapassado',
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xFFFF5252),
          ledColor: Color(0xFFFF5252),
          ledOnMs: 1000,
          ledOffMs: 500,
          playSound: true,
          enableVibration: true,
          autoCancel: true,
          icon: cartNotificationIcon,
          largeIcon: DrawableResourceAndroidBitmap(appLogoIcon),
        );

        const NotificationDetails details = NotificationDetails(android: androidDetails);
        await _notificationsPlugin.show(budgetNotificationId, title, body, details);
      } catch (inner) {
        debugPrint('Fallback alert com @mipmap/launcher_icon: $inner');
        const AndroidNotificationDetails fallbackDetails = AndroidNotificationDetails(
          budgetChannelId,
          budgetChannelName,
          channelDescription: 'Notifica quando o orçamento limite for ultrapassado',
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xFFFF5252),
          ledColor: Color(0xFFFF5252),
          ledOnMs: 1000,
          ledOffMs: 500,
          playSound: true,
          enableVibration: true,
          autoCancel: true,
          icon: '@mipmap/launcher_icon',
          largeIcon: DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
        );
        await _notificationsPlugin.show(budgetNotificationId, title, body, const NotificationDetails(android: fallbackDetails));
      }
    } catch (e) {
      debugPrint('Erro ao disparar showBudgetAlert: $e');
    }
  }

  /// Dispara notificação de nova versão disponível encontrada em segundo plano
  Future<void> showUpdateAvailable({
    required String version,
    required int buildNumber,
    String? title,
  }) async {
    try {
      final header = title ?? 'Nova Versão do CARRIN Disponível (v$version)';
      const body = 'Uma nova versão com melhorias está pronta. Toque para abrir e atualizar.';
      
      const androidDetails = AndroidNotificationDetails(
        updateChannelId,
        updateChannelName,
        channelDescription: updateChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        color: Color(0xFF10B981),
        ledColor: Color(0xFF10B981),
        playSound: true,
        enableVibration: true,
        autoCancel: true,
        icon: cartNotificationIcon,
        largeIcon: DrawableResourceAndroidBitmap(appLogoIcon),
      );

      await _notificationsPlugin.show(
        updateAvailableNotificationId,
        header,
        body,
        const NotificationDetails(android: androidDetails),
        payload: 'check_update',
      );
    } catch (e) {
      debugPrint('Fallback showUpdateAvailable: $e');
      try {
        const fallbackDetails = AndroidNotificationDetails(
          updateChannelId,
          updateChannelName,
          channelDescription: updateChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xFF10B981),
          autoCancel: true,
          icon: '@mipmap/launcher_icon',
          largeIcon: DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
        );
        await _notificationsPlugin.show(
          updateAvailableNotificationId,
          'Nova Versão do CARRIN Disponível (v$version)',
          'Toque para abrir e atualizar.',
          const NotificationDetails(android: fallbackDetails),
          payload: 'check_update',
        );
      } catch (_) {}
    }
  }

  /// Dispara notificação de atualização baixada e pronta para instalar (Opção 3)
  Future<void> showUpdateReady({
    required String version,
    required String apkPath,
  }) async {
    try {
      final title = '📦 Atualização Pronta (v$version)';
      const body = 'O instalador foi baixado com sucesso. Toque aqui para instalar agora.';

      const androidDetails = AndroidNotificationDetails(
        updateChannelId,
        updateChannelName,
        channelDescription: updateChannelDescription,
        importance: Importance.high,
        priority: Priority.high,
        color: Color(0xFF10B981),
        ledColor: Color(0xFF10B981),
        playSound: true,
        enableVibration: true,
        autoCancel: true,
        icon: cartNotificationIcon,
        largeIcon: DrawableResourceAndroidBitmap(appLogoIcon),
      );

      await _notificationsPlugin.show(
        updateReadyNotificationId,
        title,
        body,
        const NotificationDetails(android: androidDetails),
        payload: 'install_apk:$apkPath',
      );
    } catch (e) {
      debugPrint('Fallback showUpdateReady: $e');
      try {
        const fallbackDetails = AndroidNotificationDetails(
          updateChannelId,
          updateChannelName,
          channelDescription: updateChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xFF10B981),
          autoCancel: true,
          icon: '@mipmap/launcher_icon',
          largeIcon: DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
        );
        await _notificationsPlugin.show(
          updateReadyNotificationId,
          '📦 Atualização Pronta (v$version)',
          'Toque para instalar agora.',
          const NotificationDetails(android: fallbackDetails),
          payload: 'install_apk:$apkPath',
        );
      } catch (_) {}
    }
  }

  /// Cancela notificações de atualização
  Future<void> cancelUpdateNotifications() async {
    try {
      await _notificationsPlugin.cancel(updateAvailableNotificationId);
      await _notificationsPlugin.cancel(updateReadyNotificationId);
    } catch (_) {}
  }

  /// Requests notification permissions for Android 13+.
  Future<bool> requestPermissions() async {
    try {
      final androidPlugin = _notificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      
      if (androidPlugin != null) {
        final granted = await androidPlugin.requestNotificationsPermission();
        return granted ?? false;
      }
    } catch (e) {
      debugPrint('Erro ao solicitar permissões de notificação: $e');
    }
    return true;
  }

  /// Checks if notifications are enabled on the system level.
  Future<bool> areNotificationsEnabled() async {
    try {
      final androidPlugin = _notificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        return (await androidPlugin.areNotificationsEnabled()) ?? true;
      }
    } catch (_) {}
    return true;
  }

  /// Shows or updates a notification with current shopping progress.
  Future<void> showOrUpdateProgress(
    String listName, 
    int bought, 
    int total, 
    double totalPrice, {
    double budget = 0.0,
  }) async {
    if (total == 0) {
      await cancelProgress();
      return;
    }

    try {
      final String priceFormatted = Utils.formatCurrency(totalPrice);
      final String title = '$listName • $priceFormatted';
      final int percent = total > 0 ? ((bought / total) * 100).toInt() : 0;
      final String content = '$bought de $total itens comprados ($percent%)';

      String? subText;
      String bigText = 'Total no carrinho: $priceFormatted\nItens: $bought de $total comprados ($percent%)';
      if (budget > 0) {
        final double balance = budget - totalPrice;
        if (balance >= 0) {
          subText = 'Resta: ${Utils.formatCurrency(balance)}';
        } else {
          subText = 'Estourou: ${Utils.formatCurrency(-balance)}';
        }
        bigText += '\nOrçamento: ${Utils.formatCurrency(budget)} | Saldo: ${Utils.formatCurrency(balance)}';
      }

      try {
        final AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ticker: 'Carrin atualizado',
          ongoing: false, // Deslizável/dispensável
          autoCancel: false, // Não é apagada acidentalmente ao tocar para abrir o app
          onlyAlertOnce: true, 
          showProgress: true,
          maxProgress: total,
          progress: bought,
          subText: subText,
          color: const Color(0xFF10B981), // Destaque na cor verde esmeralda do CARRIN
          styleInformation: BigTextStyleInformation(
            bigText,
            contentTitle: title,
            summaryText: subText ?? '$bought/$total itens',
          ),
          visibility: NotificationVisibility.public, 
          icon: cartNotificationIcon,
          largeIcon: const DrawableResourceAndroidBitmap(appLogoIcon),
        );

        final NotificationDetails platformChannelSpecifics = NotificationDetails(
          android: androidPlatformChannelSpecifics,
        );

        await _notificationsPlugin.show(
          progressNotificationId,
          title,
          content,
          platformChannelSpecifics,
        );
      } catch (inner) {
        debugPrint('Fallback progress com @mipmap/launcher_icon: $inner');
        final AndroidNotificationDetails fallbackSpecifics = AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          ticker: 'Carrin atualizado',
          ongoing: false,
          autoCancel: false,
          onlyAlertOnce: true, 
          showProgress: true,
          maxProgress: total,
          progress: bought,
          subText: subText,
          color: const Color(0xFF10B981),
          styleInformation: BigTextStyleInformation(
            bigText,
            contentTitle: title,
            summaryText: subText ?? '$bought/$total itens',
          ),
          visibility: NotificationVisibility.public, 
          icon: '@mipmap/launcher_icon',
          largeIcon: const DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
        );

        await _notificationsPlugin.show(
          progressNotificationId,
          title,
          content,
          NotificationDetails(android: fallbackSpecifics),
        );
      }
    } catch (e) {
      debugPrint('Erro ao disparar showOrUpdateProgress: $e');
    }
  }

  /// Cancels the shopping progress notification.
  Future<void> cancelProgress() async {
    try {
      await _notificationsPlugin.cancel(progressNotificationId);
    } catch (_) {}
  }

  /// Cancels all active notifications.
  Future<void> cancelAll() async {
    try {
      await _notificationsPlugin.cancelAll();
    } catch (_) {}
  }
}
