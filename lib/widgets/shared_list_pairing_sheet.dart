import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart' as android_nfc;
import 'package:nfc_manager/nfc_manager_ios.dart' as ios_nfc;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../screens/barcode_scanner_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/item_provider.dart';
import '../services/user_sheets_service.dart';
import '../services/shared_list_service.dart';
import 'package:vibration/vibration.dart';

/// BottomSheet para Compartilhamento e Sincronização de Lista
/// com suporte completo a NFC (Aproximação Ativa), QR Code e Google Sheets.
class SharedListPairingSheet extends StatefulWidget {
  final String listName;
  final String activeUserEmail;
  final String? initialCodeOrUri;
  final bool defaultTransmit;

  const SharedListPairingSheet({
    super.key,
    required this.listName,
    required this.activeUserEmail,
    this.initialCodeOrUri,
    this.defaultTransmit = false,
  });

  static Future<void> show(
    BuildContext context, {
    required String listName,
    required String activeUserEmail,
    String? initialCodeOrUri,
    bool defaultTransmit = false,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SharedListPairingSheet(
        listName: listName,
        activeUserEmail: activeUserEmail,
        initialCodeOrUri: initialCodeOrUri,
        defaultTransmit: defaultTransmit,
      ),
    );
  }

  @override
  State<SharedListPairingSheet> createState() => _SharedListPairingSheetState();
}

