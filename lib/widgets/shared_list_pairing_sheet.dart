import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/item_provider.dart';
import '../services/user_sheets_service.dart';

/// BottomSheet para Compartilhamento e Sincronização Direta de Lista via Google Sheets
/// com QR Code com Permissão de Edição Pública automática, Link Copiável e NFC.
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

class _SharedListPairingSheetState extends State<SharedListPairingSheet> {
  final TextEditingController _enterLinkController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();

  String? _spreadsheetId;
  String? _spreadsheetUrl;
  bool _isLoadingSheetInfo = true;
  bool _isConnecting = false;
  bool _isUsingCustomSheet = false;
  bool _isSharingEmail = false;

  bool _isNfcAvailable = false;
  bool _isNfcListening = false;

  @override
  void initState() {
    super.initState();

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
          _spreadsheetUrl = ssUrl;
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
        alertMessageIos: 'Aproxime outro aparelho para abrir a lista compartilhada no Google Sheets!',
        onDiscovered: (NfcTag tag) async {
          HapticFeedback.heavyImpact();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Row(
                  children: [
                    Icon(Icons.nfc_rounded, color: Colors.greenAccent),
                    SizedBox(width: 8),
                    Text('Aparelho detectado via NFC!'),
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

  Future<void> _connectToSpreadsheet(String rawInput) async {
    final clean = rawInput.trim();
    if (clean.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cole o link do Google Sheets ou ID da planilha.')),
      );
      return;
    }

    setState(() => _isConnecting = true);
    final provider = Provider.of<ItemProvider>(context, listen: false);

    try {
      final parsedId = UserSheetsService.extractSpreadsheetId(clean);
      await provider.connectToSharedSpreadsheet(parsedId);

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _isUsingCustomSheet = true;
          _spreadsheetId = parsedId;
          _spreadsheetUrl = 'https://docs.google.com/spreadsheets/d/$parsedId/edit';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Conectado à Planilha Compartilhada com sucesso!'),
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
            content: Text('Retornou para a sua planilha pessoal padrão.'),
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

  Future<void> _shareWithGoogleEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe um e-mail válido do Google.')),
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
              content: Text('Convite oficial do Google enviado para $email!'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Falha ao enviar convite por e-mail.'),
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

  void _openQrScanner() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Escanear QR da Planilha')),
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
    _enterLinkController.dispose();
    _emailController.dispose();
    try {
      NfcManager.instance.stopSession();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      child: SingleChildScrollView(
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
                  child: const Icon(Icons.qr_code_2_rounded, color: Colors.green, size: 24),
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
                        'Editável por todos via QR Code e Link',
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

            // Banner se já estiver em planilha compartilhada
            if (_isUsingCustomSheet) ...[
              const SizedBox(height: 10),
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

            const SizedBox(height: 14),

            // Card Principal: QR Code com Edição Liberada Automática
            _isLoadingSheetInfo
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : displayUrl == null
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 30),
                        child: Text('Nenhuma planilha configurada no momento.'),
                      )
                    : Column(
                        children: [
                          // Badge de Acesso Liberado
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                            decoration: BoxDecoration(
                              color: Colors.green.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle_rounded, color: Colors.green, size: 16),
                                SizedBox(width: 6),
                                Text(
                                  'Acesso de Edição Liberado para Todos',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.green),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),

                          // QR Code Gigante
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.12),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: QrImageView(
                              data: displayUrl,
                              version: QrVersions.auto,
                              size: 190.0,
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Instrução para iPhone / Android
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'Aponte a câmera do celular (iPhone ou Android) para abrir e editar a lista em tempo real no Google Planilhas ou CARRIN Web.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12.5, color: Colors.grey, height: 1.3),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Botões de Ação Rápida
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              FilledButton.icon(
                                style: FilledButton.styleFrom(
                                  backgroundColor: Colors.green[700],
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: displayUrl));
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Link do Google Sheets copiado com sucesso!'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.copy_rounded, size: 18),
                                label: const Text('Copiar Link', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                                onPressed: () async {
                                  final uri = Uri.parse(displayUrl);
                                  if (await canLaunchUrl(uri)) {
                                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                                  }
                                },
                                icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                                label: const Text('Abrir Planilha'),
                              ),
                            ],
                          ),
                        ],
                      ),

            const SizedBox(height: 16),
            const Divider(),

            // Seção: Conectar à Planilha de Outra Pessoa
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

            const SizedBox(height: 12),

            // Opção alternativa: Enviar convite por E-mail Google (oculto por padrão para manter a tela limpa)
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: const Row(
                  children: [
                    Icon(Icons.mail_outline_rounded, size: 16, color: Colors.blue),
                    SizedBox(width: 8),
                    Text(
                      'Também quer enviar convite oficial por E-mail Google?',
                      style: TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              hintText: 'exemplo@gmail.com',
                              hintStyle: const TextStyle(fontSize: 12),
                              isDense: true,
                              prefixIcon: const Icon(Icons.alternate_email_rounded, size: 16),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Colors.blue[700]),
                          onPressed: _isSharingEmail ? null : _shareWithGoogleEmail,
                          child: _isSharingEmail
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('Enviar'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
