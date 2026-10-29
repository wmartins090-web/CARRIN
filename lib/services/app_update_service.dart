import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';

/// Modelo de dados da versão remota disponível
class AppUpdateInfo {
  final String version;
  final int buildNumber;
  final String releaseDate;
  final String title;
  final List<String> releaseNotes;
  final String apkUrl;
  final int? sizeBytes;
  final bool isActive;
  final bool forceUpdate;

  AppUpdateInfo({
    required this.version,
    required this.buildNumber,
    required this.releaseDate,
    required this.title,
    required this.releaseNotes,
    required this.apkUrl,
    this.sizeBytes,
    this.isActive = true,
    this.forceUpdate = false,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    List<String> notes = [];
    if (json['release_notes'] is List) {
      notes = (json['release_notes'] as List).map((e) => e.toString()).toList();
    } else if (json['release_notes'] is String) {
      notes = (json['release_notes'] as String)
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }

    return AppUpdateInfo(
      version: json['version']?.toString() ?? '1.0.0',
      buildNumber: int.tryParse(json['build_number']?.toString() ?? '0') ?? 0,
      releaseDate: json['release_date']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Nova Atualização',
      releaseNotes: notes,
      apkUrl: json['apk_url']?.toString() ?? '',
      sizeBytes: int.tryParse(json['size_bytes']?.toString() ?? ''),
      isActive: json['is_active'] == null ? true : (json['is_active'] == true),
      forceUpdate: json['force_update'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'build_number': buildNumber,
    'release_date': releaseDate,
    'title': title,
    'release_notes': releaseNotes,
    'apk_url': apkUrl,
    'size_bytes': sizeBytes,
    'is_active': isActive,
    'force_update': forceUpdate,
  };
}

/// Serviço responsável por identificar atualizações, baixar APKs e invocar a instalação nativa.
class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static String currentAppVersion = '1.3.586';
  static int currentBuildNumber = 586;

  /// Inicializa dinamicamente as informações reais do pacote instalado no Android
  static Future<void> initPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      currentAppVersion = info.version;
      currentBuildNumber = int.tryParse(info.buildNumber) ?? currentBuildNumber;
    } catch (_) {}
  }

  static const MethodChannel _installerChannel = MethodChannel('com.wmartins.carrin/installer');

  static const String primaryVersionUrl =
      'https://raw.githubusercontent.com/hollopocran/CARRIN/main/version.json';
  static const String fallbackVersionUrl =
      'https://cdn.jsdelivr.net/gh/hollopocran/CARRIN@main/version.json';

  static const String _prefCustomVersionUrlKey = 'custom_app_version_url';
  static const String _prefDismissedBuildKey = 'dismissed_update_build';

  /// Armazena o último motivo de falha na consulta (ex: 404 por repo privado ou falha de conexão)
  String? lastFetchError;

