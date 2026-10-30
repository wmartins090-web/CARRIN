import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import '../models/item.dart';
import '../providers/item_provider.dart';
import 'receipt_parser.dart';

/// Exceção lançada quando a SEFAZ exige CAPTCHA ou proteção anti-robô/WAF.
class SefazCaptchaException implements Exception {
  final String message;
  const SefazCaptchaException([this.message = 'A SEFAZ solicitou validação pelo navegador.']);

  @override
  String toString() => message;
}

/// Exceção lançada quando a página foi carregada, mas não foi possível extrair itens válidos.
class SefazParseException implements Exception {
  final String message;
  const SefazParseException(this.message);

  @override
  String toString() => message;
}

/// Serviço responsável por consultar diretamente a SEFAZ estadual a partir da URL do QR Code
/// e extrair todos os produtos comprados, quantidades, valores e dados do estabelecimento.
class SefazReceiptService {
  SefazReceiptService._();
  static final SefazReceiptService instance = SefazReceiptService._();

  /// Headers que emulam um navegador mobile real para evitar bloqueios triviais da SEFAZ
  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.6367.82 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7',
    'Cache-Control': 'no-cache',
    'Pragma': 'no-cache',
    'Upgrade-Insecure-Requests': '1',
  };

  /// Consulta a SEFAZ via HTTP e converte a resposta HTML em um [ReceiptParseResult] com todos os itens
  Future<ReceiptParseResult> fetchItemsFromQrUrl(String qrUrl) async {
    final cleanUrl = qrUrl.trim();
    if (!cleanUrl.startsWith('http://') && !cleanUrl.startsWith('https://')) {
      throw const FormatException('URL do QR Code inválida.');
    }

    final initialParse = ReceiptParser.parseNfcUrl(cleanUrl);
    final nfcKey = initialParse.nfcKey;
    final uf = initialParse.uf;
    final cnpjFromKey = initialParse.cnpj;

    http.Response response;
    try {
      final uri = Uri.parse(cleanUrl);
      final client = http.Client();
      try {
        response = await client
            .get(uri, headers: _browserHeaders)
            .timeout(const Duration(seconds: 15));
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('Erro na conexão com SEFAZ: $e');
      throw Exception('Não foi possível conectar ao portal da SEFAZ ($e). Verifique sua internet.');
    }

    if (response.statusCode != 200) {
      throw Exception(
        'A SEFAZ retornou erro ${response.statusCode}. O portal pode estar indisponível no momento.',
      );
    }

    // Decodifica o HTML respeitando o encoding da SEFAZ (muitas usam ISO-8859-1 / Latin1)
    String htmlContent;
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('iso-8859-1') || contentType.contains('latin1')) {
      htmlContent = latin1.decode(response.bodyBytes);
    } else {
      try {
        htmlContent = utf8.decode(response.bodyBytes);
      } catch (_) {
        htmlContent = latin1.decode(response.bodyBytes);
      }
    }

    // Verifica se a SEFAZ apresentou um CAPTCHA ou desafio WAF F5 BIG-IP
    _checkForCaptcha(htmlContent);

    // Realiza o parse do documento HTML
    return parseSefazHtml(
      htmlContent: htmlContent,
      nfcKey: nfcKey,
      uf: uf,
      cnpjFallback: cnpjFromKey,
    );
  }

  /// Verifica indicadores comuns de CAPTCHA ou proteção de bot nos portais estaduais (F5 BIG-IP, reCAPTCHA, etc.)
  void _checkForCaptcha(String html) {
    final lower = html.toLowerCase();
    
    // Indicadores de WAF / Bot protection que requerem execução de JavaScript (ex: F5 BIG-IP da SEFAZ-RJ)
    final isBotProtection = lower.contains('/tspd/') ||
        lower.contains('loaderconfig') ||
        lower.contains('acesso bloqueado e/ou negado') ||
        lower.contains('acesso negado');

    final hasCaptchaKeywords = lower.contains('g-recaptcha') ||
        lower.contains('h-captcha') ||
        lower.contains('cf-turnstile') ||
        lower.contains('recaptcha') ||
        lower.contains('não sou um robô') ||
        lower.contains('nao sou um robo') ||
        lower.contains('digite os caracteres') ||
        lower.contains('validação de segurança') ||
        lower.contains('validacao de seguranca');

    // Se tiver indicador de captcha ou WAF e não tiver os elementos típicos de itens da NFC-e
    final hasItemsTable = lower.contains('txttit') ||
        lower.contains('fixo-prod-desc') ||
        lower.contains('item +') ||
        lower.contains('rcod') ||
        lower.contains('rvlunit');

    if ((isBotProtection || hasCaptchaKeywords) && !hasItemsTable) {
      throw const SefazCaptchaException(
        'A SEFAZ deste estado utiliza proteção de segurança que requer validação pelo navegador.',
      );
    }
  }

  /// Extrai itens, estabelecimento e totais a partir do HTML puro retornado pela SEFAZ
  ReceiptParseResult parseSefazHtml({
    required String htmlContent,
    String? nfcKey,
    String? uf,
    String? cnpjFallback,
  }) {
    final document = html_parser.parse(htmlContent);

    // 1. Extração do Nome do Estabelecimento
    String? storeName = _extractStoreName(document);

    // 2. Extração do CNPJ
    String? cnpj = _extractCnpj(document) ?? cnpjFallback;

    // 3. Extração dos Itens
    final List<Item> items = [];

    // Padrão 1: ENCAT / SVRS (RJ, RS, PR, BA, DF, etc.) - Tabela com <tr id="Item + X">
    final itemRows = document.querySelectorAll('tr[id^="Item"], tr.linha-item, table#tabResult tr');

    for (final row in itemRows) {
      final item = _parseEncatRow(row, storeName);
      if (item != null) {
        items.add(item);
      }
    }

    // Padrão 2: Fallback para seletores específicos caso não use tr[id^="Item"]
    if (items.isEmpty) {
      final altTitles = document.querySelectorAll('.txtTit, .fixo-prod-desc, .prod-desc');
      for (final titleEl in altTitles) {
        final parent = titleEl.parent?.parent ?? titleEl.parent;
        if (parent != null) {
          final item = _parseEncatRow(parent, storeName);
          if (item != null && !items.any((x) => x.name == item.name && x.unitPrice == item.unitPrice)) {
            items.add(item);
          }
        }
      }
    }

    if (items.isEmpty) {
      throw const SefazParseException(
        'A página da SEFAZ foi acessada, mas não foram encontrados produtos na tabela. O cupom pode ter expirado ou estar no formato resumido.',
      );
    }

    return ReceiptParseResult(
      storeName: storeName,
      cnpj: cnpj,
      nfcKey: nfcKey,
      uf: uf,
      items: items,
    );
  }

  /// Extrai os dados de um item a partir de uma linha de tabela no padrão ENCAT/SVRS
  Item? _parseEncatRow(dom.Element row, String? storeName) {
    // Descrição do Produto
    final descEl = row.querySelector('.txtTit, .fixo-prod-desc, .prod-desc, span.item-desc');
    final rawName = descEl?.text.trim() ?? '';
    if (rawName.isEmpty) return null;

    final cleanName = _sanitizeProductName(rawName);
    if (cleanName.length < 2) return null;

    // Quantidade
    double quantity = 1.0;
    final qtdEl = row.querySelector('.Rqtd, .fixo-prod-qtd, .prod-qtd');
    if (qtdEl != null) {
      final qtdMatch = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(qtdEl.text);
      if (qtdMatch != null) {
        quantity = double.tryParse(qtdMatch.group(1)!.replaceAll(',', '.')) ?? 1.0;
      }
    }

    // Valor Unitário
    double unitPrice = 0.0;
    final vlUnitEl = row.querySelector('.RvlUnit, .fixo-prod-vl-unit, .prod-vl-unit');
    if (vlUnitEl != null) {
      final vlMatch = RegExp(r'(\d+[.,]\d{2})').firstMatch(vlUnitEl.text);
      if (vlMatch != null) {
        unitPrice = double.tryParse(vlMatch.group(1)!.replaceAll(',', '.')) ?? 0.0;
      }
    }

    // Valor Total do Item (caso valor unitário não esteja explícito)
    final valEl = row.querySelector('.valor, .fixo-prod-vl-tot, .prod-total');
    if (valEl != null && unitPrice <= 0.0) {
      final totalMatch = RegExp(r'(\d+[.,]\d{2})').firstMatch(valEl.text);
      if (totalMatch != null) {
        final total = double.tryParse(totalMatch.group(1)!.replaceAll(',', '.')) ?? 0.0;
        if (quantity > 0) {
          unitPrice = double.parse((total / quantity).toStringAsFixed(2));
        } else {
          unitPrice = total;
        }
      }
    }

    if (unitPrice <= 0.0) return null;

    final formattedName = cleanName[0].toUpperCase() + cleanName.substring(1).toLowerCase();

    return Item(
      name: formattedName,
      quantity: quantity,
      unitPrice: unitPrice,
      category: ItemProvider.suggestCategoryForName(formattedName),
      isBought: true,
      supermarket: storeName,
    );
  }

  /// Limpa e normaliza a descrição de um produto
  String _sanitizeProductName(String raw) {
    var name = raw;
    // Remove códigos iniciais como "001 - " ou "12345 "
    name = name.replaceFirst(RegExp(r'^\d+\s*[-–]\s*'), '');
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();
    return name;
  }

  /// Extrai o nome do estabelecimento do HTML
  String? _extractStoreName(dom.Document doc) {
    final selectors = [
      '.txtTopo',
      '#u20',
      '.titulo',
      '.txtCenter',
      '.nome-fantasia',
      '.estabelecimento',
      '#identificacaoEstabelecimento',
    ];

    for (final sel in selectors) {
      final el = doc.querySelector(sel);
      if (el != null && el.text.trim().isNotEmpty) {
        var text = el.text.trim();
        text = text.replaceAll(RegExp(r'\s+'), ' ');
        if (text.length > 2 && text.length < 80) {
          return text.split(' ').map((w) {
            if (w.isEmpty) return '';
            if (w.length <= 2) return w.toUpperCase();
            return w[0].toUpperCase() + w.substring(1).toLowerCase();
          }).join(' ');
        }
      }
    }
    return null;
  }

  /// Extrai o CNPJ do estabelecimento
  String? _extractCnpj(dom.Document doc) {
    final text = doc.body?.text ?? '';
    final match = RegExp(r'\b(\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2})\b').firstMatch(text);
    if (match != null) {
      return match.group(1);
    }
    final rawMatch = RegExp(r'CNPJ:\s*([\d./-]+)').firstMatch(text);
    if (rawMatch != null) {
      return ReceiptParser.formatCnpj(rawMatch.group(1)!.replaceAll(RegExp(r'\D'), ''));
    }
    return null;
  }
}
