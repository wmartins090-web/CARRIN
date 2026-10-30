import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:provider/provider.dart';
import '../models/item.dart';
import '../providers/item_provider.dart';
import '../services/receipt_parser.dart';
import '../services/utils.dart';
import '../services/community_price_service.dart';
import '../services/sefaz_receipt_service.dart';
import 'barcode_scanner_screen.dart';

class ReceiptScannerScreen extends StatefulWidget {
  final List<Item>? cartItemsToCompare;
  final bool isVerificationMode;

  const ReceiptScannerScreen({
    super.key,
    this.cartItemsToCompare,
    this.isVerificationMode = false,
  });

  @override
  State<ReceiptScannerScreen> createState() => _ReceiptScannerScreenState();
}

class _ReceiptScannerScreenState extends State<ReceiptScannerScreen> {
  final ImagePicker _picker = ImagePicker();
  final TextRecognizer _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  
  bool _isProcessing = false;
  List<Item> _extractedItems = [];
  String? _storeName;
  String? _cnpj;
  String? _nfcKey;
  String? _uf;
  String _statusMessage = 'Tire uma foto, escolha da galeria ou escaneie o QR Code NFC-e.';

  @override
  void dispose() {
    _textRecognizer.close();
    super.dispose();
  }

  double get _totalAmount => _extractedItems.fold(0.0, (sum, it) => sum + (it.unitPrice * it.quantity));

  Future<void> _processImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(source: source);
      if (image == null) return;

      setState(() {
        _isProcessing = true;
        _statusMessage = 'Lendo e analisando o cupom fiscal com IA...';
      });

      final inputImage = InputImage.fromFilePath(image.path);
      final RecognizedText recognizedText = await _textRecognizer.processImage(inputImage);

      final parseResult = ReceiptParser.parseWithMetadata(recognizedText.text);

