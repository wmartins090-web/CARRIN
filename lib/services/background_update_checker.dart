import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'app_update_service.dart';
import 'notification_service.dart';

/// Identificadores das tarefas agendadas no WorkManager nativo do Android
const String backgroundUpdateTaskKey = 'com.wmartins.carrin.periodic_update_check';
const String backgroundUpdateUniqueName = 'carrin_periodic_update_check';

/// Chave em SharedPreferences para não enviar notificações repetidas da mesma versão
const String prefLastNotifiedUpdateVersionKey = 'last_notified_update_version';

/// Ponto de entrada de execução em background invocado pelo WorkManager do Android
@pragma('vm:entry-point')
void backgroundUpdateCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      if (Platform.isAndroid) {
        final updateService = AppUpdateService.instance;
        final info = await updateService.checkForUpdate();
        if (info != null) {
          final prefs = await SharedPreferences.getInstance();
          final lastNotified = prefs.getString(prefLastNotifiedUpdateVersionKey);

          // Dispara notificação apenas se for uma nova versão ainda não notificada
          if (lastNotified != info.version) {
            await NotificationService().init();
            await NotificationService().showUpdateAvailable(
              version: info.version,
              buildNumber: info.buildNumber,
              title: '🚀 Nova Atualização do CARRIN (v${info.version})',
              notes: info.releaseNotes,
            );
            await prefs.setString(prefLastNotifiedUpdateVersionKey, info.version);
          }
        }
      }
    } catch (e) {
      debugPrint('Aviso: Erro na tarefa em segundo plano de verificação de atualização: $e');
    }
    return Future.value(true);
  });
}

/// Serviço responsável por gerenciar a verificação periódica de atualizações em segundo plano
class BackgroundUpdateChecker {
  BackgroundUpdateChecker._();

  static bool _isInitialized = false;

  /// Inicializa o WorkManager e agenda a verificação periódica de atualizações
  static Future<void> initialize() async {
    if (!Platform.isAndroid || _isInitialized) return;

    try {
      await Workmanager().initialize(
        backgroundUpdateCallbackDispatcher,
      );

      // Agenda tarefa periódica a cada 6 horas com restrição de conexão com a internet
      await Workmanager().registerPeriodicTask(
        backgroundUpdateUniqueName,
        backgroundUpdateTaskKey,
        frequency: const Duration(hours: 6),
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      );

      _isInitialized = true;
      debugPrint('BackgroundUpdateChecker inicializado com sucesso.');
    } catch (e) {
      debugPrint('Aviso ao inicializar BackgroundUpdateChecker: $e');
    }
  }

  /// Cancela o agendamento da tarefa de verificação
  static Future<void> cancelPeriodicCheck() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().cancelByUniqueName(backgroundUpdateUniqueName);
    } catch (e) {
      debugPrint('Aviso ao cancelar verificação periódica: $e');
    }
  }

  /// Permite disparar uma verificação única imediata em segundo plano para testes ou depuração
  static Future<void> triggerImmediateOneOffCheck() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().registerOneOffTask(
        'carrin_one_off_update_check_${DateTime.now().millisecondsSinceEpoch}',
        backgroundUpdateTaskKey,
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
      );
    } catch (e) {
      debugPrint('Aviso ao registrar one-off update check: $e');
    }
  }
}
