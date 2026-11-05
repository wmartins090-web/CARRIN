import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notification_service.dart';
import 'app_update_service.dart';
import '../widgets/app_update_dialog.dart';

/// Handler executado em background quando uma mensagem Push do Firebase chega
/// com o aplicativo completamente fechado ou em segundo plano.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();

    final notification = message.notification;
    // Se a notificação já foi exibida nativamente pelo Android (payload 'notification' presente),
    // NÃO duplicamos chamando showUpdateAvailable novamente!
    if (notification != null) {
      debugPrint('FCM: Notificação nativa já exibida pelo Android. Ignorando duplicação.');
      return;
    }

    final data = message.data;
    final title = data['title'] ?? '🚀 Atualização do CARRIN';
    final version = (data['version'] ?? AppUpdateService.currentAppVersion).toString();
    final buildNumber = int.tryParse(data['build_number']?.toString() ?? '') ??
        AppUpdateService.currentBuildNumber + 1;

    // Se o usuário dispensou esta versão ou build, não exibe notificação
    if (await AppUpdateService.instance.isBuildDismissed(buildNumber, version: version)) {
      debugPrint('FCM Background: Atualização v$version já dispensada pelo usuário. Ignorando.');
      return;
    }

    await NotificationService().init();
    await NotificationService().showUpdateAvailable(
      version: version,
      buildNumber: buildNumber,
      title: title.toString(),
    );
  } catch (e) {
    debugPrint('Erro no background handler do FCM: $e');
  }
}

/// Serviço responsável por gerenciar a comunicação com o Firebase Cloud Messaging (FCM)
class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  bool _initialized = false;

  /// Tópico padrão para broadcast de novas versões para todos os usuários
  static const String topicAppUpdates = 'novas_versoes';
  static const String topicGeneral = 'carrin_geral';

  /// Inicializa o Firebase e registra os ouvintes de notificações push
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await Firebase.initializeApp();

        // Registra o handler para mensagens recebidas com o app fechado
        FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

        final messaging = FirebaseMessaging.instance;

        // Solicita permissões de notificação (Android 13+ e iOS)
        final settings = await messaging.requestPermission(
          alert: true,
          badge: true,
          sound: true,
          provisional: false,
        );

        debugPrint('FCM Status: ${settings.authorizationStatus}');
        try {
          await messaging.subscribeToTopic(topicAppUpdates);
          await messaging.subscribeToTopic(topicGeneral);
          debugPrint('Inscrito com sucesso nos topicos FCM: $topicAppUpdates e $topicGeneral');
        } catch (e) {
          debugPrint('Aviso ao inscrever nos topicos FCM: $e');
        }

        // Ouvinte para mensagens recebidas com o app em primeiro plano (aberto)
        FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
          final notification = message.notification;
          final data = message.data;

          final title = notification?.title ?? data['title'] ?? '🚀 Atualização do CARRIN';
          final version = (data['version'] ?? AppUpdateService.currentAppVersion).toString();
          final buildNumber = int.tryParse(data['build_number']?.toString() ?? '') ??
              AppUpdateService.currentBuildNumber + 1;

          if (await AppUpdateService.instance.isBuildDismissed(buildNumber, version: version)) {
            debugPrint('FCM Foreground: Atualização v$version já dispensada pelo usuário. Ignorando.');
            return;
          }

          NotificationService().showUpdateAvailable(
            version: version,
            buildNumber: buildNumber,
            title: title.toString(),
          );
        });

        // Ouvinte para quando o usuário toca na notificação e abre o app
        FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
          debugPrint('App aberto a partir de uma notificação FCM: ${message.data}');
          final v = message.data['version']?.toString();
          final b = int.tryParse(message.data['build_number']?.toString() ?? '');
          Future.delayed(const Duration(milliseconds: 600), () {
            AppUpdateDialog.openFromNotification(autoStartDownload: true, targetVersion: v, targetBuildNumber: b);
          });
        });

        // Caso o app tenha sido aberto a partir de uma notificação com o app fechado
        messaging.getInitialMessage().then((initialMessage) {
          if (initialMessage != null) {
            debugPrint('App aberto via getInitialMessage FCM: ${initialMessage.data}');
            final v = initialMessage.data['version']?.toString();
            final b = int.tryParse(initialMessage.data['build_number']?.toString() ?? '');
            Future.delayed(const Duration(milliseconds: 1000), () {
              AppUpdateDialog.openFromNotification(autoStartDownload: true, targetVersion: v, targetBuildNumber: b);
            });
          }
        });

        _initialized = true;
      }
    } catch (e) {
      debugPrint('Aviso ao inicializar FcmService: $e');
    }
  }
}
