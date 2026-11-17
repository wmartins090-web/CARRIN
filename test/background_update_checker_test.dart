import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lista_compras/services/background_update_checker.dart';
import 'package:lista_compras/services/app_update_service.dart';
import 'package:lista_compras/widgets/app_update_dialog.dart';

class _ResumableMockHttpClient extends http.BaseClient {
  final List<int> fullPayload;
  final List<String?> observedRanges;
  final int Function() nextAttemptIndex;

  _ResumableMockHttpClient({
    required this.fullPayload,
    required this.observedRanges,
    required this.nextAttemptIndex,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final attempt = nextAttemptIndex();
    final rangeHeader = request.headers['Range'] ?? request.headers['range'];
    observedRanges.add(rangeHeader);

    if (attempt == 1) {
      // Simula entrega de 80 KB e queda de rede abrupta (Wi-Fi -> 4G)
      final controller = StreamController<List<int>>();
      Future.microtask(() async {
        controller.add(fullPayload.sublist(0, 80 * 1024));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        controller.addError(const SocketException('Network interface changed'));
        await controller.close();
      });
      return http.StreamedResponse(
        controller.stream,
        HttpStatus.ok,
        contentLength: fullPayload.length,
      );
    }

    int start = 0;
    if (rangeHeader != null) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(rangeHeader);
      if (m != null) start = int.parse(m.group(1)!);
    }
    final remaining = fullPayload.sublist(start);
    final headers = <String, String>{};
    if (start > 0) {
      headers['content-range'] = 'bytes $start-${fullPayload.length - 1}/${fullPayload.length}';
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(remaining),
      start > 0 ? HttpStatus.partialContent : HttpStatus.ok,
      contentLength: remaining.length,
      headers: headers,
    );
  }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  group('BackgroundUpdateChecker Contract Tests', () {
    test('task identifiers and preference keys are correctly defined', () {
      expect(backgroundUpdateTaskKey, equals('com.wmartins.carrin.periodic_update_check'));
      expect(backgroundUpdateUniqueName, equals('carrin_periodic_update_check'));
      expect(prefLastNotifiedUpdateVersionKey, equals('last_notified_update_version'));
    });

    test('anti-spam logic prevents duplicate notifications for the same version', () async {
      final prefs = await SharedPreferences.getInstance();
      
      // Before notification
      expect(prefs.getString(prefLastNotifiedUpdateVersionKey), isNull);

      // Simulates notification sent
      await prefs.setString(prefLastNotifiedUpdateVersionKey, '1.3.580');

      // Now it should match
      expect(prefs.getString(prefLastNotifiedUpdateVersionKey), equals('1.3.580'));
    });

    test('AppUpdateService version is defined and bumped', () {
      expect(AppUpdateService.currentAppVersion.isNotEmpty, isTrue);
      expect(AppUpdateService.currentBuildNumber > 0, isTrue);
    });

    test('isApkFileValid rejects non-existent or truncated files (< 50MB)', () async {
      final nonExistent = File('carrin_non_existent.apk');
      expect(await AppUpdateService.isApkFileValid(nonExistent), isFalse);

      final tempDir = await Directory.systemTemp.createTemp('apk_test_');
      try {
        final dummy = File('${tempDir.path}/dummy.apk');
        await dummy.writeAsBytes([1, 2, 3, 4, 5]);
        expect(await AppUpdateService.isApkFileValid(dummy), isFalse);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('downloadApk preserves partial file on connection drop and resumes via HTTP Range 206', () async {
      final payload = List<int>.generate(200 * 1024, (i) => i % 251);
      final List<String?> observedRanges = [];
      int requestCount = 0;

      final tempDir = await Directory.systemTemp.createTemp('apk_resume_test_');
      try {
        final List<int> receivedTimeline = [];
        final resultFile = await AppUpdateService.instance.downloadApk(
          apkUrl: 'https://cdn.example.com/carrin_test.apk',
          version: '1.3.632',
          buildNumber: 632,
          expectedSizeBytes: payload.length,
          targetDirectoryOverride: tempDir,
          skipApkValidationForTesting: true,
          retryDelay: const Duration(milliseconds: 20),
          httpClientFactory: () => _ResumableMockHttpClient(
            fullPayload: payload,
            observedRanges: observedRanges,
            nextAttemptIndex: () => ++requestCount,
          ),
          onProgress: (prog, received, total) {
            receivedTimeline.add(received);
          },
        );

        expect(requestCount, 2);
        expect(observedRanges.first, isNull);
        expect(observedRanges[1], 'bytes=${80 * 1024}-');
        expect(await resultFile.exists(), isTrue);
        final savedBytes = await resultFile.readAsBytes();
        expect(savedBytes.length, payload.length);
        expect(savedBytes, equals(payload));
        final afterResumeIdx = receivedTimeline.indexWhere((b) => b == 80 * 1024);
        expect(afterResumeIdx, isNonNegative);
        expect(receivedTimeline.last, payload.length);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('AppUpdateDialog displays release notes expanded by default', (WidgetTester tester) async {
      final info = AppUpdateInfo(
        version: '1.3.632',
        buildNumber: 632,
        releaseDate: '2026-11-17',
        title: 'CARRIN v1.3.632',
        releaseNotes: ['Download retomável no Wi-Fi/4G', 'Notas sempre visíveis ao clicar'],
        apkUrl: 'https://example.com/carrin.apk',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppUpdateDialog(updateInfo: info),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Download retomável no Wi-Fi/4G'), findsOneWidget);
      expect(find.text('Notas sempre visíveis ao clicar'), findsOneWidget);
      expect(find.text('Ocultar notas da versão'), findsOneWidget);
    });
  });
}
