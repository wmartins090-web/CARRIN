import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BottomSheet moderno para Pareamento e Compartilhamento de Lista
/// com suporte a Aproximação NFC, QR Code e Código de 6 dígitos.
class SharedListPairingSheet extends StatefulWidget {
  final String listName;
  final String activeUserEmail;

  const SharedListPairingSheet({
    super.key,
    required this.listName,
    required this.activeUserEmail,
  });

  static Future<void> show(BuildContext context, {required String listName, required String activeUserEmail}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SharedListPairingSheet(
        listName: listName,
        activeUserEmail: activeUserEmail,
      ),
    );
  }

  @override
  State<SharedListPairingSheet> createState() => _SharedListPairingSheetState();
}

class _SharedListPairingSheetState extends State<SharedListPairingSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late String _pairingCode;
  late String _shareUrl;

  bool _isNfcAvailable = false;
  bool _isNfcListening = false;
  String? _pairedDeviceName;
  final TextEditingController _enterCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    _generatePairingCode();
    _checkNfcSupport();
    _loadPairedDevice();
  }

  void _generatePairingCode() {
    final hash = (widget.listName + widget.activeUserEmail).hashCode.abs();
    final numPart = (hash % 9000 + 1000).toString();
    _pairingCode = 'CAR-$numPart';
    _shareUrl = 'https://wmartins090-web.github.io/CARRIN/#/colab?list=${Uri.encodeComponent(widget.listName)}&code=$_pairingCode';
  }

  Future<void> _checkNfcSupport() async {
    try {
      final availability = await NfcManager.instance.checkAvailability();
      if (mounted) {
        final isAvail = availability == NfcAvailability.enabled;
        setState(() => _isNfcAvailable = isAvail);
        if (isAvail) {
          _startNfcBroadcasting();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _isNfcAvailable = false);
    }
  }

  Future<void> _loadPairedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final paired = prefs.getString('paired_device_${widget.listName}');
    if (mounted && paired != null) {
      setState(() => _pairedDeviceName = paired);
    }
  }

  Future<void> _startNfcBroadcasting() async {
    if (!_isNfcAvailable || _isNfcListening) return;
    setState(() => _isNfcListening = true);

    try {
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        alertMessageIos: 'Aproxime o iPhone para sincronizar a lista de compras!',
        onDiscovered: (NfcTag tag) async {
          HapticFeedback.heavyImpact();
          await _savePairedDevice('Dispositivo Pareado por NFC');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.nfc_rounded, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text('Aparelho conectado via NFC com sucesso!'),
                  ],
                ),
                backgroundColor: Color(0xFF1B5E20),
              ),
            );
          }
        },
      );
    } catch (_) {
      // Ignora erro silenciosamente se a sessão for cancelada
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _enterCodeController.dispose();
    try {
      NfcManager.instance.stopSession();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.primaryColor;
    final cardColor = theme.cardColor;

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      padding: EdgeInsets.only(
        top: 14,
        left: 18,
        right: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Puxador central
          Container(
            width: 44,
            height: 4.5,
            decoration: BoxDecoration(
              color: isDark ? Colors.white24 : Colors.grey.shade300,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 14),

          // Cabeçalho com Ícone e Título
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.phonelink_ring_rounded, color: primary, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Lista Compartilhada (NFC / QR)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    Text(
                      'Lista: ${widget.listName}',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white70 : Colors.black54,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),

          if (_pairedDeviceName != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Colors.green, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Conectado com: $_pairedDeviceName',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.green),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Abas: NFC, QR Code e Código
          TabBar(
            controller: _tabController,
            indicatorColor: primary,
            labelColor: primary,
            unselectedLabelColor: isDark ? Colors.white54 : Colors.grey.shade600,
            labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
            tabs: const [
              Tab(icon: Icon(Icons.nfc_rounded, size: 20), text: 'NFC'),
              Tab(icon: Icon(Icons.qr_code_rounded, size: 20), text: 'QR Code'),
              Tab(icon: Icon(Icons.pin_rounded, size: 20), text: 'Código'),
            ],
          ),

          const SizedBox(height: 16),

          SizedBox(
            height: 330,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildNfcTab(isDark, primary),
                _buildQrTab(isDark, primary),
                _buildCodeTab(isDark, primary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 1. ABA NFC
  Widget _buildNfcTab(bool isDark, Color primary) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primary.withValues(alpha: 0.08),
              ),
            ),
            Container(
              width: 105,
              height: 105,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primary.withValues(alpha: 0.14),
              ),
            ),
            Icon(Icons.nfc_rounded, size: 52, color: primary),
          ],
        ),
        const SizedBox(height: 18),
        const Text(
          'Encoste as Traseiras dos Aparelhos',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            _isNfcAvailable
                ? 'Aproxime a traseira do iPhone 15 Pro Max ou outro celular com NFC para transferir e conectar a lista instantaneamente.'
                : 'NFC em espera ou não suportado neste aparelho. Utilize a aba QR Code ao lado!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: isDark ? Colors.white70 : Colors.black54,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  // 2. ABA QR CODE
  Widget _buildQrTab(bool isDark, Color primary) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: QrImageView(
            data: _shareUrl,
            version: QrVersions.auto,
            size: 170,
            gapless: false,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Aponte a Câmera do Outro Aparelho',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5),
        ),
        const SizedBox(height: 4),
        Text(
          'No iPhone ou Android, basta abrir a câmera normal.',
          style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Colors.black54),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _openQrScanner(context),
          icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
          label: const Text('Escanear QR de Outro Aparelho', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }

  // 3. ABA CÓDIGO
  Widget _buildCodeTab(bool isDark, Color primary) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      child: Column(
        children: [
          const SizedBox(height: 8),
          const Text('Seu Código de Pareamento:', style: TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: _pairingCode));
              HapticFeedback.lightImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Código copiado para a área de transferência!')),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: primary.withValues(alpha: 0.4), width: 1.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _pairingCode,
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 3,
                      color: primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(Icons.copy_rounded, size: 18, color: primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 10),
          const Text('Ou entre com o código de outra pessoa:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _enterCodeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'Ex: CAR-1234',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final code = _enterCodeController.text.trim();
                  if (code.isNotEmpty) {
                    _savePairedDevice('Dispositivo ($code)');
                  }
                },
                child: const Text('Conectar'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _openQrScanner(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Escanear QR de Conexão')),
          body: MobileScanner(
            onDetect: (capture) {
              final barcodes = capture.barcodes;
              for (final barcode in barcodes) {
                if (barcode.rawValue != null) {
                  final raw = barcode.rawValue!;
                  Navigator.pop(context);
                  _savePairedDevice('Dispositivo ($raw)');
                  break;
                }
              }
            },
          ),
        ),
      ),
    );
  }

  Future<void> _savePairedDevice(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('paired_device_${widget.listName}', name);
    if (mounted) {
      setState(() => _pairedDeviceName = name);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Vinculado com sucesso: $name'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
