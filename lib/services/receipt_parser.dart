import '../models/item.dart';
import '../providers/item_provider.dart';

/// Resultado estruturado da análise de um cupom fiscal.
class ReceiptParseResult {
  final String? storeName;
  final String? cnpj;
  final String? nfcKey;
  final String? uf;
  final List<Item> items;

  const ReceiptParseResult({
    this.storeName,
    this.cnpj,
    this.nfcKey,
    this.uf,
    required this.items,
  });

  ReceiptParseResult copyWith({
    String? storeName,
    String? cnpj,
    String? nfcKey,
    String? uf,
    List<Item>? items,
  }) {
    return ReceiptParseResult(
      storeName: storeName ?? this.storeName,
      cnpj: cnpj ?? this.cnpj,
      nfcKey: nfcKey ?? this.nfcKey,
      uf: uf ?? this.uf,
      items: items ?? this.items,
    );
  }
}

/// Utilitário para processamento e extração inteligente de itens, dados do estabelecimento
/// e dados fiscais (NFC-e / SAT) de notas e cupons.
class ReceiptParser {
  // Palavras-chave fiscais e de rodapé que nunca devem ser tratadas como produtos
  static final Set<String> _ignoredKeywords = {
    'total',
    'subtotal',
    'valor a pagar',
    'valor total',
    'total a pagar',
    'valor pago',
    'pagamento',
    'dinheiro',
    'cartao',
    'credito',
    'debito',
    'pix',
    'troco',
    'desconto',
    'acrescimo',
    'tributos',
    'valor aprox',
    'imposto',
    'icms',
    'procon',
    'chave de acesso',
    'cnpj',
    'inscricao',
    'extrato',
    'nfc-e',
    'nfce',
    'sat',
    'danfe',
    'consumidor',
    'emissao',
    'protocolo',
    'via consumidor',
    'via cliente',
    'obrigado',
    'volte sempre',
    'descricao',
    'vl unit',
    'vl total',
    'documento auxiliar',
  };

  static const Map<String, String> _ufCodes = {
    '11': 'RO', '12': 'AC', '13': 'AM', '14': 'RR', '15': 'PA', '16': 'AP', '17': 'TO',
    '21': 'MA', '22': 'PI', '23': 'CE', '24': 'RN', '25': 'PB', '26': 'PE', '27': 'AL',
    '28': 'SE', '29': 'BA', '31': 'MG', '32': 'ES', '33': 'RJ', '35': 'SP', '41': 'PR',
    '42': 'SC', '43': 'RS', '50': 'MS', '51': 'MT', '52': 'GO', '53': 'DF'
  };

  /// Analisa o texto bruto OCR de um cupom e extrai a lista de itens (compatibilidade direta).
  static List<Item> parse(String text) {
    return parseWithMetadata(text).items;
  }

  /// Analisa o texto bruto OCR extraindo itens e metadados fiscais (estabelecimento, CNPJ, NFC-e).
  static ReceiptParseResult parseWithMetadata(String text) {
    final rawLines = text.split('\n');
    final List<String> lines = [];
    for (var l in rawLines) {
      final trimmed = l.trim();
      if (trimmed.isNotEmpty) {
        lines.add(trimmed);
      }
    }

    final storeName = extractStoreName(text);
    final cnpj = extractCnpj(text);
    final nfcKey = extractNfcKey(text);
    final uf = nfcKey != null && nfcKey.length >= 2 ? _ufCodes[nfcKey.substring(0, 2)] : null;

    final List<Item> items = [];
    final priceRegex = RegExp(r'(\d+)[.,](\d{2})(?:\s|[^0-9]|$)*$');
    final qtyUnitPriceRegex = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(?:un|cx|pc|kg|lt|pct)?\s*[xX*]\s*(\d+[.,]\d{2})',
      caseSensitive: false,
    );

