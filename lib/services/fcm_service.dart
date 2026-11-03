import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notification_service.dart';
import 'app_update_service.dart';

/// Handler executado em background quando uma mensagem Push do Firebase chega
/// com o aplicativo completamente fechado ou em segundo plano.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();

    final data = message.data;
    final notification = message.notification;

    final title = notification?.title ?? data['title'] ?? '🚀 Atualização do CARRIN';
    final version = data['version'] ?? AppUpdateService.currentAppVersion;
    final buildNumber = int.tryParse(data['build_number']?.toString() ?? '') ??
        AppUpdateService.currentBuildNumber + 1;

    await NotificationService().init();
    await NotificationService().showUpdateAvailable(
      version: version.toString(),
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

        if (settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional) {
          debugPrint('Permissão de Push concedida pelo usuário.');

          // Inscreve automaticamente no tópico de novas versões do CARRIN
          await messaging.subscribeToTopic(topicAppUpdates);
          await messaging.subscribeToTopic(topicGeneral);
          debugPrint('Inscrito nos tópicos FCM: $topicAppUpdates e $topicGeneral');
        }

        // Ouvinte para mensagens recebidas com o app em primeiro plano (aberto)
        FirebaseMessaging.onMessage.listen((RemoteMessage message) {
          final notification = message.notification;
          final data = message.data;

          final title = notification?.title ?? data['title'] ?? '🚀 Atualização do CARRIN';
          final version = data['version'] ?? AppUpdateService.currentAppVersion;
          final buildNumber = int.tryParse(data['build_number']?.toString() ?? '') ??
              AppUpdateService.currentBuildNumber + 1;

          NotificationService().showUpdateAvailable(
            version: version.toString(),
            buildNumber: buildNumber,
            title: title.toString(),
          );
        });

        // Ouvinte para quando o usuário toca na notificação e abre o app
        FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
          debugPrint('App aberto a partir de uma notificação FCM: ${message.data}');
          AppUpdateService.instance.checkForUpdate();
        });

        _initialized = true;
      }
    } catch (e) {
      debugPrint('Aviso ao inicializar FcmService: $e');
    }
  }
}