class _SharedListPairingSheetState extends State<SharedListPairingSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _enterLinkController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();

  String? _spreadsheetId;
  String? _spreadsheetUrl;
  late String _carrinPayloadUri;
  late String _selectedList;
  bool _isConnecting = false;
  bool _isUsingCustomSheet = false;
  bool _isSharingEmail = false;

  // Modo do QR Code: true = Para o app CARRIN (dados completos), false = Para iPhone / Web (Google Sheets)
  bool _qrForCarrinApp = true;

  bool _isNfcAvailable = false;
  bool _isNfcActive = false;
  bool _isTransmitMode = false;
  String _nfcStatusText = 'Modo Inteligente: Aguardando lista via NFC...';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _isTransmitMode = widget.defaultTransmit;

    final provider = Provider.of<ItemProvider>(context, listen: false);
    _selectedList = widget.listName;
    _carrinPayloadUri = SharedListService.instance.encodeList(provider, targetMonth: _selectedList);
    _updatePayloadForSelectedList();

    if (widget.initialCodeOrUri != null && widget.initialCodeOrUri!.trim().isNotEmpty) {
      _enterLinkController.text = widget.initialCodeOrUri!.trim();
    }

    _loadSpreadsheetData();
    _checkNfcSupport();
  }

  Future<void> _updatePayloadForSelectedList() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    final items = await provider.getItemsForMonth(_selectedList);
    final budget = (_selectedList == provider.currentMonth) ? provider.budget : 0.0;

    String? dedicatedSsId = await provider.getDedicatedSpreadsheetIdForList(_selectedList);
    if (dedicatedSsId == null && provider.isSyncEnabled) {
      dedicatedSsId = await provider.getOrCreateDedicatedSpreadsheetForList(_selectedList);
    }

    // Obtém ou cria syncId para sincronização ponto-a-ponto instantânea
    final syncId = await provider.getOrCreateSyncIdForMonth(_selectedList);
    await provider.startSyncListeningForMonth(_selectedList);

    if (mounted) {
      setState(() {
        _spreadsheetId = dedicatedSsId;
        if (dedicatedSsId != null && dedicatedSsId.isNotEmpty) {
          _spreadsheetUrl = 'https://docs.google.com/spreadsheets/d/$dedicatedSsId/edit';
        }
        _carrinPayloadUri = SharedListService.instance.encodeSingleList(
          title: _selectedList,
          budget: budget,
          items: items,
          spreadsheetId: dedicatedSsId,
          syncId: syncId,
        );
      });
    }
  }

  Future<void> _loadSpreadsheetData() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);

    try {
      final ssId = await provider.getActiveSpreadsheetId();
      final ssUrl = await provider.getActiveSpreadsheetUrl();
      final isCustom = await provider.isUsingCustomSharedSpreadsheet();

      if (mounted) {
        setState(() {
          _spreadsheetId = ssId;
          _spreadsheetUrl = ssUrl;
          _isUsingCustomSheet = isCustom;
        });
      }
    } catch (_) {}
  }

  Future<void> _checkNfcSupport() async {
    try {
      final availability = await NfcManager.instance.checkAvailability();
      if (mounted) {
        final isAvail = availability == NfcAvailability.enabled;
        setState(() {
          _isNfcAvailable = isAvail;
          if (isAvail) {
            _startNfcSession(isTransmitMode: _isTransmitMode);
          } else {
            _nfcStatusText = 'NFC desativado ou não suportado neste aparelho';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isNfcAvailable = false;
          _nfcStatusText = 'NFC não suportado neste dispositivo';
        });
      }
    }
  }

  String? _extractTextFromNdefMessage(NdefMessage message) {
    for (final record in message.records) {
      try {
        if (record.typeNameFormat == TypeNameFormat.wellKnown &&
            record.type.length == 1 &&
            record.type[0] == 0x55) {
          // URI Record
          final prefixCode = record.payload.isNotEmpty ? record.payload[0] : 0;
          final body = record.payload.length > 1
              ? utf8.decode(record.payload.sublist(1), allowMalformed: true)
              : '';
          final prefix = switch (prefixCode) {
            1 => 'http://www.',
            2 => 'https://www.',
            3 => 'http://',
            4 => 'https://',
            _ => '',
          };
          return '$prefix$body';
        } else {
          final text = utf8.decode(record.payload, allowMalformed: true);
          if (text.contains('carrin://') || text.contains('docs.google.com') || text.contains('{')) {
            return text;
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> _startNfcSession({required bool isTransmitMode}) async {
    if (!_isNfcAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NFC não está disponível ou habilitado nas configurações deste aparelho.')),
      );
      return;
    }

    try {
      NfcManager.instance.stopSession();
    } catch (_) {}

    setState(() {
      _isNfcActive = true;
      _isTransmitMode = isTransmitMode;
      _nfcStatusText = isTransmitMode
          ? '🔵 Transmitindo "$_selectedList"... Aproxime o celular receptor'
          : '🟢 Modo Inteligente Receptor... Aguardando celular transmissor';
    });

    try {
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso14443, NfcPollingOption.iso15693},
        alertMessageIos: isTransmitMode
            ? 'Aproxime do celular receptor para transmitir a lista "$_selectedList"!'
            : 'Aproxime do celular transmissor para receber a lista!',
        onDiscovered: (NfcTag tag) async {
          HapticFeedback.heavyImpact();

          final provider = Provider.of<ItemProvider>(context, listen: false);

          if (isTransmitMode) {
            final uriToTransmit = _carrinPayloadUri;
            final record = NdefRecord(
              typeNameFormat: TypeNameFormat.wellKnown,
              type: Uint8List.fromList([0x55]), // 'U'
              identifier: Uint8List(0),
              payload: Uint8List.fromList([0, ...utf8.encode(uriToTransmit)]),
            );
            final message = NdefMessage(records: [record]);

            try {
              if (defaultTargetPlatform == TargetPlatform.android) {
                final ndefAndroid = android_nfc.NdefAndroid.from(tag);
                if (ndefAndroid != null && ndefAndroid.isWritable) {
                  await ndefAndroid.writeNdefMessage(message);
                }
              } else if (defaultTargetPlatform == TargetPlatform.iOS) {
                final ndefIos = ios_nfc.NdefIos.from(tag);
                if (ndefIos != null) {
                  await ndefIos.writeNdef(message);
                }
              }
            } catch (_) {}

            if (mounted) {
              setState(() {
                _nfcStatusText = 'Dispositivo ou Tag NFC detectado com sucesso!';
              });
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Row(
                    children: [
                      Icon(Icons.nfc_rounded, color: Colors.greenAccent),
                      SizedBox(width: 8),
                      Text('Lista transmitida via NFC com sucesso!'),
                    ],
                  ),
                  backgroundColor: Color(0xFF1B5E20),
                ),
              );
            }
          } else {
            // Modo Leitura: lê o payload da tag / dispositivo
            String? extracted;
            try {
              if (defaultTargetPlatform == TargetPlatform.android) {
                final ndef = android_nfc.NdefAndroid.from(tag);
                if (ndef != null) {
                  final msg = ndef.cachedNdefMessage ?? await ndef.getNdefMessage();
                  if (msg != null) {
                    extracted = _extractTextFromNdefMessage(msg);
                  }
                }
              } else if (defaultTargetPlatform == TargetPlatform.iOS) {
                final ndefIos = ios_nfc.NdefIos.from(tag);
                if (ndefIos != null && ndefIos.cachedNdefMessage != null) {
                  extracted = _extractTextFromNdefMessage(ndefIos.cachedNdefMessage!);
                }
              }
            } catch (_) {}

            if (extracted != null && extracted.isNotEmpty) {
              final payload = SharedListService.instance.decodeList(extracted);
              if (payload != null && mounted) {
                Navigator.pop(context);
                await _autoImportAndOpen(context, payload, provider);
                return;
              }
            }

            if (mounted) {
              setState(() {
                _nfcStatusText = 'Sinal NFC detectado!';
              });
            }
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isNfcActive = false;
          _nfcStatusText = 'Sessão NFC finalizada ou cancelada';
        });
      }
    }
  }

  Future<void> _autoImportAndOpen(
    BuildContext context,
    SharedListPayload payload,
    ItemProvider provider,
  ) async {
    await provider.importAndOpenSharedList(payload);

    try {
      if ((await Vibration.hasVibrator()) == true) {
        Vibration.vibrate(duration: 80);
      }
    } catch (_) {}

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.sync_rounded, color: Colors.greenAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '🎉 Lista "${payload.title}" aberta e sincronizada!',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF1B5E20),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _connectToSpreadsheet(String rawInput) async {
    final clean = rawInput.trim();
    if (clean.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cole o link da lista ou ID.')),
      );
      return;
    }

    final provider = Provider.of<ItemProvider>(context, listen: false);

    // 1. Tenta decodificar como payload direto do CARRIN
    final payload = SharedListService.instance.decodeList(clean);
    if (payload != null) {
      Navigator.pop(context);
      await _autoImportAndOpen(context, payload, provider);
      return;
    }

    // 2. Se for link do Google Sheets
    setState(() => _isConnecting = true);
    try {
      final parsedId = UserSheetsService.extractSpreadsheetId(clean);
      await provider.importSharedListWithSpreadsheet(
        title: _selectedList,
        spreadsheetId: parsedId,
        fallbackItems: [],
        budget: 0.0,
      );

      if (mounted) {
        setState(() {
          _isConnecting = false;
          _isUsingCustomSheet = true;
          _spreadsheetId = parsedId;
          _spreadsheetUrl = 'https://docs.google.com/spreadsheets/d/$parsedId/edit';
        });

        Navigator.pop(context); // Fecha a folha para exibir os itens na tela
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lista "$_selectedList" conectada à planilha com sucesso!'),
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
    final provider = Provider.of<ItemProvider>(context, listen: false);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Escanear QR da Lista Compartilhada')),
          body: MobileScanner(
            onDetect: (capture) {
              for (final barcode in capture.barcodes) {
                final code = barcode.rawValue?.trim() ?? barcode.displayValue?.trim();
                if (code != null && code.isNotEmpty) {
                  Navigator.pop(context);
                  final payload = SharedListService.instance.decodeList(code);
                  if (payload != null) {
                    Navigator.pop(context);
                    _autoImportAndOpen(context, payload, provider);
                  } else {
                    _enterLinkController.text = code;
                    _connectToSpreadsheet(code);
                  }
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
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.primaryColor;
    final cardColor = theme.cardColor;

    final String qrData = _qrForCarrinApp
        ? _carrinPayloadUri
        : (_spreadsheetUrl ?? (_spreadsheetId != null ? 'https://docs.google.com/spreadsheets/d/$_spreadsheetId/edit' : _carrinPayloadUri));

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
                  color: Colors.blue.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.share_location_rounded, color: Colors.blue, size: 24),
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
                      'Sincronize com outro aparelho em tempo real',
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

          // Card de Seleção e Confirmação de Lista Única
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: primary.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.inventory_2_outlined, color: primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Compartilhando exclusivamente a lista:',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      Text(
                        _selectedList,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                Consumer<ItemProvider>(
                  builder: (ctx, prov, _) {
                    if (prov.months.length <= 1) return const SizedBox.shrink();
                    return PopupMenuButton<String>(
                      icon: const Icon(Icons.swap_horiz_rounded, size: 22),
                      tooltip: 'Trocar Lista',
                      onSelected: (newMonth) async {
                        final prov = Provider.of<ItemProvider>(context, listen: false);
                        final items = await prov.getItemsForMonth(newMonth);
                        final listBudget = (newMonth == prov.currentMonth) ? prov.budget : 0.0;
                        final existingSsId = await prov.getDedicatedSpreadsheetIdForList(newMonth);

                        setState(() {
                          _selectedList = newMonth;
                          _spreadsheetId = existingSsId;
                          if (existingSsId != null && existingSsId.isNotEmpty) {
                            _spreadsheetUrl = 'https://docs.google.com/spreadsheets/d/$existingSsId/edit';
                          }
                          _carrinPayloadUri = SharedListService.instance.encodeSingleList(
                            title: newMonth,
                            budget: listBudget,
                            items: items,
                            spreadsheetId: existingSsId,
                          );
                        });
                        _updatePayloadForSelectedList();
                      },
                      itemBuilder: (popupCtx) => prov.months.map((m) {
                        return PopupMenuItem<String>(
                          value: m,
                          child: Row(
                            children: [
                              Icon(
                                m == _selectedList ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                size: 18,
                                color: m == _selectedList ? primary : Colors.grey,
                              ),
                              const SizedBox(width: 8),
                              Text(m, style: TextStyle(fontWeight: m == _selectedList ? FontWeight.bold : FontWeight.normal)),
                            ],
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
              ],
            ),
          ),

          // Banner de Status se já estiver em planilha compartilhada
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

          const SizedBox(height: 12),

          // 3 Abas em Destaque: NFC, QR Code e Google Sheets
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
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              tabs: const [
                Tab(icon: Icon(Icons.nfc_rounded, size: 20), text: 'NFC'),
                Tab(icon: Icon(Icons.qr_code_2_rounded, size: 20), text: 'QR Code'),
                Tab(icon: Icon(Icons.table_chart_rounded, size: 20), text: 'Google Sheets'),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // Conteúdo das Abas
          SizedBox(
            height: 350,
            child: TabBarView(
              controller: _tabController,
              children: [
                // 1. ABA NFC (Aproximação Ativa)
                _buildNfcTab(primary),

                // 2. ABA QR CODE (Universal & iPhone)
                _buildQrTab(qrData),

                // 3. ABA GOOGLE SHEETS & E-MAIL
                _buildGoogleSheetsTab(theme),
              ],
            ),
          ),

          const SizedBox(height: 10),
          const Divider(),

          // Rodapé: Entrar na Lista de Outra Pessoa
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Entrar na Lista de Outra Pessoa:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
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
                    hintText: 'Cole o link compartilhado ou ID',
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
                    : const Text('Carregar'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

  // 1. ABA NFC
  Widget _buildNfcTab(Color primary) {
    final isListening = !_isTransmitMode;
    final accentColor = isListening ? Colors.green : Colors.blue;

    return SingleChildScrollView(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(height: 8),

          // Seletor Inteligente de Papel: Receptor vs Transmissor
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () {
                    setState(() => _isTransmitMode = false);
                    _startNfcSession(isTransmitMode: false);
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isListening ? Colors.green : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.download_rounded, size: 16, color: isListening ? Colors.white : Colors.grey[700]),
                        const SizedBox(width: 6),
                        Text(
                          '📥 Receber Lista',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isListening ? Colors.white : Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                InkWell(
                  onTap: () {
                    setState(() => _isTransmitMode = true);
                    _startNfcSession(isTransmitMode: true);
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: !isListening ? Colors.blue[700] : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.upload_rounded, size: 16, color: !isListening ? Colors.white : Colors.grey[700]),
                        const SizedBox(width: 6),
                        Text(
                          '📤 Transmitir Lista',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: !isListening ? Colors.white : Colors.grey[700],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Radar animado
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 125,
                height: 125,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor.withValues(alpha: 0.08),
                ),
              ),
              Container(
                width: 95,
                height: 95,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor.withValues(alpha: 0.18),
                ),
              ),
              Icon(
                isListening ? Icons.sensors_rounded : Icons.tap_and_play_rounded,
                size: 52,
                color: (_isNfcAvailable && _isNfcActive) ? accentColor : Colors.grey,
              ),
            ],
          ),

          const SizedBox(height: 14),

          Text(
            !_isNfcAvailable
                ? 'NFC Desativado no Aparelho'
                : (isListening
                    ? '🟢 Modo Inteligente: Pronto para Receber'
                    : '🔵 Transmitindo: "$_selectedList"'),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              !_isNfcAvailable
                  ? 'Ative o NFC nas configurações do seu celular para usar esta função.'
                  : _nfcStatusText,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11.5, color: Colors.grey),
            ),
          ),

          const SizedBox(height: 16),

          if (isListening)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.green[800],
                side: BorderSide(color: Colors.green[700]!),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (ctx) => const BarcodeScannerScreen()),
                );
              },
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
              label: const Text('Ou Ler QR Code com a Câmera', style: TextStyle(fontSize: 12)),
            )
          else
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.blue[700],
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onPressed: () => _tabController.animateTo(1),
              icon: const Icon(Icons.qr_code_rounded, size: 16),
              label: const Text('Exibir QR Code Desta Lista', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }

  // 2. ABA QR CODE
  Widget _buildQrTab(String qrData) {
    final effectiveData = qrData.isNotEmpty ? qrData : _carrinPayloadUri;

    return SingleChildScrollView(
      child: Column(
        children: [
          // Seletor de Destino do QR Code
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ChoiceChip(
                label: const Text('📱 No App CARRIN', style: TextStyle(fontSize: 11)),
                selected: _qrForCarrinApp,
                onSelected: (val) => setState(() => _qrForCarrinApp = true),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('🍎 iPhone / Web (Google)', style: TextStyle(fontSize: 11)),
                selected: !_qrForCarrinApp,
                onSelected: (val) => setState(() => _qrForCarrinApp = false),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Imagem do QR Code
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8),
              ],
            ),
            child: effectiveData.isNotEmpty
                ? QrImageView(
                    data: effectiveData,
                    version: QrVersions.auto,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    size: 180.0,
                    gapless: true,
                    errorStateBuilder: (cxt, err) {
                      return SizedBox(
                        width: 180,
                        height: 180,
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.qr_code_2_rounded, size: 36, color: Colors.grey),
                              const SizedBox(height: 6),
                              Text('Atualizando QR Code...', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                            ],
                          ),
                        ),
                      );
                    },
                  )
                : const SizedBox(
                    width: 180,
                    height: 180,
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
          ),
          const SizedBox(height: 10),

          Text(
            _qrForCarrinApp
                ? 'Aponte a câmera do celular com CARRIN para carregar a lista na hora'
                : 'Aponte a câmera do iPhone para abrir no Google Planilhas / Safari',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11.5, color: Colors.grey),
          ),
          const SizedBox(height: 10),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green[700],
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: effectiveData));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Link copiado para a área de transferência!'), backgroundColor: Colors.green),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Copiar Link', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (ctx) => const BarcodeScannerScreen()),
                  );
                },
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                label: const Text('Ler QR Code', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 3. ABA GOOGLE SHEETS
  Widget _buildGoogleSheetsTab(ThemeData theme) {
    final displayUrl = _spreadsheetUrl ?? (_spreadsheetId != null ? 'https://docs.google.com/spreadsheets/d/$_spreadsheetId/edit' : null);

    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline_rounded, color: Colors.orange, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Para compartilhar SOMENTE esta lista isolada, utilize as abas NFC ou QR Code do CARRIN.',
                    style: TextStyle(fontSize: 11.5, color: Colors.deepOrange),
                  ),
                ),
              ],
            ),
          ),
          const Text(
            'Conecte por E-mail Google ou abra a planilha oficial na nuvem:',
            style: TextStyle(fontSize: 12, color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Gmail da outra pessoa',
                    hintText: 'exemplo@gmail.com',
                    isDense: true,
                    prefixIcon: const Icon(Icons.alternate_email_rounded, size: 18),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
                onPressed: _isSharingEmail ? null : _shareWithGoogleEmail,
                child: _isSharingEmail
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Convidar'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (displayUrl != null) ...[
            OutlinedButton.icon(
              onPressed: () async {
                final uri = Uri.parse(displayUrl);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
              icon: const Icon(Icons.open_in_browser_rounded, size: 18),
              label: const Text('Abrir Planilha no Navegador'),
            ),
          ],
        ],
      ),
    );
  }
}