    int i = 0;
    while (i < lines.length) {
      final line = lines[i];

      // Ignora se for linha fiscal ou rodapé conhecido
      if (_isIgnoredLine(line)) {
        i++;
        continue;
      }

      // Procura formato de preço na linha atual
      final priceMatches = priceRegex.allMatches(line);

      if (priceMatches.isNotEmpty) {
        final lastMatch = priceMatches.last;
        final priceStr = '${lastMatch.group(1)}.${lastMatch.group(2)}';
        final linePrice = double.tryParse(priceStr) ?? 0.0;

        String rawName = line.substring(0, lastMatch.start).trim();

        // Se a linha antes do preço estiver vazia ou for só quantidade (ex: "1 UN X"),
        // verifica se a linha anterior continha o nome do produto (formato 2 linhas)
        if (_isOnlyQuantityOrShort(rawName) && i > 0) {
          final previousLine = lines[i - 1];
          if (!_isIgnoredLine(previousLine) && !priceRegex.hasMatch(previousLine)) {
            rawName = previousLine;
          }
        }

        // Tentar extrair quantidade e valor unitário se presentes na linha
        double quantity = 1.0;
        double unitPrice = linePrice;
        bool isKg = false;

        final qtyMatch = qtyUnitPriceRegex.firstMatch(line);
        if (qtyMatch != null) {
          final qStr = qtyMatch.group(1)!.replaceAll(',', '.');
          final uStr = qtyMatch.group(2)!.replaceAll(',', '.');
          final parsedQty = double.tryParse(qStr);
          final parsedUnit = double.tryParse(uStr);
          if (parsedQty != null && parsedQty > 0) {
            quantity = parsedQty;
          }
          if (parsedUnit != null && parsedUnit > 0) {
            unitPrice = parsedUnit;
          }
          isKg = RegExp(r'\bkg\b', caseSensitive: false).hasMatch(qtyMatch.group(0)!);
        } else {
          final kgUnitMatch = RegExp(r'\b(\d+(?:[.,]\d+)?)\s*kg\b', caseSensitive: false).firstMatch(line);
          if (kgUnitMatch != null && !rawName.toLowerCase().contains(kgUnitMatch.group(0)!.toLowerCase())) {
            isKg = true;
          }
        }

        // Extrai código de barras antes de limpar os prefixos numéricos
        final extractedBarcode = extractValidBarcode(rawName) ?? extractValidBarcode(line);

        // Limpeza do nome do produto
        final cleanName = _cleanProductName(rawName);

        if (cleanName.length >= 2 && unitPrice > 0 && !_isIgnoredKeyword(cleanName)) {
          // Capitaliza a primeira letra e formata
          final formattedName = cleanName[0].toUpperCase() + cleanName.substring(1).toLowerCase();

          items.add(Item(
            name: formattedName,
            quantity: quantity,
            unitPrice: unitPrice,
            isKg: isKg,
            category: ItemProvider.suggestCategoryForName(formattedName),
            isBought: true,
            barcode: extractedBarcode,
          ));
        }
      }

      i++;
    }

    final finalItems = storeName != null && storeName.isNotEmpty
        ? items.map((it) => it.copyWith(supermarket: storeName)).toList()
        : items;