  /// Consulta a versão mais recente disponível na nuvem
  Future<AppUpdateInfo?> fetchLatestUpdateInfo() async {
    lastFetchError = null;
    final prefs = await SharedPreferences.getInstance();
    final customUrl = prefs.getString(_prefCustomVersionUrlKey);
    final urlsToTry = [
      if (customUrl != null && customUrl.trim().isNotEmpty) customUrl.trim(),
      primaryVersionUrl,
      fallbackVersionUrl,
    ];

    int notFoundCount = 0;
    int connectionErrorCount = 0;

    for (final url in urlsToTry) {
      try {
        final uri = Uri.parse(url);
        final response = await http.get(uri).timeout(const Duration(seconds: 6));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is Map<String, dynamic>) {
            final info = AppUpdateInfo.fromJson(decoded);
            if (info.isActive) {
              lastFetchError = null;
              return info;
            }
          }
        } else if (response.statusCode == 404) {
          notFoundCount++;
          debugPrint('Aviso: $url retornou HTTP 404 (arquivo não encontrado ou repositório privado)');
        }
      } catch (e) {
        connectionErrorCount++;
        debugPrint('Erro ao consultar versão em $url: $e');
      }
    }

    if (notFoundCount > 0) {
      lastFetchError = 'Erro 404: Arquivo version.json não encontrado. Verifique se a visibilidade do repositório no GitHub está como "Público".';
    } else if (connectionErrorCount == urlsToTry.length) {
      lastFetchError = 'Falha de conexão ao verificar atualizações. Verifique sua internet.';
    }

    return null;
  }

  /// Verifica se há uma versão mais nova que a instalada
  Future<AppUpdateInfo?> checkForUpdate({bool ignoreDismissed = false}) async {
    final info = await fetchLatestUpdateInfo();
    if (info == null) return null;

    final isNewer = info.buildNumber > currentBuildNumber ||
        _isSemanticVersionGreater(info.version, currentAppVersion);

    if (!isNewer) return null;

    if (!ignoreDismissed && !info.forceUpdate) {
      final prefs = await SharedPreferences.getInstance();
      final dismissedBuild = prefs.getInt(_prefDismissedBuildKey) ?? 0;
      if (dismissedBuild >= info.buildNumber) {
        return null; // Usuário pediu para lembrar depois desta build
      }
    }

    return info;
  }

  /// Guarda que o usuário dispensou temporariamente esta build
  Future<void> dismissBuild(int buildNumber) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefDismissedBuildKey, buildNumber);
  }

  /// Verifica se a permissão para instalar APKs desconhecidos está ativa no Android
  Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? canInstall = await _installerChannel.invokeMethod<bool>('canRequestPackageInstalls');
      return canInstall ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Abre as configurações do Android para permitir instalação a partir deste app
  Future<void> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _installerChannel.invokeMethod('openInstallPermissionSettings');
    } catch (e) {
      debugPrint('Erro ao abrir configurações de instalação: $e');
    }
  }

  /// Dispara a instalação nativa do APK baixado via FileProvider
  Future<bool> installApk(String filePath) async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? result = await _installerChannel.invokeMethod<bool>('installApk', {
        'filePath': filePath,
      });
      return result ?? false;
    } catch (e) {
      debugPrint('Erro nativo ao invocar instalador do Android: $e');
      return false;
    }
  }

  // Estado do download em segundo plano
  bool _isDownloadingInBackground = false;
  double _backgroundProgress = 0.0;
  int _backgroundReceived = 0;
  int _backgroundTotal = 0;
  AppUpdateInfo? _downloadingInfo;
  AppUpdateInfo? _readyUpdateInfo;
  String? _readyApkPath;

  bool get isDownloadingInBackground => _isDownloadingInBackground;
  double get backgroundProgress => _backgroundProgress;
  int get backgroundReceived => _backgroundReceived;
  int get backgroundTotal => _backgroundTotal;
  AppUpdateInfo? get readyUpdateInfo => _readyUpdateInfo;
  String? get readyApkPath => _readyApkPath;

  /// Retorna o arquivo APK já baixado se ele existir e estiver íntegro no cache
  /// Valida se o arquivo APK está completo e com integridade de arquivo ZIP válida (assinatura EOCD)
  static Future<bool> isApkFileValid(File file, {int? expectedBytes}) async {
    try {
      if (!await file.exists()) return false;
      final len = await file.length();
      // Um APK completo do CARRIN tem ~110MB+ (mínimo absoluto 50MB)
      if (len < 50 * 1024 * 1024) return false;
      if (expectedBytes != null && expectedBytes > 0 && len != expectedBytes) {
        return false;
      }

      // Um arquivo ZIP/APK válido DEVE conter o registro End of Central Directory (EOCD),
      // cuja assinatura é [0x50, 0x4B, 0x05, 0x06] nos últimos 65.557 bytes.
      final raf = await file.open(mode: FileMode.read);
      try {
        final searchLength = len < 65557 ? len : 65557;
        await raf.setPosition(len - searchLength);
        final bytes = await raf.read(searchLength);
        for (int i = bytes.length - 4; i >= 0; i--) {
          if (bytes[i] == 0x50 &&
              bytes[i + 1] == 0x4b &&
              bytes[i + 2] == 0x05 &&
              bytes[i + 3] == 0x06) {
            return true;
          }
        }
        return false;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Retorna o arquivo APK já baixado se ele existir e for comprovadamente íntegro no cache
  Future<File?> getDownloadedApk(AppUpdateInfo info) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final apkFile = File('${tempDir.path}/carrin_v${info.version}_b${info.buildNumber}.apk');
      if (await apkFile.exists()) {
        final isValid = await isApkFileValid(apkFile, expectedBytes: info.sizeBytes);
        if (isValid) {
          _readyUpdateInfo = info;
          _readyApkPath = apkFile.path;
          return apkFile;
        } else {
          // Arquivo corrompido ou download parcial no cache: deleta para não travar o app
          await apkFile.delete().catchError((_) => apkFile);
          _readyUpdateInfo = null;
          _readyApkPath = null;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Limpa APKs antigos de versões anteriores da pasta temporária
  Future<void> cleanOldDownloadedApks() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = tempDir.listSync();
      for (final f in files) {
        if (f is File) {
          final p = f.path;
          if (p.contains('carrin_') && (p.endsWith('.apk') || p.endsWith('.part'))) {
            if (_readyApkPath != p) {
              await f.delete().catchError((_) => f);
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Executa o download silenciosamente em background sem interromper o usuário.
  /// Quando terminar, invoca o callback onReady com o info e o caminho do APK pronto.
  Future<File?> downloadInBackground(
    AppUpdateInfo info, {
    void Function(AppUpdateInfo info, String filePath)? onReady,
  }) async {
    // 1. Verifica se já está em disco
    final existing = await getDownloadedApk(info);
    if (existing != null) {
      _readyUpdateInfo = info;
      _readyApkPath = existing.path;
      onReady?.call(info, existing.path);
      return existing;
    }

    if (_isDownloadingInBackground && _downloadingInfo?.buildNumber == info.buildNumber) {
      return null; // Já está baixando em segundo plano
    }

    _isDownloadingInBackground = true;
    _downloadingInfo = info;
    _backgroundProgress = 0.0;
    _backgroundReceived = 0;
    _backgroundTotal = 0;

    try {
      final file = await downloadApk(
        apkUrl: info.apkUrl,
        buildNumber: info.buildNumber,
        version: info.version,
        onProgress: (prog, received, total) {
          _backgroundProgress = prog;
          _backgroundReceived = received;
          _backgroundTotal = total;
        },
      );

      _isDownloadingInBackground = false;
      _downloadingInfo = null;
      _readyUpdateInfo = info;
      _readyApkPath = file.path;

      // Limpa downloads obsoletos em background
      cleanOldDownloadedApks();

      // Dispara notificação nativa na barra de status informando que o APK está pronto
      NotificationService().showUpdateReady(
        version: info.version,
        apkPath: file.path,
      );

      onReady?.call(info, file.path);
      return file;
    } catch (e) {
      _isDownloadingInBackground = false;
      _downloadingInfo = null;
      debugPrint('Aviso: falha no download silencioso do APK: $e');
      return null;
    }
  }

  /// Baixa o APK com acompanhamento de progresso em tempo real e escrita atômica (.part -> .apk)
  Future<File> downloadApk({
    required String apkUrl,
    int? buildNumber,
    String? version,
    void Function(double progress, int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final uri = Uri.parse(apkUrl);
      final request = http.Request('GET', uri);
      final response = await client.send(request);

      if (response.statusCode != 200 && response.statusCode != 302) {
        throw Exception('Servidor retornou código ${response.statusCode} ao baixar o APK.');
      }

      http.StreamedResponse finalResponse = response;
      if (response.statusCode == 302 && response.headers.containsKey('location')) {
        final redirectUri = Uri.parse(response.headers['location']!);
        final redirectRequest = http.Request('GET', redirectUri);
        finalResponse = await client.send(redirectRequest);
      }

      final totalBytes = finalResponse.contentLength ?? 0;
      final tempDir = await getTemporaryDirectory();
      final suffix = (version != null && buildNumber != null)
          ? 'carrin_v${version}_b$buildNumber'
          : 'carrin_update';
      final apkFile = File('${tempDir.path}/$suffix.apk');
      final partFile = File('${tempDir.path}/$suffix.apk.part');

      if (await partFile.exists()) {
        await partFile.delete().catchError((_) => partFile);
      }

      final sink = partFile.openWrite();
      int receivedBytes = 0;

      await for (final chunk in finalResponse.stream) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        final progress = totalBytes > 0 ? (receivedBytes / totalBytes) : 0.0;
        onProgress?.call(progress, receivedBytes, totalBytes);
      }

      await sink.flush();
      await sink.close();

      if (totalBytes > 0 && receivedBytes < totalBytes) {
        await partFile.delete().catchError((_) => partFile);
        throw Exception('Download incompleto ( de  bytes recebidos).');
      }

      final isValid = await isApkFileValid(partFile, expectedBytes: totalBytes > 0 ? totalBytes : null);
      if (!isValid) {
        await partFile.delete().catchError((_) => partFile);
        throw Exception('Arquivo APK baixado está corrompido ou incompleto.');
      }

      if (await apkFile.exists()) {
        await apkFile.delete().catchError((_) => apkFile);
      }
      await partFile.rename(apkFile.path);

      return apkFile;
    } finally {
      client.close();
    }
  }

  /// Checa se a versão A é maior que a versão B semanticamente (ex: 1.3.566 > 1.3.565)
  bool _isSemanticVersionGreater(String remote, String current) {
    try {
      final rParts = remote.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      final cParts = current.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      while (rParts.length < 3) {
        rParts.add(0);
      }
      while (cParts.length < 3) {
        cParts.add(0);
      }

      for (int i = 0; i < 3; i++) {
        if (rParts[i] > cParts[i]) return true;
        if (rParts[i] < cParts[i]) return false;
      }
    } catch (_) {}
    return false;
  }
}
