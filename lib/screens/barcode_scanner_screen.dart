import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:vibration/vibration.dart';

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

  void _onDetect(BarcodeCapture capture) {
    if (_found) return;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue?.trim() ?? barcode.displayValue?.trim();
      if (code != null && code.isNotEmpty) {
        setState(() => _found = true);
        try {
          Vibration.vibrate(duration: 70);
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
                      'Aponte para o código de barras ou QR Code',
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
                bottom: 40,
                left: 24,
                right: 24,
                child: Center(
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    children: [
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.16),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                        ),
                        onPressed: _showManualInputDialog,
                        icon: const Icon(Icons.keyboard_outlined, size: 18),
                        label: const Text(
                          'Digitar código',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.16),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
