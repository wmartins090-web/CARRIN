import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import '../models/item.dart';
import '../services/shelf_tag_parser.dart';
import '../widgets/shelf_tag_selection_sheet.dart';

const Color _emeraldColor = Color(0xFF10B981);

class BarcodeScannerScreen extends StatefulWidget {
  final String title;
  const BarcodeScannerScreen({super.key, this.title = 'Escanear'});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen>
    with SingleTickerProviderStateMixin {
  late final MobileScannerController controller;
  late final AnimationController _animController;
  late final Animation<double> _animation;
  bool _found = false;
  bool _isAnalyzingFrame = false;
  String? _processingLabel;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(
      autoStart: true,
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
      returnImage: true,
      formats: const [
        BarcodeFormat.all,
      ],
    );

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.05, end: 0.95).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    controller.dispose();
    super.dispose();
  }

  bool _isDirectQrPayload(String code) {
    final lower = code.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('carrin://') ||
        lower.contains('carrin.app/') ||
        lower.contains('docs.google.com/spreadsheets/') ||
        lower.contains('sefaz') ||
        lower.contains('fazenda') ||
        lower.contains('nfce') ||
        lower.contains('danfe') ||
        lower.contains('?p=') ||
        RegExp(r'^\d{44}$').hasMatch(code) ||
        (code.startsWith('{') && code.endsWith('}'));
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_found || _isAnalyzingFrame) return;
    String? code;
    for (final barcode in capture.barcodes) {
      final candidate = barcode.rawValue?.trim() ?? barcode.displayValue?.trim();
      if (candidate != null && candidate.isNotEmpty) {
        code = candidate;
        break;
      }
    }
    if (code == null || code.isEmpty) return;

    setState(() => _found = true);
    try {
      Vibration.vibrate(duration: 70);
    } catch (_) {}

    final frameBytes = capture.image;
    if (_isDirectQrPayload(code) || frameBytes == null || frameBytes.isEmpty) {
      if (mounted) {
        Navigator.pop(context, code);
      }
      return;
    }

    final cleanBarcode = Item.parseBarcode(code) ?? code;

    if (mounted) {
      setState(() {
        _isAnalyzingFrame = true;
        _processingLabel = 'Lendo etiqueta de gôndola...';
      });
    }

    ShelfTagResult? frameTagResult;
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('carrin_frame_');
      final tempFile = File('${tempDir.path}/scan.png');
      await tempFile.writeAsBytes(frameBytes, flush: true);
      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      try {
        final recognized = await recognizer.processImage(InputImage.fromFilePath(tempFile.path));
        final ocrLines = _extractOcrLines(recognized);
        final parsed = ocrLines.isNotEmpty
            ? ShelfTagParser.parseOcrLines(ocrLines, requirePriceContext: true)
            : ShelfTagParser.parse(recognized.text, requirePriceContext: true);
        if (parsed.hasAnyPrice) {
          frameTagResult = ShelfTagResult(
            productName: parsed.productName,
            barcode: cleanBarcode,
            retailPrice: parsed.retailPrice,
            wholesalePrice: parsed.wholesalePrice,
            allPrices: parsed.allPrices,
            rawText: parsed.rawText,
          );
        }
      } finally {
        await recognizer.close();
      }
    } catch (_) {
      frameTagResult = null;
    } finally {
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {}
    }

    if (!mounted) return;

    if (frameTagResult != null && frameTagResult.hasAnyPrice) {
      final resolvedTagResult = frameTagResult;
      setState(() {
        _isAnalyzingFrame = false;
        _processingLabel = null;
      });

      if (resolvedTagResult.hasMultiplePrices || resolvedTagResult.allPrices.length > 1) {
        bool selected = false;
        await ShelfTagSelectionSheet.show(
          context,
          tagResult: resolvedTagResult,
          onPriceSelected: (selectedPrice, prodName, barcode) {
            selected = true;
            final payload = jsonEncode({
              'name': prodName,
              'barcode': barcode ?? cleanBarcode,
              'price': selectedPrice.price,
              'quantity': selectedPrice.minQuantity ?? 1,
              'isWholesale': selectedPrice.isWholesale,
              'label': selectedPrice.label,
              'retailPrice': resolvedTagResult.retailPrice?.price,
              'wholesalePrice': resolvedTagResult.wholesalePrice?.price,
              'wholesaleMinQty': resolvedTagResult.wholesalePrice?.minQuantity,
            });
            Navigator.pop(context, '__ACTION_SHELF_TAG__:$payload');
          },
        );
        if (!selected && mounted) {
          setState(() => _found = false);
        }
        return;
      } else {
        final single = resolvedTagResult.allPrices.first;
        final payload = jsonEncode({
          'name': resolvedTagResult.productName,
          'barcode': cleanBarcode,
          'price': single.price,
          'quantity': single.minQuantity ?? 1,
          'isWholesale': single.isWholesale,
          'label': single.label,
          'retailPrice': resolvedTagResult.retailPrice?.price,
          'wholesalePrice': resolvedTagResult.wholesalePrice?.price,
          'wholesaleMinQty': resolvedTagResult.wholesalePrice?.minQuantity,
        });
        Navigator.pop(context, '__ACTION_SHELF_TAG__:$payload');
        return;
      }
    }

    Navigator.pop(context, code);
  }

  List<ShelfTagOcrLine> _extractOcrLines(RecognizedText recognized) {
    final List<ShelfTagOcrLine> lines = [];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final box = line.boundingBox;
        if (line.text.trim().isEmpty) continue;
        lines.add(ShelfTagOcrLine(
          text: line.text,
          left: box.left,
          top: box.top,
          right: box.right,
          bottom: box.bottom,
        ));
      }
    }
    return lines;
  }

  Future<void> _deleteTempFileQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<void> _scanShelfTag() async {
    String? capturedPath;
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 88,
      );
      if (image == null) return;
      capturedPath = image.path;

      if (!mounted) return;
      setState(() {
        _isAnalyzingFrame = true;
        _processingLabel = 'Lendo nome, preço e código (foto será descartada)...';
      });

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      RecognizedText? recognizedText;
      BarcodeCapture? barcodeCapture;
      try {
        final results = await Future.wait<dynamic>([
          recognizer.processImage(InputImage.fromFilePath(image.path)),
          controller.analyzeImage(image.path).catchError((_) => null),
        ]);
        recognizedText = results[0] as RecognizedText;
        barcodeCapture = results[1] as BarcodeCapture?;
      } finally {
        await recognizer.close();
        // Descarta imediatamente a foto temporária do aparelho após extrair os dados
        await _deleteTempFileQuietly(capturedPath);
        capturedPath = null;
      }

      String? imageBarcode;
      if (barcodeCapture != null) {
        for (final b in barcodeCapture.barcodes) {
          final raw = b.rawValue?.trim() ?? b.displayValue?.trim();
          if (raw != null && raw.isNotEmpty) {
            imageBarcode = Item.parseBarcode(raw) ?? raw;
            break;
          }
        }
      }

      final ocrLines = _extractOcrLines(recognizedText);
      final parsed = ocrLines.isNotEmpty
          ? ShelfTagParser.parseOcrLines(ocrLines)
          : ShelfTagParser.parse(recognizedText.text);
      final result = ShelfTagResult(
        productName: parsed.productName,
        barcode: imageBarcode ?? parsed.barcode,
        retailPrice: parsed.retailPrice,
        wholesalePrice: parsed.wholesalePrice,
        allPrices: parsed.allPrices,
        rawText: parsed.rawText,
      );

      if (!mounted) return;
      setState(() {
        _isAnalyzingFrame = false;
        _processingLabel = null;
      });

      if (!result.hasAnyPrice) {
        final bool hasPartialData =
            (result.barcode != null && result.barcode!.isNotEmpty) ||
            (result.productName != null && result.productName!.isNotEmpty);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              hasPartialData
                  ? 'Preço não identificado, mas li ${result.productName ?? 'código ${result.barcode}'}.'
                  : 'Nenhum preço nítido encontrado na foto. Aproxime a câmera da etiqueta da gôndola.',
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
            action: hasPartialData
                ? SnackBarAction(
                    label: 'USAR',
                    textColor: Colors.white,
                    onPressed: () {
                      if (!mounted) return;
                      final payload = jsonEncode({
                        'name': result.productName,
                        'barcode': result.barcode,
                        'price': null,
                        'quantity': 1,
                      });
                      Navigator.pop(context, '__ACTION_SHELF_TAG__:$payload');
                    },
                  )
                : null,
          ),
        );
        return;
      }

      await ShelfTagSelectionSheet.show(
        context,
        tagResult: result,
        onPriceSelected: (selectedPrice, prodName, barcode) {
          final payload = jsonEncode({
            'name': prodName,
            'barcode': barcode,
            'price': selectedPrice.price,
            'quantity': selectedPrice.minQuantity ?? 1,
            'isWholesale': selectedPrice.isWholesale,
            'label': selectedPrice.label,
            'retailPrice': result.retailPrice?.price,
            'wholesalePrice': result.wholesalePrice?.price,
            'wholesaleMinQty': result.wholesalePrice?.minQuantity,
          });
          Navigator.pop(context, '__ACTION_SHELF_TAG__:$payload');
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAnalyzingFrame = false;
          _processingLabel = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao analisar etiqueta: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          widget.title,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Colors.white,
            fontSize: 17,
            letterSpacing: 0.3,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          // Alternar Lanterna
          IconButton(
            tooltip: 'Lanterna',
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: controller,
              builder: (context, state, child) {
                final isOn = state.torchState == TorchState.on;
                return Icon(
                  isOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                  color: isOn ? Colors.amberAccent : Colors.white70,
                );
              },
            ),
            onPressed: () => controller.toggleTorch(),
          ),
          // Alternar Câmera
          IconButton(
            tooltip: 'Trocar Câmera',
            icon: const Icon(Icons.flip_camera_ios_rounded, color: Colors.white70),
            onPressed: () => controller.switchCamera(),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Viewfinder quadrado moderno e proporcional para ler códigos 1D e QR Codes
          final boxSize = (constraints.maxWidth * 0.72).clamp(240.0, 290.0);
          final scanRect = Rect.fromCenter(
            center: Offset(constraints.maxWidth / 2, constraints.maxHeight * 0.42),
            width: boxSize,
            height: boxSize,
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              // Câmera MobileScanner fluida
              MobileScanner(
                controller: controller,
                fit: BoxFit.cover,
                onDetect: _onDetect,
              ),

              // Overlay moderno e minimalista com recorte central arredondado
              CustomPaint(
                painter: _ScannerOverlayPainter(
                  scanWindow: scanRect,
                  borderRadius: 22,
                ),
              ),

              // Linha Laser suave e discreta
              AnimatedBuilder(
                animation: _animation,
                builder: (context, child) {
                  return Positioned(
                    top: scanRect.top + (scanRect.height * _animation.value),
                    left: scanRect.left + 16,
                    width: scanRect.width - 32,
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.white.withValues(alpha: 0.0),
                            _emeraldColor,
                            Colors.white,
                            _emeraldColor,
                            Colors.white.withValues(alpha: 0.0),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _emeraldColor.withValues(alpha: 0.7),
                            blurRadius: 8,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              // Botão único e limpo de câmera para fotografar etiqueta
              if (!widget.title.contains('NFC-e'))
                Positioned(
                  bottom: MediaQuery.of(context).padding.bottom + 32,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Tooltip(
                      message: 'Tirar foto da etiqueta',
                      child: GestureDetector(
                        onTap: _isAnalyzingFrame ? null : _scanShelfTag,
                        child: Container(
                          width: 76,
                          height: 76,
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3.5),
                            color: Colors.black.withValues(alpha: 0.25),
                          ),
                          child: Container(
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                            child: const Icon(
                              Icons.camera_alt_rounded,
                              color: Colors.black87,
                              size: 32,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (_isAnalyzingFrame)
                Container(
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 24),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: _emeraldColor.withValues(alpha: 0.6)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.4, color: _emeraldColor),
                          ),
                          const SizedBox(width: 14),
                          Flexible(
                            child: Text(
                              _processingLabel ?? 'Analisando etiqueta...',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ScannerOverlayPainter extends CustomPainter {
  final Rect scanWindow;
  final double borderRadius;

  _ScannerOverlayPainter({required this.scanWindow, this.borderRadius = 22});

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutoutPath = Path()
      ..addRRect(RRect.fromRectAndRadius(scanWindow, Radius.circular(borderRadius)));

    final backgroundPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.50)
      ..style = PaintingStyle.fill;

    final backgroundWithCutout = Path.combine(
      PathOperation.difference,
      backgroundPath,
      cutoutPath,
    );

    canvas.drawPath(backgroundWithCutout, backgroundPaint);

    // Cantoneiras elegantes e suaves
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    const cornerLength = 26.0;
    final r = borderRadius;

    // Canto superior esquerdo
    final tlPath = Path()
      ..moveTo(scanWindow.left, scanWindow.top + cornerLength)
      ..lineTo(scanWindow.left, scanWindow.top + r)
      ..arcToPoint(Offset(scanWindow.left + r, scanWindow.top), radius: Radius.circular(r))
      ..lineTo(scanWindow.left + cornerLength, scanWindow.top);
    canvas.drawPath(tlPath, borderPaint);

    // Canto superior direito
    final trPath = Path()
      ..moveTo(scanWindow.right - cornerLength, scanWindow.top)
      ..lineTo(scanWindow.right - r, scanWindow.top)
      ..arcToPoint(Offset(scanWindow.right, scanWindow.top + r), radius: Radius.circular(r))
      ..lineTo(scanWindow.right, scanWindow.top + cornerLength);
    canvas.drawPath(trPath, borderPaint);

    // Canto inferior esquerdo (clockwise: false para curvar para fora acompanhando o RRect)
    final blPath = Path()
      ..moveTo(scanWindow.left, scanWindow.bottom - cornerLength)
      ..lineTo(scanWindow.left, scanWindow.bottom - r)
      ..arcToPoint(Offset(scanWindow.left + r, scanWindow.bottom),
          radius: Radius.circular(r), clockwise: false)
      ..lineTo(scanWindow.left + cornerLength, scanWindow.bottom);
    canvas.drawPath(blPath, borderPaint);

    // Canto inferior direito (clockwise: false para curvar para fora acompanhando o RRect)
    final brPath = Path()
      ..moveTo(scanWindow.right - cornerLength, scanWindow.bottom)
      ..lineTo(scanWindow.right - r, scanWindow.bottom)
      ..arcToPoint(Offset(scanWindow.right, scanWindow.bottom - r),
          radius: Radius.circular(r), clockwise: false)
      ..lineTo(scanWindow.right, scanWindow.bottom - cornerLength);
    canvas.drawPath(brPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) =>
      oldDelegate.scanWindow != scanWindow || oldDelegate.borderRadius != borderRadius;
}
