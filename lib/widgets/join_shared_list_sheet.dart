import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:vibration/vibration.dart';
import '../providers/item_provider.dart';
import '../services/shared_list_service.dart';
import '../screens/shopping_list_screen.dart';

/// Modal bottom sheet para entrar na lista compartilhada de outra pessoa
/// diretamente via QR Code com a câmera ou colando o link/código.
class JoinSharedListSheet extends StatefulWidget {
  const JoinSharedListSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const JoinSharedListSheet(),
    );
  }

  @override
  State<JoinSharedListSheet> createState() => _JoinSharedListSheetState();
}

class _JoinSharedListSheetState extends State<JoinSharedListSheet> {
  final TextEditingController _linkController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _processPayload(SharedListPayload payload, ItemProvider provider) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await provider.importAndOpenSharedList(payload);

      try {
        if ((await Vibration.hasVibrator()) == true) {
          Vibration.vibrate(duration: 80);
        } else {
          HapticFeedback.heavyImpact();
        }
      } catch (_) {}

      if (mounted) {
        Navigator.pop(context); // fecha a sheet

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            content: Row(
              children: [
                const Icon(Icons.check_circle_outline, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '🎉 Lista "${payload.title}" conectada com sucesso!',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 3),
          ),
        );

        // Abre a tela de compras diretamente na lista importada
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ShoppingListScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Erro ao carregar a lista: $e';
        });
      }
    }
  }

  void _openQrCameraScanner(BuildContext context) {
    final provider = Provider.of<ItemProvider>(context, listen: false);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (scannerCtx) => _QrCameraScannerView(
          onCodeScanned: (scannedCode) async {
            Navigator.pop(scannerCtx); // fecha scanner de câmera

            final payload = SharedListService.instance.decodeList(scannedCode);
            if (payload != null) {
              await _processPayload(payload, provider);
            } else {
              if (mounted) {
                setState(() {
                  _errorMessage = 'O QR Code lido não é uma lista válida do CARRIN.';
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Código inválido ou lista não reconhecida.'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> _handlePasteAndLoad() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    final text = _linkController.text.trim();

    if (text.isEmpty) {
      setState(() {
        _errorMessage = 'Cole o link ou código da lista compartilhada.';
      });
      return;
    }

    final payload = SharedListService.instance.decodeList(text);
    if (payload != null) {
      await _processPayload(payload, provider);
    } else {
      setState(() {
        _errorMessage = 'Link ou código não reconhecido. Peça para o outro usuário gerar o QR Code no CARRIN.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : theme.cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Indicador de arrasto superior
            Center(
              child: Container(
                width: 44,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Título e Ícone
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.qr_code_scanner_rounded,
                    color: Color(0xFF10B981),
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Entrar na Lista de Outra Pessoa',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Acesse a lista em tempo real sem precisar criar uma lista vazia',
                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // BOTÃO PRINCIPAL: ESCANEAR QR CODE COM A CÂMERA
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981),
                foregroundColor: Colors.white,
                elevation: 3,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _isLoading ? null : () => _openQrCameraScanner(context),
              icon: const Icon(Icons.camera_alt_rounded, size: 24),
              label: const Text(
                'Escanear QR Code com a Câmera',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
            ),

            const SizedBox(height: 20),

            // Divisor "OU COLE O LINK"
            Row(
              children: [
                Expanded(child: Divider(color: Colors.grey.withValues(alpha: 0.25))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'OU COLE O LINK RECEBIDO',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                      color: Colors.grey[500],
                    ),
                  ),
                ),
                Expanded(child: Divider(color: Colors.grey.withValues(alpha: 0.25))),
              ],
            ),

            const SizedBox(height: 16),

            // Campo para colar link
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _linkController,
                    decoration: InputDecoration(
                      hintText: 'Cole o link compartilhado (carrin://share...)',
                      hintStyle: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      filled: true,
                      fillColor: isDark ? const Color(0xFF0F172A) : Colors.grey[100],
                      prefixIcon: const Icon(Icons.link_rounded, size: 20),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste_rounded, size: 20),
                        tooltip: 'Colar da área de transferência',
                        onPressed: () async {
                          final data = await Clipboard.getData(Clipboard.kTextPlain);
                          if (data?.text != null && data!.text!.isNotEmpty) {
                            _linkController.text = data.text!;
                            setState(() => _errorMessage = null);
                          }
                        },
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _isLoading ? null : _handlePasteAndLoad,
                  child: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Entrar', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Tela de Scanner de Câmera moderna com MobileScanner dedicada a listas do CARRIN
class _QrCameraScannerView extends StatefulWidget {
  final ValueChanged<String> onCodeScanned;

  const _QrCameraScannerView({required this.onCodeScanned});

  @override
  State<_QrCameraScannerView> createState() => _QrCameraScannerViewState();
}

class _QrCameraScannerViewState extends State<_QrCameraScannerView> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );
  bool _hasDetected = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Escanear QR Code da Lista', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: ValueListenableBuilder<MobileScannerState>(
              valueListenable: _controller,
              builder: (ctx, state, _) {
                final isOn = state.torchState == TorchState.on;
                return Icon(
                  isOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                  color: isOn ? Colors.amberAccent : Colors.white,
                );
              },
            ),
            tooltip: 'Lanterna',
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_android_rounded),
            tooltip: 'Trocar Câmera',
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: (capture) {
              if (_hasDetected) return;
              for (final barcode in capture.barcodes) {
                final code = barcode.rawValue?.trim() ?? barcode.displayValue?.trim();
                if (code != null && code.isNotEmpty) {
                  _hasDetected = true;
                  widget.onCodeScanned(code);
                  break;
                }
              }
            },
          ),

          // Moldura visual do leitor de QR
          Container(
            width: 250,
            height: 250,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF10B981), width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),

          // Instrução na parte inferior
          Positioned(
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Aponte a câmera para o QR Code do CARRIN',
                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