    return ReceiptParseResult(
      storeName: storeName,
      cnpj: cnpj,
      nfcKey: nfcKey,
      uf: uf,
      items: finalItems,
    );
  }

  /// Tenta extrair o nome do supermercado/estabelecimento do cabeçalho da nota
  static String? extractStoreName(String text) {
    final rawLines = text.split('\n');
    final addressPrefixes = RegExp(r'^(rua|av\.|avenida|rod\.|rodovia|travessa|alameda|estrada|praca|praça|cep|bairro)\b', caseSensitive: false);

    for (int i = 0; i < rawLines.length && i < 7; i++) {
      final line = rawLines[i].trim();
      if (line.isEmpty) continue;

      final lower = line.toLowerCase();
      // Ignora termos fiscais genéricos de cabeçalho
      if (lower.contains('documento auxiliar') ||
          lower.contains('danfe') ||
          lower.contains('nfc-e') ||
          lower.contains('sat -') ||
          lower.contains('extrato') ||
          lower.contains('cupom fiscal') ||
          lower.startsWith('cnpj') ||
          lower.startsWith('ie:') ||
          addressPrefixes.hasMatch(lower)) {
        continue;
      }

      // Limpeza de caracteres estranhos do OCR
      final cleaned = line.replaceAll(RegExp(r'[^a-zA-Z0-9À-ÿ\s.\-&]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleaned.length >= 3 && cleaned.length <= 50 && RegExp(r'[a-zA-Z]').hasMatch(cleaned)) {
        // Formata nome do estabelecimento: primeiras letras maiúsculas
        return cleaned.split(' ').map((w) {
          if (w.isEmpty) return '';
          if (w.length <= 2 && ['de', 'da', 'do', 'em', 'e'].contains(w.toLowerCase())) {
            return w.toLowerCase();
          }
          return w[0].toUpperCase() + w.substring(1).toLowerCase();
        }).join(' ');
      }
    }
    return null;
  }

  /// Extrai o CNPJ formatado caso presente no texto
  static String? extractCnpj(String text) {
    final match = RegExp(r'\b(\d{2})[.\s]?(\d{3})[.\s]?(\d{3})[/\s]?(\d{4})[-\s]?(\d{2})\b').firstMatch(text);
    if (match != null) {
      return '${match.group(1)}.${match.group(2)}.${match.group(3)}/${match.group(4)}-${match.group(5)}';
    }
    return null;
  }

  /// Extrai a chave de acesso da NFC-e (44 dígitos numéricos)
  static String? extractNfcKey(String text) {
    // Procura chave contínua ou com espaços
    final match = RegExp(r'\b(?:\d{4}\s*){11}\b').firstMatch(text);
    if (match != null) {
      final digits = match.group(0)!.replaceAll(RegExp(r'\s+'), '');
      if (digits.length == 44) return digits;
    }

    final paramMatch = RegExp(r'(?:chNFe|p)=([0-9]{44})', caseSensitive: false).firstMatch(text);
    if (paramMatch != null) {
      return paramMatch.group(1);
    }

    return null;
  }

  /// Analisa uma URL originária de QR Code de NFC-e de qualquer SEFAZ estadual
  static ReceiptParseResult parseNfcUrl(String rawUrl) {
    String? nfcKey;

    // Padrão 1: Parâmetro p=... (geralmente SEFAZ MG, SP, etc. p=CHAVE|VERSAO|...)
    final pMatch = RegExp(r'[?&]p=([0-9]{44})', caseSensitive: false).firstMatch(rawUrl);
    if (pMatch != null) {
      nfcKey = pMatch.group(1);
    } else {
      // Padrão 2: Parâmetro chNFe=...
      final chMatch = RegExp(r'[?&]chNFe=([0-9]{44})', caseSensitive: false).firstMatch(rawUrl);
      if (chMatch != null) {
        nfcKey = chMatch.group(1);
      } else {
        // Padrão 3: 44 dígitos soltos na URL
        final rawDigits = RegExp(r'\b([0-9]{44})\b').firstMatch(rawUrl);
        if (rawDigits != null) {
          nfcKey = rawDigits.group(1);
        }
      }
    }

    String? cnpj;
    String? uf;

    if (nfcKey != null && nfcKey.length == 44) {
      final cUf = nfcKey.substring(0, 2);
      uf = _ufCodes[cUf];
      final rawCnpj = nfcKey.substring(6, 20);
      cnpj = formatCnpj(rawCnpj);
    }

    return ReceiptParseResult(
      nfcKey: nfcKey,
      cnpj: cnpj,
      uf: uf,
      items: const [],
    );
  }

  /// Formata uma sequência de 14 dígitos como CNPJ
  static String formatCnpj(String cnpj) {
    final digits = cnpj.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 14) return cnpj;
    return '${digits.substring(0, 2)}.${digits.substring(2, 5)}.${digits.substring(5, 8)}/${digits.substring(8, 12)}-${digits.substring(12, 14)}';
  }

  /// Extrai um código de barras GTIN/EAN válido (8, 12, 13 ou 14 dígitos) de um texto bruto.
  static String? extractValidBarcode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final matches = RegExp(r'(?<!\d)(\d{8}|\d{12,14})(?!\d)').allMatches(raw);
    for (final m in matches) {
      final digits = m.group(1)!;
      if (RegExp(r'^0+$').hasMatch(digits)) continue;
      // Normaliza GTIN-14 com zero à esquerda para EAN-13 quando válido
      if (digits.length == 14 && digits.startsWith('0')) {
        final ean13 = digits.substring(1);
        if (_isValidEan13CheckDigit(ean13)) {
          return ean13;
        }
      }
      return digits;
    }
    return null;
  }

  static bool _isValidEan13CheckDigit(String ean13) {
    if (ean13.length != 13) return false;
    int sum = 0;
    for (int i = 0; i < 12; i++) {
      final d = int.tryParse(ean13[i]);
      if (d == null) return false;
      sum += (i % 2 == 0) ? d : d * 3;
    }
    final check = (10 - (sum % 10)) % 10;
    return check == int.tryParse(ean13[12]);
  }

  /// Limpa códigos de barras, prefixos numéricos e lixos do OCR no nome do produto
  static String _cleanProductName(String rawName) {
    var name = rawName;

    // Remove códigos numéricos do início (ex: "001 789123456 Sabonete" -> "Sabonete")
    name = name.replaceFirst(RegExp(r'^\d{2,}\s+'), '');
    name = name.replaceFirst(RegExp(r'^\d{2,}\s+'), ''); // repete caso haja item + codigo de barras

    // Remove códigos de barras EAN/GTIN isolados em qualquer posição
    name = name.replaceAll(RegExp(r'(?<!\d)(\d{8}|\d{12,14})(?!\d)'), ' ');

    // Remove padrões como "1 UN X 29,90", "1 UN X", "2 CX * 5,00", "0,5 KG X"
    name = name.replaceAll(
      RegExp(r'\b\d+(?:[.,]\d+)?\s*(?:un|cx|pc|kg|lt|pct)?\s*[xX*]\s*(?:\d+[.,]\d{2})?\s*', caseSensitive: false),
      '',
    );

    // Remove caracteres especiais irrelevantes, mantendo letras, acentos e dígitos úteis (ex: 500g, 1L)
    name = name.replaceAll(RegExp(r'[^a-zA-Z0-9À-ÿ\s-]'), ' ');

    // Normaliza múltiplos espaços
    name = name.replaceAll(RegExp(r'\s+'), ' ').trim();

    return name;
  }

  static bool _isOnlyQuantityOrShort(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= 2) return true;
    final qtyOnlyPattern = RegExp(
      r'^(?:\d+(?:[.,]\d+)?\s*(?:un|cx|pc|kg|lt|pct)?\s*[xX*]\s*)?(?:\d+[.,]\d{2})?\s*$',
      caseSensitive: false,
    );
    return qtyOnlyPattern.hasMatch(trimmed);
  }

  static bool _isIgnoredLine(String line) {
    final lower = line.toLowerCase();
    for (final kw in _ignoredKeywords) {
      if (lower.startsWith(kw) || lower.contains(' $kw') || lower.contains('$kw ')) {
        return true;
      }
    }
    return false;
  }

  static bool _isIgnoredKeyword(String name) {
    final lower = name.toLowerCase();
    for (final kw in _ignoredKeywords) {
      if (lower == kw || lower.startsWith('$kw ') || lower.endsWith(' $kw')) {
        return true;
      }
    }
    return false;
  }
}
