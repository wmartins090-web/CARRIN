import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';

class BarcodeScannerScreen extends StatefulWidget {
  final String title;
  const BarcodeScannerScreen({super.key, this.title = 'Escanear Produto'});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen>
    with SingleTickerProviderStateMixin {
  late final MobileScannerController controller;
  late final AnimationController _animController;
  late final Animation<double> _animation;
  bool _found = false;

  @override
  void initState() {
    super.initState();
    controller = MobileScannerController(
      autoStart: true,
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
      formats: const [
        BarcodeFormat.all,
      ],
    );

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0.08, end: 0.92).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _animController.dispose();
    controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_found) return;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim() ?? barcode.displayValue?.trim();
      if (code != null && code.isNotEmpty) {
        setState(() => _found = true);
        try {
          Vibration.vibrate(duration: 80);
        } catch (_) {}
        if (mounted) {
          Navigator.pop(context, code);
        }
        return;
      }
    }
  }

  void _showManualInputDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.keyboard_outlined, color: Colors.blue),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(
          widget.title,
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 17),
        ),
        backgroundColor: Colors.black.withValues(alpha: 0.6),
        elevation: 0,
        leading: const CloseButton(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Receber por NFC (Aproximação)',
            icon: const Icon(Icons.nfc_rounded, color: Colors.lightBlueAccent),
            onPressed: () => Navigator.pop(context, '__ACTION_OPEN_NFC__'),
          ),
          IconButton(
            tooltip: 'Alternar Lanterna',
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: controller,
              builder: (context, state, child) {
                switch (state.torchState) {
                  case TorchState.off:
                    return const Icon(Icons.flash_off_rounded, color: Colors.white70);
                  case TorchState.on:
                    return const Icon(Icons.flash_on_rounded, color: Colors.amberAccent);
                  case TorchState.unavailable:
                    return const Icon(Icons.flash_off_rounded, color: Colors.white30);
                  case TorchState.auto:
                    return const Icon(Icons.flash_auto_rounded, color: Colors.white);
                }
              },
            ),
            onPressed: () => controller.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Alternar Câmera',
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: controller,
              builder: (context, state, child) {
                switch (state.cameraDirection) {
                  case CameraFacing.front:
                    return const Icon(Icons.camera_front_rounded, color: Colors.white);
                  case CameraFacing.back:
                    return const Icon(Icons.camera_rear_rounded, color: Colors.white);
                }
              },
            ),
            onPressed: () => controller.switchCamera(),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final boxWidth = (constraints.maxWidth * 0.78).clamp(240.0, 310.0);
          final boxHeight = boxWidth * 0.68;
          final scanWindow = Rect.fromCenter(
            center: Offset(constraints.maxWidth / 2, constraints.maxHeight * 0.44),
            width: boxWidth,
            height: boxHeight,
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              // Leitor de Câmera Universal
              MobileScanner(
                controller: controller,
                scanWindow: scanWindow,
                onDetect: _onDetect,
              ),

              // Overlay limpo com corte central e cantoneiras elegantes
              CustomPaint(
                painter: _ScannerOverlayPainter(
                  scanWindow: scanWindow,
                  borderRadius: 18,
                ),
              ),

              // Linha Laser Animada de Leitura
              AnimatedBuilder(
                animation: _animation,
                builder: (context, child) {
                  return Positioned(
                    top: scanWindow.top + (scanWindow.height * _animation.value),
                    left: scanWindow.left + 14,
                    width: scanWindow.width - 28,
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.greenAccent.withValues(alpha: 0.0),
                            Colors.greenAccent,
                            Colors.white,
                            Colors.greenAccent,
                            Colors.greenAccent.withValues(alpha: 0.0),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.greenAccent.withValues(alpha: 0.6),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

              // Instrução minimalista e limpa
              Positioned(
                top: scanWindow.bottom + 20,
                left: 20,
                right: 20,
                child: const Text(
                  'Aponte para o código de barras ou QR Code',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.2,
                  ),
                ),
              ),

              // Botões inferiores limpos
              Positioned(
                bottom: 34,
                left: 20,
                right: 20,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.18),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      ),
                      onPressed: _showManualInputDialog,
                      icon: const Icon(Icons.keyboard_outlined, size: 18),
                      label: const Text(
                        'Digitar código',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 12),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.18),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      ),
                      onPressed: () => Navigator.pop(context, '__ACTION_OPEN_NFC__'),
                      icon: const Icon(Icons.nfc_rounded, size: 18, color: Colors.lightBlueAccent),
                      label: const Text(
                        'NFC',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
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

  _ScannerOverlayPainter({required this.scanWindow, this.borderRadius = 18});

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutoutPath = Path()
      ..addRRect(RRect.fromRectAndRadius(scanWindow, Radius.circular(borderRadius)));

    final backgroundPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.55)
      ..style = PaintingStyle.fill;

    final backgroundWithCutout = Path.combine(
      PathOperation.difference,
      backgroundPath,
      cutoutPath,
    );

    canvas.drawPath(backgroundWithCutout, backgroundPaint);

    // Cantoneiras refinadas e perfeitamente alinhadas ao raio
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    const cornerLength = 24.0;
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

    // Canto inferior esquerdo
    final blPath = Path()
      ..moveTo(scanWindow.left, scanWindow.bottom - cornerLength)
      ..lineTo(scanWindow.left, scanWindow.bottom - r)
      ..arcToPoint(Offset(scanWindow.left + r, scanWindow.bottom), radius: Radius.circular(r))
      ..lineTo(scanWindow.left + cornerLength, scanWindow.bottom);
    canvas.drawPath(blPath, borderPaint);

    // Canto inferior direito
    final brPath = Path()
      ..moveTo(scanWindow.right - cornerLength, scanWindow.bottom)
      ..lineTo(scanWindow.right - r, scanWindow.bottom)
      ..arcToPoint(Offset(scanWindow.right, scanWindow.bottom - r), radius: Radius.circular(r))
      ..lineTo(scanWindow.right, scanWindow.bottom - cornerLength);
    canvas.drawPath(brPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) =>
      oldDelegate.scanWindow != scanWindow || oldDelegate.borderRadius != borderRadius;
}
