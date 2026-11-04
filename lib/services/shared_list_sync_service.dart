import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço de sincronização em tempo real para Listas Compartilhadas do CARRIN.
/// Conecta dispositivos instantaneamente sem necessidade de login Google,
/// utilizando canal de mensageria de alta velocidade e baixa latência.
class SharedListSyncService {
  SharedListSyncService._();
  static final SharedListSyncService instance = SharedListSyncService._();

  static const String _serverBase = 'https://ntfy.sh';
  static const String _deviceIdPrefKey = 'carrin_sync_device_id';

  String? _deviceId;
  String? _activeSyncId;
  Timer? _pollingTimer;
  int _lastSeenTimestamp = 0;
  bool _isPolling = false;
  Function(Map<String, dynamic> event)? _onRemoteUpdateCallback;

  /// Obtém ou inicializa o ID único e impessoal deste aparelho
  Future<String> getDeviceId() async {
    if (_deviceId != null && _deviceId!.isNotEmpty) return _deviceId!;
    try {
      final prefs = await SharedPreferences.getInstance();
      String? id = prefs.getString(_deviceIdPrefKey);
      if (id == null || id.isEmpty) {
        final rand = Random().nextInt(999999).toString().padLeft(6, '0');
        id = 'dev_${DateTime.now().millisecondsSinceEpoch}_$rand';
        await prefs.setString(_deviceIdPrefKey, id);
      }
      _deviceId = id;
      return id;
    } catch (_) {
      _deviceId ??= 'dev_${DateTime.now().millisecondsSinceEpoch}';
      return _deviceId!;
    }
  }

  /// Sanitiza o syncId para uso seguro como tópico HTTP
  String _toTopic(String syncId) {
    final clean = syncId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return 'carrin_sync_$clean';
  }

  /// Publica uma ação local (toggle, update, add, remove) para o canal da lista
  Future<bool> publishAction({
    required String syncId,
    required String action,
    required Map<String, dynamic> data,
  }) async {
    final cleanSyncId = syncId.trim();
    if (cleanSyncId.isEmpty) return false;

    try {
      final myDeviceId = await getDeviceId();
      final now = DateTime.now().millisecondsSinceEpoch;
      final topic = _toTopic(cleanSyncId);

      final messagePayload = {
        'v': 1,
        'sid': cleanSyncId,
        'did': myDeviceId,
        'ts': now,
        'act': action,
        'd': data,
      };

      final uri = Uri.parse('$_serverBase/$topic');
      final res = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          'Title': 'CARRIN Sync',
          'Priority': 'default',
        },
        body: jsonEncode(messagePayload),
      ).timeout(const Duration(seconds: 4));

      return res.statusCode == 200;
    } catch (e) {
      debugPrint('Aviso: falha temporária ao publicar sincronização em nuvem: $e');
      return false;
    }
  }

  /// Inicia o monitoramento ativo para a lista conectada
  Future<void> startListening({
    required String syncId,
    required Function(Map<String, dynamic> event) onRemoteUpdate,
  }) async {
    final cleanSyncId = syncId.trim();
    if (cleanSyncId.isEmpty) return;

    if (_activeSyncId == cleanSyncId && _pollingTimer != null && _pollingTimer!.isActive) {
      _onRemoteUpdateCallback = onRemoteUpdate;
      return;
    }

    stopListening();
    _activeSyncId = cleanSyncId;
    _onRemoteUpdateCallback = onRemoteUpdate;
    _lastSeenTimestamp = DateTime.now().millisecondsSinceEpoch - 1000;

    // Dispara a primeira busca imediatamente
    _pollLatestEvents();

    // Inicia ciclo contínuo de sincronização a cada 3.5 segundos enquanto a lista estiver aberta
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 3500), (_) {
      _pollLatestEvents();
    });
  }

  /// Interrompe a escuta ativa de sincronização
  void stopListening() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _activeSyncId = null;
    _onRemoteUpdateCallback = null;
    _isPolling = false;
  }

  /// Consulta eventos recentes no canal e processa apenas mensagens de outros aparelhos
  Future<void> _pollLatestEvents() async {
    final currentSync = _activeSyncId;
    if (currentSync == null || _isPolling) return;

    _isPolling = true;
    try {
      final myDeviceId = await getDeviceId();
      final topic = _toTopic(currentSync);
      // Busca mensagens dos últimos segundos (janela segura de 30s para cobrir eventuais oscilações de rede)
      final uri = Uri.parse('$_serverBase/$topic/json?poll=1&since=30s');

      final res = await http.get(
        uri,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode == 200 && res.body.isNotEmpty && _activeSyncId == currentSync) {
        final lines = res.body.split('\n');
        for (final line in lines) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;

          try {
            final envelope = jsonDecode(trimmed) as Map<String, dynamic>;
            if (envelope['event'] != 'message') continue;

            final rawMsg = envelope['message'];
            if (rawMsg == null) continue;

            Map<String, dynamic> msgData;
            if (rawMsg is String) {
              msgData = jsonDecode(rawMsg) as Map<String, dynamic>;
            } else if (rawMsg is Map<String, dynamic>) {
              msgData = rawMsg;
            } else {
              continue;
            }

            final senderDeviceId = msgData['did'] as String?;
            final messageTs = (msgData['ts'] as num?)?.toInt() ?? 0;

            // Ignora mensagens enviadas pelo próprio aparelho e mensagens antigas já processadas
            if (senderDeviceId == myDeviceId) continue;
            if (messageTs <= _lastSeenTimestamp) continue;

            _lastSeenTimestamp = messageTs;
            _onRemoteUpdateCallback?.call(msgData);
          } catch (_) {}
        }
      }
    } catch (_) {
      // Falha temporária de rede silenciosa
    } finally {
      _isPolling = false;
    }
  }
}
