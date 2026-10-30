import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/receipt_parser.dart';
import '../services/sefaz_receipt_service.dart';

/// Modal com WebView embutida para contornar proteções WAF (como F5 BIG-IP / CAPTCHA)
/// e extrair automaticamente os produtos de notas fiscais da SEFAZ.
class SefazWebViewModal extends StatefulWidget {
  final String initialUrl;
  final String? nfcKey;
  final String? uf;
  final String? cnpjFallback;

  const SefazWebViewModal({
    super.key,
    required this.initialUrl,
    this.nfcKey,
    this.uf,
    this.cnpjFallback,
  });

  /// Exibe a modal em tela cheia e retorna os itens extraídos se bem-sucedido
  static Future<ReceiptParseResult?> show(
    BuildContext context, {
    required String url,
    String? nfcKey,
    String? uf,
    String? cnpjFallback,
  }) {
    return showModalBottomSheet<ReceiptParseResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SefazWebViewModal(
        initialUrl: url,
        nfcKey: nfcKey,
        uf: uf,
        cnpjFallback: cnpjFallback,
      ),
    );
  }

  @override
  State<SefazWebViewModal> createState() => _SefazWebViewModalState();
}

class _SefazWebViewModalState extends State<SefazWebViewModal> {
  late final WebViewController _controller;
  bool _isLoading = true;
  double _progress = 0.0;
  bool _isSuccess = false;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    super.dispose();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (mounted) setState(() => _isLoading = true);
          },
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress / 100);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _isLoading = false);
            _tryExtractProducts();
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));

    // Polling a cada 1.5s para capturar a tabela assim que o JS da SEFAZ renderizar
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      if (!_isSuccess) {
        _tryExtractProducts();
      }
    });
  }

  Future<void> _tryExtractProducts() async {
    if (_isSuccess || !mounted) return;

    try {
      final rawResult = await _controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );

      String html = rawResult.toString();
      // Em alguns dispositivos o retorno vem envolto em JSON string
      if (html.startsWith('"') && html.endsWith('"')) {
        try {
          html = jsonDecode(html) as String;
        } catch (_) {
          html = html.substring(1, html.length - 1);
        }
      }

      // Verifica se a tabela de produtos está presente
      final lower = html.toLowerCase();
      final hasTable = lower.contains('txttit') ||
          lower.contains('fixo-prod-desc') ||
          lower.contains('item +') ||
          lower.contains('rcod') ||
          lower.contains('rvlunit');

      if (!hasTable) return;

      final parsed = SefazReceiptService.instance.parseSefazHtml(
        htmlContent: html,
        nfcKey: widget.nfcKey,
        uf: widget.uf,
        cnpjFallback: widget.cnpjFallback,
      );

      if (parsed.items.isNotEmpty) {
        _isSuccess = true;
        _pollingTimer?.cancel();
        if (mounted) {
          Navigator.of(context).pop(parsed);
        }
      }
    } catch (_) {
      // Ignora e aguarda próximo polling ou interação do usuário
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.92,
      child: Column(
        children: [
          // Barra de título com botão fechar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(Icons.qr_code_2_rounded, color: primary, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Importando NFC-e (${widget.uf ?? 'SEFAZ'})',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                      Text(
                        'Se houver teste de segurança (CAPTCHA), resolva-o abaixo.',
                        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Fechar',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // Indicador de progresso
          if (_isLoading)
            LinearProgressIndicator(
              value: _progress > 0 ? _progress : null,
              color: primary,
              backgroundColor: primary.withValues(alpha: 0.1),
              minHeight: 3,
            ),

          // WebView com o portal da SEFAZ
          Expanded(
            child: ClipRRect(
              child: WebViewWidget(controller: _controller),
            ),
          ),
        ],
      ),
    );
  }
}
