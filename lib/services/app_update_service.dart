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
/// Chave global do navegador para navegação de atualizações e notificações
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static String currentAppVersion = '1.3.632';
  static int currentBuildNumber = 632;

  /// Inicializa dinamicamente as informações reais do pacote instalado no Android
  static Future<void> initPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      currentAppVersion = info.version;
      currentBuildNumber = int.tryParse(info.buildNumber) ?? currentBuildNumber;
    } catch (_) {}
  }

  static const MethodChannel _installerChannel = MethodChannel('com.wmartins.carrin/installer');

  static const String r2VersionUrl =
      'https://pub-4bdefe4ec784476eae543ebde4bd2f20.r2.dev/version.json';
  static const String primaryVersionUrl =
      'https://raw.githubusercontent.com/wmartins090-web/CARRIN/main/version.json';
  static const String fallbackVersionUrl =
      'https://cdn.jsdelivr.net/gh/wmartins090-web/CARRIN@main/version.json';

  static const String _prefCustomVersionUrlKey = 'custom_app_version_url';
  static const String _prefDismissedBuildKey = 'dismissed_update_build';
  static const String _prefDismissedVersionKey = 'dismissed_update_version';

  /// Armazena o último motivo de falha na consulta (ex: 404 por repo privado ou falha de conexão)
  String? lastFetchError;

  /// Consulta a versão mais recente disponível na nuvem
  Future<AppUpdateInfo?> fetchLatestUpdateInfo() async {
    lastFetchError = null;
    final prefs = await SharedPreferences.getInstance();
    final customUrl = prefs.getString(_prefCustomVersionUrlKey);
    final urlsToTry = [
      if (customUrl != null && customUrl.trim().isNotEmpty) customUrl.trim(),
      r2VersionUrl,
      primaryVersionUrl,
      fallbackVersionUrl,
    ];

    int notFoundCount = 0;
    int connectionErrorCount = 0;

    for (final url in urlsToTry) {
      try {
        final separator = url.contains('?') ? '&' : '?';
        final uri = Uri.parse('$url' + separator + '_cb=' + DateTime.now().millisecondsSinceEpoch.toString());
        final response = await http.get(uri, headers: {'User-Agent': 'CARRIN-App/1.0'}).timeout(const Duration(seconds: 6));
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
      final isDismissed = await isBuildDismissed(info.buildNumber, version: info.version);
      if (isDismissed) {
        return null; // Usuário pediu para lembrar depois desta build/versão
      }
    }

    return info;
  }

  /// Guarda que o usuário dispensou temporariamente esta build ou versão
  Future<void> dismissBuild(int buildNumber, {String? version}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefDismissedBuildKey, buildNumber);
    if (version != null && version.isNotEmpty) {
      await prefs.setString(_prefDismissedVersionKey, version);
    }
  }

  /// Verifica se esta build ou versão foi dispensada pelo usuário
  Future<bool> isBuildDismissed(int buildNumber, {String? version}) async {
    final prefs = await SharedPreferences.getInstance();
    final dismissedBuild = prefs.getInt(_prefDismissedBuildKey) ?? 0;
    if (buildNumber <= dismissedBuild) return true;
    final dismissedVersion = prefs.getString(_prefDismissedVersionKey);
    if (version != null && version.isNotEmpty && dismissedVersion == version) {
      return true;
    }
    return false;
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
    // Se o usuário dispensou esta versão e não for forçada, não baixa nem notifica
    if (!info.forceUpdate && await isBuildDismissed(info.buildNumber, version: info.version)) {
      debugPrint('AppUpdateService: downloadInBackground ignorado pois v${info.version} foi dispensada.');
      return null;
    }

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
        expectedSizeBytes: info.sizeBytes,
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
        buildNumber: info.buildNumber,
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

  /// Retorna quantos bytes já foram baixados em arquivo parcial (.part) para esta versão.
  Future<int> getPartialApkBytes(AppUpdateInfo info) async {
    try {
      final tempDir = await getTemporaryDirectory();
      final partFile = File('${tempDir.path}/carrin_v${info.version}_b${info.buildNumber}.apk.part');
      if (await partFile.exists()) {
        return await partFile.length();
      }
    } catch (_) {}
    return 0;
  }

  /// Envia requisição GET preservando o cabeçalho [Range] mesmo através de redirecionamentos (301/302/307/308).
  Future<http.StreamedResponse> _sendGetWithRedirects(
    http.Client client,
    Uri initialUri, {
    int startByte = 0,
    int maxRedirects = 5,
  }) async {
    Uri currentUri = initialUri;
    for (int hop = 0; hop <= maxRedirects; hop++) {
      final request = http.Request('GET', currentUri);
      request.followRedirects = false;
      request.headers['User-Agent'] = 'CARRIN-App/1.0';
      if (startByte > 0) {
        request.headers['Range'] = 'bytes=$startByte-';
      }

      final response = await client.send(request).timeout(const Duration(seconds: 20));
      final code = response.statusCode;
      if ((code == 301 || code == 302 || code == 303 || code == 307 || code == 308) &&
          response.headers['location'] != null) {
        final loc = response.headers['location']!;
        await response.stream.drain<void>().catchError((_) {});
        currentUri = currentUri.resolve(loc);
        continue;
      }
      return response;
    }
    throw Exception('Excesso de redirecionamentos ao baixar o APK.');
  }

  int _parseTotalBytesFromContentRange(String? contentRange, int existingBytes, int? contentLength) {
    if (contentRange != null && contentRange.isNotEmpty) {
      final match = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(contentRange);
      if (match != null) {
        final parsed = int.tryParse(match.group(1)!);
        if (parsed != null && parsed > 0) return parsed;
      }
    }
    if (contentLength != null && contentLength > 0) {
      return existingBytes + contentLength;
    }
    return 0;
  }

  /// Baixa o APK com retomada automática (HTTP Range 206), escrita incremental em `.part`
  /// e recuperação automática caso a internet caia ou troque entre Wi-Fi e dados móveis.
  Future<File> downloadApk({
    required String apkUrl,
    int? buildNumber,
    String? version,
    int? expectedSizeBytes,
    @visibleForTesting Directory? targetDirectoryOverride,
    @visibleForTesting bool skipApkValidationForTesting = false,
    @visibleForTesting Duration retryDelay = const Duration(milliseconds: 1800),
    @visibleForTesting int maxRetriesPerUrl = 4,
    @visibleForTesting http.Client Function()? httpClientFactory,
    void Function(double progress, int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final List<String> candidateUrls = [apkUrl];
    final String fileName = apkUrl.split('/').last.split('?').first;
    if (apkUrl.contains('pub-4bdefe4ec784476eae543ebde4bd2f20.r2.dev')) {
      final ghTag = version != null ? 'v$version' : 'v$currentAppVersion';
      candidateUrls.add('https://github.com/wmartins090-web/CARRIN/releases/download/$ghTag/$fileName');
    } else if (apkUrl.contains('github.com')) {
      candidateUrls.add('https://pub-4bdefe4ec784476eae543ebde4bd2f20.r2.dev/$fileName');
    }

    final Directory dir = targetDirectoryOverride ?? await getTemporaryDirectory();
    final String suffix = (version != null && buildNumber != null)
        ? 'carrin_v${version}_b$buildNumber'
        : 'carrin_update';
    final File apkFile = File('${dir.path}/$suffix.apk');
    final File partFile = File('${dir.path}/$suffix.apk.part');

    Exception? lastException;
    for (int urlIdx = 0; urlIdx < candidateUrls.length; urlIdx++) {
      final currentUrl = candidateUrls[urlIdx];
      final uri = Uri.parse(currentUrl);

      for (int attempt = 0; attempt < maxRetriesPerUrl; attempt++) {
        // Cria um HttpClient novo por tentativa para evitar reaproveitar socket morto após troca Wi-Fi <-> 4G
        final client = (httpClientFactory ?? http.Client.new)();
        IOSink? sink;
        try {
          int existingBytes = await partFile.exists() ? await partFile.length() : 0;
          if (expectedSizeBytes != null && expectedSizeBytes > 0 && existingBytes > expectedSizeBytes) {
            await partFile.delete().catchError((_) => partFile);
            existingBytes = 0;
          }

          final response = await _sendGetWithRedirects(
            client,
            uri,
            startByte: existingBytes,
          );

          int totalBytes = expectedSizeBytes ?? 0;
          int receivedBytes = 0;

          if (response.statusCode == 416) {
            final cr = response.headers['content-range'];
            await response.stream.drain<void>().catchError((_) {});
            final totalMatch = cr != null ? RegExp(r'/(\d+)').firstMatch(cr) : null;
            final remoteTotal = totalMatch != null ? int.tryParse(totalMatch.group(1)!) : null;
            if (remoteTotal != null && existingBytes == remoteTotal) {
              totalBytes = remoteTotal;
              receivedBytes = existingBytes;
            } else {
              await partFile.delete().catchError((_) => partFile);
              continue;
            }
          } else if (response.statusCode == 206 && existingBytes > 0) {
            final cr = response.headers['content-range'];
            totalBytes = _parseTotalBytesFromContentRange(cr, existingBytes, response.contentLength);
            final startMatch = cr != null ? RegExp(r'bytes\s+(\d+)-').firstMatch(cr) : null;
            final startOffset = startMatch != null ? int.tryParse(startMatch.group(1)!) : existingBytes;

            if (startOffset == existingBytes) {
              receivedBytes = existingBytes;
              sink = partFile.openWrite(mode: FileMode.append);
            } else {
              receivedBytes = 0;
              sink = partFile.openWrite(mode: FileMode.write);
            }

            if (totalBytes > 0) {
              onProgress?.call((receivedBytes / totalBytes).clamp(0.0, 1.0), receivedBytes, totalBytes);
            }

            await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
              sink.add(chunk);
              receivedBytes += chunk.length;
              final progress = totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
              onProgress?.call(progress, receivedBytes, totalBytes);
            }
          } else if (response.statusCode == 200) {
            totalBytes = response.contentLength ?? totalBytes;
            receivedBytes = 0;
            sink = partFile.openWrite(mode: FileMode.write);

            await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
              sink.add(chunk);
              receivedBytes += chunk.length;
              final progress = totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
              onProgress?.call(progress, receivedBytes, totalBytes);
            }
          } else {
            await response.stream.drain<void>().catchError((_) {});
            throw Exception('Servidor retornou código ${response.statusCode} ao baixar o APK.');
          }

          if (sink != null) {
            await sink.flush();
            await sink.close();
            sink = null;
          }

          final actualLen = await partFile.exists() ? await partFile.length() : 0;
          if (totalBytes > 0 && actualLen < totalBytes) {
            throw Exception('Conexão interrompida ($actualLen de $totalBytes bytes recebidos).');
          }

          if (!skipApkValidationForTesting) {
            final isValid = await isApkFileValid(
              partFile,
              expectedBytes: totalBytes > 0 ? totalBytes : expectedSizeBytes,
            );
            if (!isValid) {
              await partFile.delete().catchError((_) => partFile);
              throw Exception('Arquivo APK baixado está corrompido ou incompleto.');
            }
          }

          if (await apkFile.exists()) {
            await apkFile.delete().catchError((_) => apkFile);
          }
          await partFile.rename(apkFile.path);
          return apkFile;
        } catch (e) {
          if (sink != null) {
            try {
              await sink.flush();
              await sink.close();
            } catch (_) {}
          }
          debugPrint('Tentativa ${attempt + 1}/$maxRetriesPerUrl falhou para $currentUrl: $e');
          lastException = e is Exception ? e : Exception(e.toString());
          if (attempt + 1 < maxRetriesPerUrl) {
            await Future.delayed(retryDelay);
          }
        } finally {
          client.close();
        }
      }
    }

    throw lastException ?? Exception('Falha ao baixar o arquivo APK em todas as fontes disponíveis.');
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
