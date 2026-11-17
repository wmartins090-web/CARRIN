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
        final parsed = ShelfTagParser.parse(recognized.text, requirePriceContext: true);
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

  void _showManualInputDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.keyboard_outlined, color: Colors.blueAccent),
            SizedBox(width: 10),
            Text('Digitar Código', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Digite os números do código de barras ou a chave do produto:',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: textController,
              autofocus: true,
              keyboardType: TextInputType.text,
              decoration: InputDecoration(
                hintText: 'Ex: 7891000100103',
                prefixIcon: const Icon(Icons.qr_code_2_rounded),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              final val = textController.text.trim();
              if (val.isNotEmpty) {
                Navigator.pop(dialogCtx);
                if (mounted) {
                  Navigator.pop(context, val);
                }
              }
            },
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
  }

  Future<void> _scanShelfTag() async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 92,
      );
      if (image == null) return;

      if (!mounted) return;
      setState(() {
        _isAnalyzingFrame = true;
        _processingLabel = 'Analisando etiqueta de gôndola...';
      });

      final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      String ocrText = '';
      BarcodeCapture? barcodeCapture;
      try {
        final results = await Future.wait<dynamic>([
          recognizer.processImage(InputImage.fromFilePath(image.path)),
          controller.analyzeImage(image.path).catchError((_) => null),
        ]);
        final recognizedText = results[0] as RecognizedText;
        ocrText = recognizedText.text;
        barcodeCapture = results[1] as BarcodeCapture?;
      } finally {
        await recognizer.close();
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

      final parsed = ShelfTagParser.parse(ocrText);
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

              // Instrução central elegante
              Positioned(
                top: scanRect.bottom + 24,
                left: 20,
                right: 20,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Aponte para o código da gôndola, produto ou cupom',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),

              // Botões inferiores limpos
              Positioned(
                bottom: 36,
                left: 16,
                right: 16,
                child: Center(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.16),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                          ),
                          onPressed: _showManualInputDialog,
                          icon: const Icon(Icons.keyboard_outlined, size: 18),
                          label: const Text(
                            'Digitar código',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.tealAccent.withValues(alpha: 0.20),
                            foregroundColor: Colors.tealAccent.shade100,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: BorderSide(color: Colors.tealAccent.withValues(alpha: 0.35)),
                            ),
                          ),
                          onPressed: () => Navigator.pop(context, '__ACTION_OPEN_RECEIPT__'),
                          icon: const Icon(Icons.receipt_long_rounded, size: 18, color: Colors.tealAccent),
                          label: const Text(
                            'Cupom Fiscal',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            backgroundColor: const Color(0xFF10B981).withValues(alpha: 0.22),
                            foregroundColor: const Color(0xFF6EE7B7),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: const BorderSide(color: Color(0xFF10B981), width: 1.2),
                            ),
                          ),
                          onPressed: _scanShelfTag,
                          icon: const Icon(Icons.sell_outlined, size: 18, color: Color(0xFF6EE7B7)),
                          label: const Text(
                            'Etiqueta Gôndola',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.16),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                          ),
                          onPressed: () => Navigator.pop(context, '__ACTION_OPEN_NFC__'),
                          icon: const Icon(Icons.nfc_rounded, size: 18, color: Colors.lightBlueAccent),
                          label: const Text(
                            'NFC',
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_isAnalyzingFrame)
                Container(
                  color: Colors.black.withValues(alpha: 0.55),
                  child: Center(
                    child: Container(
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
                          Text(
                            _processingLabel ?? 'Analisando etiqueta...',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
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
