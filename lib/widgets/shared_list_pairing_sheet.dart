import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/item_provider.dart';
import '../services/user_sheets_service.dart';

/// BottomSheet para Compartilhamento e Sincronização de Lista via Google Sheets
/// com suporte a Convite Google por E-mail, QR Code Oficial, Link de Acesso e NFC.
class SharedListPairingSheet extends StatefulWidget {
  final String listName;
  final String activeUserEmail;
  final String? initialCodeOrUri;

  const SharedListPairingSheet({
    super.key,
    required this.listName,
    required this.activeUserEmail,
    this.initialCodeOrUri,
  });

  static Future<void> show(
    BuildContext context, {
    required String listName,
    required String activeUserEmail,
    String? initialCodeOrUri,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SharedListPairingSheet(
        listName: listName,
        activeUserEmail: activeUserEmail,
        initialCodeOrUri: initialCodeOrUri,
      ),
    );
  }

  @override
  State<SharedListPairingSheet> createState() => _SharedListPairingSheetState();
}

class _SharedListPairingSheetState extends State<SharedListPairingSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _enterLinkController = TextEditingController();

  String? _spreadsheetId;
  String? _spreadsheetUrl;
  bool _isLoadingSheetInfo = true;
  bool _isSharingEmail = false;
  bool _isMakingPublic = false;
  bool _isConnecting = false;
  bool _isUsingCustomSheet = false;

  bool _isNfcAvailable = false;
  bool _isNfcListening = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);

    if (widget.initialCodeOrUri != null && widget.initialCodeOrUri!.trim().isNotEmpty) {
      _enterLinkController.text = widget.initialCodeOrUri!.trim();
    }

    _loadSpreadsheetData();
    _checkNfcSupport();
  }

  Future<void> _loadSpreadsheetData() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    setState(() => _isLoadingSheetInfo = true);

    try {
      final ssId = await provider.getActiveSpreadsheetId();
      final ssUrl = await provider.getActiveSpreadsheetUrl();
      final isCustom = await provider.isUsingCustomSharedSpreadsheet();

      if (mounted) {
        setState(() {
          _spreadsheetId = ssId;
          _spreadsheetUrl = ssUrl ?? (ssId != null ? 'https://docs.google.com/spreadsheets/d/$ssId/edit' : null);
          _isUsingCustomSheet = isCustom;
          _isLoadingSheetInfo = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingSheetInfo = false);
    }
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

  Future<void> _startNfcBroadcasting() async {
    if (!_isNfcAvailable || _isNfcListening) return;
    setState(() => _isNfcListening = true);

    try {
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        alertMessageIos: 'Aproxime outro aparelho para abrir a lista de compras compartilhada!',
        onDiscovered: (NfcTag tag) async {
          HapticFeedback.heavyImpact();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.nfc_rounded, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text('Aparelho detectado por aproximação!'),
                  ],
                ),
                backgroundColor: Color(0xFF1B5E20),
              ),
            );
          }
        },
      );
    } catch (_) {}
  }

  Future<void> _shareWithGoogleEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, informe um e-mail válido do Google.')),
      );
      return;
    }

    setState(() => _isSharingEmail = true);
    final provider = Provider.of<ItemProvider>(context, listen: false);

    try {
      final success = await provider.shareSpreadsheetWithEmail(email);
      if (mounted) {
        setState(() => _isSharingEmail = false);
        if (success) {
          _emailController.clear();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Planilha compartilhada com sucesso com $email!'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Falha ao compartilhar. Verifique a conexão com o Google Drive.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSharingEmail = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _makePublicByLink() async {
    setState(() => _isMakingPublic = true);
    final provider = Provider.of<ItemProvider>(context, listen: false);

    try {
      final url = await provider.makeSpreadsheetPublicWithLink();
      if (mounted) {
        setState(() {
          _isMakingPublic = false;
          if (url != null) _spreadsheetUrl = url;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Acesso liberado! Qualquer pessoa com o link agora pode visualizar e editar.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isMakingPublic = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao liberar acesso: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _connectToSpreadsheet(String rawInput) async {
    final clean = rawInput.trim();
    if (clean.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cole o link da planilha ou digite o código/ID.')),
      );
      return;
    }

    setState(() => _isConnecting = true);
    final provider = Provider.of<ItemProvider>(context, listen: false);

    try {
      final parsedId = UserSheetsService.extractSpreadsheetId(clean);
      await provider.connectToSharedSpreadsheet(parsedId);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('paired_device_${widget.listName}', 'Planilha Compartilhada ($parsedId)');

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _isUsingCustomSheet = true;
          _spreadsheetId = parsedId;
          _spreadsheetUrl = 'https://docs.google.com/spreadsheets/d/$parsedId/edit';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Conectado à Planilha Compartilhada com sucesso! Itens atualizados.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao conectar: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _disconnectAndRestore() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    setState(() => _isConnecting = true);

    try {
      await provider.restoreDefaultSpreadsheet();
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('paired_device_${widget.listName}');

      if (mounted) {
        await _loadSpreadsheetData();
      }
      if (mounted) {
        setState(() {
          _isConnecting = false;
          _isUsingCustomSheet = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Desconectado! Retornou para a sua planilha pessoal padrão.'),
            backgroundColor: Colors.blueGrey,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isConnecting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao restaurar: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  void _openQrScanner() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Escanear QR da Planilha Google')),
          body: MobileScanner(
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final code = barcode.rawValue?.trim() ?? barcode.displayValue?.trim();
                if (code != null && code.isNotEmpty) {
                  Navigator.pop(context);
                  _enterLinkController.text = code;
                  _connectToSpreadsheet(code);
                  break;
                }
              }
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emailController.dispose();
    _enterLinkController.dispose();
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

    final displayUrl = _spreadsheetUrl ?? (_spreadsheetId != null ? 'https://docs.google.com/spreadsheets/d/$_spreadsheetId/edit' : null);

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
              color: Colors.grey.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 14),

          // Cabeçalho
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.table_chart_rounded, color: Colors.green, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Lista Compartilhada (Google Sheets)',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    Text(
                      'Sincronização em tempo real na nuvem do Google',
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
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

          // Banner de Status se já estiver em planilha compartilhada
          if (_isUsingCustomSheet) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link_rounded, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Conectado à Planilha Compartilhada',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: _isConnecting ? null : _disconnectAndRestore,
                    child: const Text('Voltar à Minha', style: TextStyle(fontSize: 12, color: Colors.deepOrange)),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Abas Modernas
          Container(
            decoration: BoxDecoration(
              color: isDark ? Colors.grey[900] : Colors.grey[200],
              borderRadius: BorderRadius.circular(16),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: primary,
                borderRadius: BorderRadius.circular(16),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              labelColor: Colors.white,
              unselectedLabelColor: isDark ? Colors.grey[400] : Colors.grey[700],
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(icon: Icon(Icons.mail_outline_rounded, size: 20), text: 'E-mail Google'),
                Tab(icon: Icon(Icons.qr_code_2_rounded, size: 20), text: 'QR / Link'),
                Tab(icon: Icon(Icons.nfc_rounded, size: 20), text: 'NFC'),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Conteúdo das Abas
          SizedBox(
            height: 250,
            child: _isLoadingSheetInfo
                ? const Center(child: CircularProgressIndicator())
                : TabBarView(
                    controller: _tabController,
                    children: [
                      // Aba 1: E-mail Google (Google Drive Permissions)
                      _buildEmailShareTab(theme),

                      // Aba 2: QR Code e Link da Planilha
                      _buildQrAndLinkTab(displayUrl),

                      // Aba 3: NFC
                      _buildNfcTab(),
                    ],
                  ),
          ),

          const SizedBox(height: 12),
          const Divider(),
          const SizedBox(height: 6),

          // Conectar à Planilha de Outra Pessoa
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Entrar na Planilha de Outra Pessoa:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              TextButton.icon(
                onPressed: _openQrScanner,
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                label: const Text('Ler QR Code', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _enterLinkController,
                  decoration: InputDecoration(
                    hintText: 'Cole o link do Google Sheets ou ID',
                    hintStyle: const TextStyle(fontSize: 12),
                    isDense: true,
                    prefixIcon: const Icon(Icons.link_rounded, size: 18),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _isConnecting
                    ? null
                    : () => _connectToSpreadsheet(_enterLinkController.text),
                child: _isConnecting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Conectar'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmailShareTab(ThemeData theme) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          const Text(
            'Convide diretamente a conta Google (Gmail) da outra pessoa:',
            style: TextStyle(fontSize: 13, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: InputDecoration(
              labelText: 'E-mail Google da outra pessoa',
              hintText: 'exemplo@gmail.com',
              prefixIcon: const Icon(Icons.alternate_email_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              filled: true,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green[700],
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onPressed: _isSharingEmail ? null : _shareWithGoogleEmail,
              icon: _isSharingEmail
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, size: 18),
              label: Text(_isSharingEmail ? 'Enviando convite...' : 'Conceder Acesso de Editor'),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'O Google Drive dará permissão de edição para esta conta instantaneamente.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildQrAndLinkTab(String? displayUrl) {
    if (displayUrl == null) {
      return const Center(child: Text('Nenhuma planilha configurada.'));
    }

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 6),
                  ],
                ),
                child: QrImageView(
                  data: displayUrl,
                  version: QrVersions.auto,
                  size: 135.0,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'QR Code Oficial',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'No iPhone 15 Pro Max, aponte a câmera para abrir no Google Planilhas ou CARRIN Web.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: displayUrl));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Link do Google Sheets copiado!')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Copiar Link', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _isMakingPublic ? null : _makePublicByLink,
              icon: _isMakingPublic
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.public_rounded, size: 16),
              label: const Text('Liberar Acesso de Edição para quem tiver o link', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNfcTab() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _isNfcAvailable ? Colors.blue.withValues(alpha: 0.15) : Colors.grey.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.nfc_rounded,
              size: 48,
              color: _isNfcAvailable ? Colors.blue : Colors.grey,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _isNfcAvailable ? 'Aproxime as traseiras dos aparelhos' : 'NFC não disponível neste dispositivo',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              _isNfcAvailable
                  ? 'O link da Planilha Google será transmitido para o outro celular abrir ou conectar instantaneamente.'
                  : 'Utilize o QR Code ou convite por E-mail Google na aba ao lado.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