      setState(() {
        _extractedItems = parseResult.items;
        _storeName = parseResult.storeName ?? _storeName;
        _cnpj = parseResult.cnpj ?? _cnpj;
        _nfcKey = parseResult.nfcKey ?? _nfcKey;
        _uf = parseResult.uf ?? _uf;
        _isProcessing = false;
        if (parseResult.items.isEmpty) {
          _statusMessage = 'Não foi possível identificar itens ou preços claros neste cupom.';
        } else {
          _statusMessage = 'Encontrados ${_extractedItems.length} itens. Toque em um item para editar.';
        }
      });

    } catch (e) {
      setState(() {
        _statusMessage = 'Erro ao processar imagem: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _scanNfcQrCode() async {
    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const BarcodeScannerScreen(title: 'Escanear QR Code NFC-e'),
      ),
    );

    if (scanned == null || scanned.isEmpty) return;

    final initial = ReceiptParser.parseNfcUrl(scanned);
    if (initial.nfcKey == null && !scanned.startsWith('http')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('O código lido não corresponde a uma URL de NFC-e válida.')),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
      _nfcKey = initial.nfcKey ?? _nfcKey;
      _cnpj = initial.cnpj ?? _cnpj;
      _uf = initial.uf ?? _uf;
      _statusMessage = 'Consultando SEFAZ (${_uf ?? 'BR'}) e baixando itens da nota...';
    });

    try {
      final sefazResult = await SefazReceiptService.instance.fetchItemsFromQrUrl(scanned);

      if (!mounted) return;

      setState(() {
        _isProcessing = false;
        _extractedItems = sefazResult.items;
        _storeName = sefazResult.storeName ?? _storeName;
        _cnpj = sefazResult.cnpj ?? _cnpj;
        _nfcKey = sefazResult.nfcKey ?? _nfcKey;
        _uf = sefazResult.uf ?? _uf;
        _statusMessage = 'Sucesso! ${_extractedItems.length} produtos carregados diretamente da SEFAZ.';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🎉 ${sefazResult.items.length} itens importados diretamente da SEFAZ!'),
          backgroundColor: Colors.green.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _isProcessing = false;
        _statusMessage = 'NFC-e detectada (UF: ${_uf ?? 'BR'}, CNPJ: ${_cnpj ?? '-'}).';
      });

      final bool isCaptcha = e is SefazCaptchaException || e.toString().toLowerCase().contains('captcha');
      final String reason = isCaptcha
          ? 'A SEFAZ do seu estado (${_uf ?? 'BR'}) exigiu validação por CAPTCHA para exibir os itens.'
          : 'Não foi possível baixar os itens diretamente da SEFAZ (${e.toString().replaceAll('Exception: ', '')}).';

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(
            children: [
              Icon(Icons.qr_code_2, color: Colors.green),
              SizedBox(width: 8),
              Expanded(child: Text('NFC-e Reconhecida')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_uf != null) Text('Estado (UF): $_uf', style: const TextStyle(fontWeight: FontWeight.bold)),
              if (_cnpj != null) Text('CNPJ: $_cnpj'),
              const SizedBox(height: 8),
              if (_nfcKey != null) Text('Chave: $_nfcKey', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.amber.shade300),
                ),
                child: Text(
                  reason,
                  style: TextStyle(fontSize: 12.5, color: Colors.amber.shade900),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Deseja tirar uma foto do cupom fiscal para a IA extrair todos os produtos agora?',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Agora não'),
            ),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _processImage(ImageSource.camera);
              },
              icon: const Icon(Icons.camera_alt, size: 16),
              label: const Text('Tirar Foto do Cupom'),
            ),
          ],
        ),
      );
    }
  }

  void _editStoreNameDialog() {
    final ctrl = TextEditingController(text: _storeName ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Nome do Estabelecimento'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Supermercado / Loja', hintText: 'Ex: Supermercados BH'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _storeName = ctrl.text.trim().isEmpty ? null : ctrl.text.trim();
              });
              Navigator.pop(ctx);
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  void _editItemDialog(int index) {
    final item = _extractedItems[index];
    final nameCtrl = TextEditingController(text: item.name);
    final qtyCtrl = TextEditingController(text: Utils.formatNumber(item.quantity));
    final priceCtrl = TextEditingController(text: Utils.formatCurrencyInput(item.unitPrice));
    if (priceCtrl.text.isNotEmpty) priceCtrl.selection = TextSelection.collapsed(offset: priceCtrl.text.length);
    String selectedCategory = item.category;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Editar Item do Cupom'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Nome do Produto'),
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: qtyCtrl,
                        decoration: const InputDecoration(labelText: 'Qtd'),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: priceCtrl,
                        decoration: const InputDecoration(labelText: 'Preço (R\$)', prefixText: 'R\$ ', hintText: '0,00'),
                        keyboardType: TextInputType.number,
                        inputFormatters: [CurrencyInputFormatter()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: ItemProvider.categories.contains(selectedCategory) ? selectedCategory : 'Outros',
                  decoration: const InputDecoration(labelText: 'Categoria'),
                  items: ItemProvider.categories.map((c) => DropdownMenuItem(
                    value: c,
                    child: Text('${ItemProvider.categoryEmojis[c] ?? '📦'} $c'),
                  )).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => selectedCategory = val);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                final newName = nameCtrl.text.trim();
                final newQty = double.tryParse(qtyCtrl.text.replaceAll(',', '.')) ?? 1.0;
                final newPrice = Utils.parseCurrency(priceCtrl.text);

                if (newName.isNotEmpty) {
                  setState(() {
                    _extractedItems[index] = item.copyWith(
                      name: newName,
                      quantity: newQty,
                      unitPrice: newPrice,
                      category: selectedCategory,
                    );
                  });
                }
                Navigator.pop(ctx);
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
  }

  void _saveItems() async {
    final provider = Provider.of<ItemProvider>(context, listen: false);
    int addedCount = 0;
    int updatedCount = 0;

    for (var item in _extractedItems) {
      final normalized = Utils.normalize(item.name);
      final existingIndex = provider.items.indexWhere(
        (it) => Utils.normalize(it.name) == normalized,
      );

      if (existingIndex != -1) {
        final existingItem = provider.items[existingIndex];
        final updated = existingItem.copyWith(
          unitPrice: item.unitPrice > 0 ? item.unitPrice : existingItem.unitPrice,
          quantity: item.quantity,
          isBought: true,
          category: item.category.isNotEmpty ? item.category : existingItem.category,
        );
        await provider.updateItem(updated);
        updatedCount++;
      } else {
        await provider.addItem(item);
        addedCount++;
      }
    }

    // Registra na base da comunidade com selo de Nota Fiscal Verificada
    final marketName = _storeName ?? provider.detectedSupermarket?['name'] ?? CommunityPriceService.defaultStoreName;
    final lat = (provider.detectedSupermarket?['latitude'] as num?)?.toDouble() ?? 
        (marketName == CommunityPriceService.defaultStoreName ? CommunityPriceService.defaultStoreLat : null);
    final lng = (provider.detectedSupermarket?['longitude'] as num?)?.toDouble() ?? 
        (marketName == CommunityPriceService.defaultStoreName ? CommunityPriceService.defaultStoreLng : null);

    for (var item in _extractedItems) {
      if (item.unitPrice > 0) {
        CommunityPriceService.instance.publishPrice(
          productName: item.name,
          price: item.unitPrice,
          supermarketName: marketName,
          category: item.category,
          unit: item.isKg ? 'kg' : 'un',
          latitude: lat,
          longitude: lng,
          submittedBy: provider.activeUserDisplayName,
          verifiedReceipt: true,
        ).catchError((_) => false);
      }
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            addedCount > 0 && updatedCount > 0
                ? '$addedCount novos adicionados e $updatedCount itens da lista atualizados!'
                : (addedCount > 0
                    ? '$addedCount novos itens salvos na lista!'
                    : '$updatedCount itens da lista foram atualizados e marcados como comprados!'),
          ),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<ItemProvider>(context, listen: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isVerificationMode ? 'Conferir Cupom Fiscal' : 'Escanear Nota Fiscal'),
        actions: [
          if (_extractedItems.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Escanear outro cupom',
              onPressed: () {
                setState(() {
                  _extractedItems = [];
                  _storeName = null;
                  _cnpj = null;
                  _nfcKey = null;
                  _uf = null;
                  _statusMessage = 'Tire uma foto, escolha da galeria ou escaneie o QR Code NFC-e.';
                });
              },
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
        children: [
          if (_isProcessing)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Analisando documento (IA)...', style: TextStyle(fontSize: 16)),
                  ],
                ),
              ),
            )
          else if (_extractedItems.isNotEmpty)
            Expanded(
              child: Column(
                children: [
                  // Banner de Estabelecimento Detectado
                  if (_storeName != null || _cnpj != null)
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.withValues(alpha: 0.15)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.storefront, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _storeName ?? 'Estabelecimento',
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                ),
                                if (_cnpj != null)
                                  Text(
                                    'CNPJ: $_cnpj${_uf != null ? ' • $_uf' : ''}',
                                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            tooltip: 'Editar loja',
                            onPressed: _editStoreNameDialog,
                          ),
                        ],
                      ),
                    ),

                  // Resumo financeiro dos itens extraídos
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.all(16),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${_extractedItems.length} produtos identificados',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Total: ${Utils.formatCurrency(_totalAmount)}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 🛡️ Mapew Feature: Painel de Conferência Inteligente contra o Carrinho
                  if (widget.isVerificationMode || (widget.cartItemsToCompare != null && widget.cartItemsToCompare!.isNotEmpty)) ...[
                    Builder(builder: (ctx) {
                      final cartList = widget.cartItemsToCompare ?? provider.items;
                      final cartTotal = cartList.fold(0.0, (sum, it) => sum + (it.unitPrice * it.quantity));
                      final diff = _totalAmount - cartTotal;
                      final isHigher = diff > 0.05;
                      final isLower = diff < -0.05;

                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isHigher
                              ? Colors.red.withValues(alpha: 0.1)
                              : (isLower ? Colors.green.withValues(alpha: 0.1) : Colors.blue.withValues(alpha: 0.1)),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isHigher
                                ? Colors.red.shade400
                                : (isLower ? Colors.green.shade400 : Colors.blue.shade300),
                            width: 1.2,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  isHigher ? Icons.warning_amber_rounded : (isLower ? Icons.savings_outlined : Icons.verified_rounded),
                                  color: isHigher ? Colors.red : (isLower ? Colors.green : Colors.blue),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    isHigher
                                        ? 'Atenção: Cobrança maior que o planejado!'
                                        : (isLower ? 'Parabéns: Total do caixa foi menor!' : 'Conferência de Caixa Perfeita!'),
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: isHigher ? Colors.red.shade900 : (isLower ? Colors.green.shade900 : Colors.blue.shade900),
                                    ),
                                  ),
                                ),
                                Text(
                                  isHigher ? '+ ${Utils.formatCurrency(diff)}' : (isLower ? '- ${Utils.formatCurrency(diff.abs())}' : 'Bateu 100%'),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13,
                                    color: isHigher ? Colors.red : (isLower ? Colors.green : Colors.blue),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Seu Carrinho: ${Utils.formatCurrency(cartTotal)}  •  Nota Fiscal: ${Utils.formatCurrency(_totalAmount)}',
                              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],

                  // Lista de Itens com badge inteligente de correspondência
                  Expanded(
                    child: ListView.builder(
                      itemCount: _extractedItems.length,
                      itemBuilder: (context, index) {
                        final item = _extractedItems[index];
                        final subtotal = item.unitPrice * item.quantity;
                        final normalized = Utils.normalize(item.name);
                        final alreadyInList = provider.items.any((it) => Utils.normalize(it.name) == normalized);

                        return Dismissible(
                          key: Key('item_${item.name}_$index'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            color: Colors.red,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            child: const Icon(Icons.delete, color: Colors.white),
                          ),
                          onDismissed: (_) {
                            setState(() {
                              _extractedItems.removeAt(index);
                            });
                          },
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                              child: Text(
                                ItemProvider.categoryEmojis[item.category] ?? '📦',
                                style: const TextStyle(fontSize: 20),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    item.name,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                if (alreadyInList) ...[
                                  Builder(builder: (c) {
                                    final cartMatch = provider.items.firstWhere(
                                      (it) => Utils.normalize(it.name) == normalized,
                                    );
                                    final priceDiff = item.unitPrice - cartMatch.unitPrice;
                                    final hasDiff = cartMatch.unitPrice > 0 && priceDiff.abs() > 0.05;

                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.green.withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(6),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.check, size: 10, color: Colors.green),
                                              SizedBox(width: 2),
                                              Text('Na Lista', style: TextStyle(fontSize: 9, color: Colors.green, fontWeight: FontWeight.bold)),
                                            ],
                                          ),
                                        ),
                                        if (hasDiff) ...[
                                          const SizedBox(width: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: priceDiff > 0 ? Colors.red.withValues(alpha: 0.15) : Colors.amber.withValues(alpha: 0.2),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              priceDiff > 0 ? 'Cobrou +${Utils.formatCurrency(priceDiff)}' : 'Desconto -${Utils.formatCurrency(priceDiff.abs())}',
                                              style: TextStyle(
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.bold,
                                                color: priceDiff > 0 ? Colors.red.shade800 : Colors.amber.shade900,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  }),
                                ]
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).primaryColor.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '+ Novo',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: Theme.of(context).primaryColor,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              '${Utils.formatNumber(item.quantity)}x ${Utils.formatCurrency(item.unitPrice)} • ${item.category}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  Utils.formatCurrency(subtotal),
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 20, color: Colors.grey),
                                  onPressed: () {
                                    setState(() {
                                      _extractedItems.removeAt(index);
                                    });
                                  },
                                ),
                              ],
                            ),
                            onTap: () => _editItemDialog(index),
                          ),
                        );
                      },
                    ),
                  ),

                  // Botão de Confirmação e Salvamento
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _saveItems,
                        icon: const Icon(Icons.check_circle_outline),
                        label: Text(
                          'Salvar ${_extractedItems.length} Itens na Lista',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                      ),
                    ),
                  )
                ],
              ),
            )
          else
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long, size: 80, color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6)),
                      const SizedBox(height: 16),
                      Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 32),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _processImage(ImageSource.camera),
                            icon: const Icon(Icons.camera_alt),
                            label: const Text('Câmera (Foto)'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _processImage(ImageSource.gallery),
                            icon: const Icon(Icons.photo_library),
                            label: const Text('Galeria'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _scanNfcQrCode,
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('QR Code NFC-e'),
                          ),
                        ],
                      )
                    ],
                  ),
                ),
              ),
            )
        ],
      ),
    ),
  );
}
}
