import 'utils.dart';

/// Representa uma opção de preço identificada na etiqueta de gôndola
class ShelfTagPrice {
  final double price;
  final String label; // ex: 'Varejo' ou 'Atacado'
  final int? minQuantity; // ex: 3, 6, 12
  final String description; // ex: 'Preço unitário' ou 'A partir de 3 unidades'
  final bool isWholesale;

  const ShelfTagPrice({
    required this.price,
    required this.label,
    this.minQuantity,
    required this.description,
    this.isWholesale = false,
  });

  String get formattedPrice => Utils.formatCurrency(price);
}

/// Resultado completo da análise de uma etiqueta de gôndola
class ShelfTagResult {
  final String? productName;
  final String? barcode;
  final ShelfTagPrice? retailPrice; // Preço de Varejo
  final ShelfTagPrice? wholesalePrice; // Preço de Atacado
  final List<ShelfTagPrice> allPrices;
  final String rawText;

  const ShelfTagResult({
    this.productName,
    this.barcode,
    this.retailPrice,
    this.wholesalePrice,
    this.allPrices = const [],
    required this.rawText,
  });

  bool get hasMultiplePrices => retailPrice != null && wholesalePrice != null;
  bool get hasAnyPrice => allPrices.isNotEmpty;

  /// Economia por unidade ao comprar no atacado
  double? get unitSavings {
    if (retailPrice != null && wholesalePrice != null && retailPrice!.price > wholesalePrice!.price) {
      return retailPrice!.price - wholesalePrice!.price;
    }
    return null;
  }

  /// Percentual de desconto do atacado em relação ao varejo
  double? get discountPercentage {
    final savings = unitSavings;
    if (savings != null && retailPrice != null && retailPrice!.price > 0) {
      return (savings / retailPrice!.price) * 100.0;
    }
    return null;
  }
}

/// Analisador inteligente de texto OCR de Etiquetas de Gôndola (Supermercados e Atacarejos)
class ShelfTagParser {
  ShelfTagParser._();

  /// Regex para capturar valores monetários brasileiros (ex: R$ 12,99, 12,99, R$ 12.99, 12.99)
  static final RegExp _priceRegex = RegExp(
    r'(?:R\$\s*)?(\d{1,4}(?:[.,]\d{2}))(?!\d)',
    caseSensitive: false,
  );

  /// Regex para capturar quantidades mínimas de atacado
  static final RegExp _wholesaleQtyRegex = RegExp(
    r'(?:a\s*partir\s*de|leve|acima\s*de|cx\s*c\/|caixa\s*c\/|fardo\s*c\/|minimo\s*de|min\.?)\s*(\d{1,3})|(\d{1,3})\s*(?:\+|\s*unidades?|\s*unids?|\s*un\b|\s*pecas?|\s*pc\b|\s*cx\b|\s*latas?|\s*pct\b)',
    caseSensitive: false,
  );

  /// Regex para código de barras EAN-13 / GTIN-14 / UPC-A / EAN-8
  static final RegExp _barcodeRegex = RegExp(r'(?<!\d)(789\d{10}|790\d{10}|\d{14}|\d{13}|\d{12}|\d{8})(?!\d)');

  static final RegExp _dateRegex = RegExp(r'\b\d{1,2}[./]\d{1,2}(?:[./]\d{2,4})?\b');

  static final RegExp _currencyPrefixRegex = RegExp(
    r'(?:R\s*[\$5S]|\$)\s*$',
    caseSensitive: false,
  );

  static final RegExp _measurementAfterRegex = RegExp(
    r'^\s*(?:kg|quilos?|kilos?|g|gr|gramas?|mg|mcg|ml|lt?s?|litros?|kcal|kj|cm|mm|m|%)\b',
    caseSensitive: false,
  );

  static final RegExp _referenceClauseBeforeRegex = RegExp(
    r'(?:(?:preco|preço|valor|vr\.?)\s*(?:por|p\/)|(?:por|p\/)\s*(?:cada)?\s*)(?:100\s*[gm]l?|kg|quilo|kilo|litro|lt|unid\.?\s*medida)|(?:100\s*[gm]l?|litro|quilo|por\s*kg)\s*[:\-]\s*$',
    caseSensitive: false,
  );

  static final RegExp _referenceClauseAfterRegex = RegExp(
    r'^\s*(?:\/|p\/|por)\s*(?:100\s*[gm]l?|kg|quilo|kilo|litro|lt)\b',
    caseSensitive: false,
  );

  static final RegExp _savingsClauseBeforeRegex = RegExp(
    r'\b(?:economize|economia|desconto|poupe|parcela(?:s|do)?|\d+\s*x)\s*(?:de|ate|até)?\s*$',
    caseSensitive: false,
  );

  static const Set<String> _boilerplateTokens = {
    'varejo',
    'atacado',
    'atacarejo',
    'oferta',
    'ofertas',
    'promocao',
    'superoferta',
    'preco',
    'valor',
    'unitario',
    'unidade',
    'unidades',
    'unid',
    'cada',
    'partir',
    'leve',
    'mais',
    'menos',
    'pague',
    'cartao',
    'clube',
    'fidelidade',
    'app',
    'economize',
    'economia',
    'desconto',
    'off',
    'especial',
    'por',
    'kg',
    'quilo',
    'litro',
    'valido',
    'validade',
    'vigencia',
    'ate',
    'hoje',
    'apenas',
    'supermercado',
    'mercado',
    'hipermercado',
    'atacadao',
    'assai',
    'carrefour',
    'guanabara',
    'mundial',
    'tenda',
    'roldao',
    'maxxi',
    'zaffari',
    'angeloni',
    'condor',
    'ltda',
    'sa',
    'cnpj',
    'ncm',
    'lote',
    'fabricacao',
    'tributos',
    'aprox',
    'de',
    'da',
    'do',
    'das',
    'dos',
    'para',
    'com',
    'sem',
    'em',
    'no',
    'na',
    'nos',
    'nas',
    'ao',
    'aos',
    'ou',
    'e',
    'a',
    'o',
    'cod',
    'codigo',
    'plu',
    'sku',
    'ref',
    'un',
  };

  /// Pré-processa as linhas OCR para corrigir erros comuns (R$ separado, centavos separados, espaços)
  static List<String> _preprocessLines(String rawText) {
    final initial = rawText
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim().replaceAll(RegExp(r'\s+'), ' '))
        .where((l) => l.isNotEmpty)
        .toList();

    final normalized = initial.map((line) {
      var l = line.replaceAllMapped(
        RegExp(r'(?<![A-Za-z0-9])R\s*[\$5S]\s*(?=\d)', caseSensitive: false),
        (_) => 'R\$ ',
      );
      // Converte "R$ 12 99" (centavos sobrescritos lidos com espaço) em "R$ 12,99"
      l = l.replaceAllMapped(
        RegExp(r'(R\$\s*)(\d{1,4})\s+(\d{2})(?!\d|[.,/])', caseSensitive: false),
        (m) => '${m.group(1)}${m.group(2)},${m.group(3)}',
      );
      // Remove espaços extras ao redor da vírgula/ponto decimal ("12 , 99" -> "12,99")
      l = l.replaceAllMapped(
        RegExp(r'(?<!\d)(\d{1,4})\s*([.,])\s*(\d{2})(?!\d|\s*[.,/]\d)'),
        (m) => '${m.group(1)}${m.group(2)}${m.group(3)}',
      );
      return l;
    }).toList();

    // Passo 1: Junta "12" (ou "R$ 12") + ",99" quebrados entre duas linhas
    final List<String> decimalMerged = [];
    for (int i = 0; i < normalized.length; i++) {
      final curr = normalized[i];
      if (i + 1 < normalized.length) {
        final next = normalized[i + 1];
        if (RegExp(r'(?:^|\s)(?:R\$\s*)?\d{1,4}$', caseSensitive: false).hasMatch(curr) &&
            RegExp(r'^[.,]\d{2}\b').hasMatch(next)) {
          decimalMerged.add('$curr${next.trim()}');
          i++;
          continue;
        }
      }
      decimalMerged.add(curr);
    }

    // Passo 2: Junta "R$" isolado numa linha com o preço na próxima (ou "R$ 12" + "99")
    final List<String> merged = [];
    for (int i = 0; i < decimalMerged.length; i++) {
      final curr = decimalMerged[i];
      if (i + 1 < decimalMerged.length) {
        final next = decimalMerged[i + 1];
        if (RegExp(r'^(?:R\s*[\$5S]|\$)$', caseSensitive: false).hasMatch(curr) &&
            RegExp(r'^\d{1,4}(?:[.,]\d{2})?').hasMatch(next)) {
          var joinedNext = next.replaceFirstMapped(
            RegExp(r'^(\d{1,4})\s+(\d{2})(?!\d)'),
            (m) => '${m.group(1)},${m.group(2)}',
          );
          merged.add('R\$ $joinedNext');
          i++;
          continue;
        }
        if (RegExp(r'(?:^|\s)R\$\s*\d{1,4}$', caseSensitive: false).hasMatch(curr) &&
            RegExp(r'^\d{2}$').hasMatch(next)) {
          merged.add('$curr,${next.trim()}');
          i++;
          continue;
        }
      }
      merged.add(curr);
    }

    return merged;
  }

  /// Analisa o texto bruto extraído via OCR de uma etiqueta de gôndola.
  /// Quando [requirePriceContext] é true (captura automática via scanner de barras),
  /// exige indício de moeda (`R$`) ou palavra-chave de gôndola para evitar falsos positivos em embalagens.
  static ShelfTagResult parse(String rawText, {bool requirePriceContext = false}) {
    if (rawText.trim().isEmpty) {
      return const ShelfTagResult(rawText: '');
    }

    final lines = _preprocessLines(rawText);
    if (lines.isEmpty) {
      return ShelfTagResult(rawText: rawText);
    }

    String? detectedBarcode;

    // 1. Procura código de barras priorizando EAN-13/GTIN real sobre códigos internos (COD/PLU)
    int bestBcScore = -1;
    for (final line in lines) {
      final cleanLineForBc = line.replaceAll(RegExp(r'(?<=\d)\s+(?=\d)'), '');
      for (final m in _barcodeRegex.allMatches(line)) {
        final digits = m.group(1)!;
        if (RegExp(r'^0+$').hasMatch(digits)) continue;
        final before = line.substring(0, m.start).toLowerCase();
        final int score = _scoreBarcodeCandidate(digits, before);
        if (score > bestBcScore) {
          bestBcScore = score;
          detectedBarcode = digits;
        }
      }
      if (bestBcScore < 80) {
        for (final m in _barcodeRegex.allMatches(cleanLineForBc)) {
          final digits = m.group(1)!;
          if (RegExp(r'^0+$').hasMatch(digits)) continue;
          if (digits.length >= 12 || digits.startsWith('789') || digits.startsWith('790')) {
            final int score = _scoreBarcodeCandidate(digits, line.toLowerCase());
            if (score > bestBcScore) {
              bestBcScore = score;
              detectedBarcode = digits;
            }
          }
        }
      }
    }

    // 2. Procura preços e seus contextos (Varejo vs Atacado, filtrando preços de referência por Kg/Litro)
    final List<double> primaryValues = [];
    final List<double> referenceValues = [];
    final Map<double, int?> priceToMinQty = {};
    final Map<double, bool> priceIsWholesale = {};
    final Set<int> priceLineIndexes = {};

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lineLower = line.toLowerCase();
      final prevLineLower = (i > 0) ? lines[i - 1].toLowerCase() : '';
      final nextLineLower = (i + 1 < lines.length) ? lines[i + 1].toLowerCase() : '';
      final combinedContext = '$prevLineLower $lineLower $nextLineLower';

      // Mascara datas (ex: 17/11/2026 ou 17.11) para não confundir com preços
      final maskedLine = line.replaceAllMapped(_dateRegex, (m) => ' ' * m.group(0)!.length);

      final matches = _priceRegex.allMatches(maskedLine);
      for (final match in matches) {
        final fullStr = match.group(0) ?? '';
        final valStr = match.group(1)?.replaceAll(',', '.');
        if (valStr == null) continue;
        final val = double.tryParse(valStr);
        if (val == null || val <= 0 || val > 10000) continue;

        final before = maskedLine.substring(0, match.start);
        final after = maskedLine.substring(match.end);
        final bool hasExplicitCurrency =
            fullStr.contains('\$') || _currencyPrefixRegex.hasMatch(before);

        // Ignora pesos/medidas com decimais sem símbolo de moeda (ex: "1.50L", "0.50KG", "12,50%")
        if (!hasExplicitCurrency && _measurementAfterRegex.hasMatch(after)) {
          continue;
        }

        // Ignora descontos/economia/parcelas
        if (_savingsClauseBeforeRegex.hasMatch(before)) {
          continue;
        }

        final bool hasShelfKeyword = combinedContext.contains('varejo') ||
            combinedContext.contains('atacado') ||
            combinedContext.contains('atacarejo') ||
            combinedContext.contains('oferta') ||
            combinedContext.contains('promoc') ||
            combinedContext.contains('a partir') ||
            combinedContext.contains('leve') ||
            combinedContext.contains('cada') ||
            combinedContext.contains('unid') ||
            combinedContext.contains('clube') ||
            combinedContext.contains('cartao') ||
            combinedContext.contains('fidelidade') ||
            combinedContext.contains('preco') ||
            combinedContext.contains('preço');

        if (requirePriceContext && !hasExplicitCurrency && !hasShelfKeyword) {
          continue;
        }

        // Verifica se é preço comparativo de unidade (ex: "PRECO P/ KG: R$ 5,98" ou "100G: R$ 2,50")
        final clauseWindowStart = (before.length - 36).clamp(0, before.length);
        final localClauseBefore = before.substring(clauseWindowStart);
        final bool isReferenceUnitPrice = _referenceClauseBeforeRegex.hasMatch(localClauseBefore) ||
            _referenceClauseAfterRegex.hasMatch(after) ||
            (prevLineLower.contains('preco p/') ||
                prevLineLower.contains('preco por') ||
                prevLineLower.contains('preço por') ||
                prevLineLower.contains('por 100g') ||
                prevLineLower.contains('por 100ml'));

        if (isReferenceUnitPrice) {
          if (!referenceValues.contains(val)) {
            referenceValues.add(val);
          }
          continue;
        }

        priceLineIndexes.add(i);
        if (!primaryValues.contains(val)) {
          primaryValues.add(val);
        }

        final bool isWholesaleIndicator = combinedContext.contains('atacado') ||
            combinedContext.contains('atacarejo') ||
            combinedContext.contains('a partir de') ||
            combinedContext.contains('leve') ||
            combinedContext.contains('ou mais') ||
            combinedContext.contains('cada a partir') ||
            combinedContext.contains('cx c/') ||
            combinedContext.contains('caixa c/') ||
            combinedContext.contains('fardo');

        if (isWholesaleIndicator) {
          priceIsWholesale[val] = true;
          final qtyMatch = _wholesaleQtyRegex.firstMatch(combinedContext);
          if (qtyMatch != null) {
            final rawNum = qtyMatch.group(1) ?? qtyMatch.group(2) ?? '';
            final q = int.tryParse(rawNum);
            if (q != null && q >= 2 && q <= 999) {
              priceToMinQty[val] = q;
            }
          }
        } else if (combinedContext.contains('varejo') ||
            combinedContext.contains('unidade') ||
            combinedContext.contains('unitario') ||
            combinedContext.contains('unitário')) {
          priceIsWholesale[val] = false;
        }
      }
    }

    final List<double> extractedValues = primaryValues.isNotEmpty
        ? List<double>.from(primaryValues)
        : (requirePriceContext ? <double>[] : List<double>.from(referenceValues));

    // 3. Seleciona inteligentemente o nome do produto entre as linhas da etiqueta
    final String? detectedProductName = _extractBestProductName(lines, priceLineIndexes);

    if (extractedValues.isEmpty) {
      return ShelfTagResult(
        productName: detectedProductName,
        barcode: detectedBarcode,
        rawText: rawText,
      );
    }

    // Ordena os valores identificados
    extractedValues.sort();

    ShelfTagPrice? retail;
    ShelfTagPrice? wholesale;
    final List<ShelfTagPrice> allPrices = [];

    if (extractedValues.length == 1) {
      final p = extractedValues.first;
      final isWs = priceIsWholesale[p] ?? false;
      final minQ = priceToMinQty[p];
      final item = ShelfTagPrice(
        price: p,
        label: isWs ? 'Atacado' : 'Varejo',
        minQuantity: minQ ?? 1,
        description: isWs && minQ != null ? 'A partir de $minQ unidades' : 'Preço unitário',
        isWholesale: isWs,
      );
      retail = isWs ? null : item;
      wholesale = isWs ? item : null;
      allPrices.add(item);
    } else {
      // No Brasil, em etiquetas de atacarejo, o menor valor é o de atacado/oferta e o maior é o de varejo
      final lowerPrice = extractedValues.first;
      final higherPrice = extractedValues.last;

      final minQ = priceToMinQty[lowerPrice] ?? 3;

      retail = ShelfTagPrice(
        price: higherPrice,
        label: 'Varejo',
        minQuantity: 1,
        description: 'Preço unitário padrão',
        isWholesale: false,
      );

      wholesale = ShelfTagPrice(
        price: lowerPrice,
        label: 'Atacado',
        minQuantity: minQ,
        description: 'A partir de $minQ unidades',
        isWholesale: true,
      );

      allPrices.add(retail);
      allPrices.add(wholesale);

      for (final p in extractedValues) {
        if (p != lowerPrice && p != higherPrice) {
          allPrices.add(ShelfTagPrice(
            price: p,
            label: 'Oferta Especial',
            description: 'Preço promocional ou clube',
            isWholesale: false,
          ));
        }
      }
    }

    return ShelfTagResult(
      productName: detectedProductName,
      barcode: detectedBarcode,
      retailPrice: retail,
      wholesalePrice: wholesale,
      allPrices: allPrices,
      rawText: rawText,
    );
  }

  static String? _extractBestProductName(List<String> lines, Set<int> priceLineIndexes) {
    final List<({int index, String text, double score, bool cleanLine})> candidates = [];

    for (int i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final lower = raw.toLowerCase();

      // Ignora linhas puramente de metadados fiscais/validade ou preço por unidade de medida
      if (lower.contains('validade') ||
          lower.contains('valido de') ||
          lower.contains('válido de') ||
          lower.contains('vigencia') ||
          lower.contains('vigência') ||
          lower.contains('fabricacao') ||
          lower.contains('fabricação') ||
          lower.contains('lote') ||
          lower.contains('tributos') ||
          lower.contains('ncm') ||
          lower.contains('preco p/') ||
          lower.contains('preco por') ||
          lower.contains('preço por') ||
          lower.contains('preco/kg')) {
        continue;
      }

      // Limpa códigos de barras, preços e prefixos de código interno para aproveitar nome na mesma linha
      var cleaned = raw;
      cleaned = cleaned.replaceAll(_barcodeRegex, ' ');
      cleaned = cleaned.replaceAll(RegExp(r'R\$\s*\d{1,4}(?:[.,]\d{2})?', caseSensitive: false), ' ');
      if (priceLineIndexes.contains(i)) {
        cleaned = cleaned.replaceAllMapped(_priceRegex, (m) {
          final after = cleaned.substring(m.end);
          if (!m.group(0)!.contains('\$') && _measurementAfterRegex.hasMatch(after)) {
            return m.group(0)!;
          }
          return ' ';
        });
      }
      cleaned = cleaned.replaceAll(
        RegExp(r'\b(?:preco\s*(?:de\s*)?)?(?:varejo|atacado|oferta|clube|cartao)\b[:\-]?', caseSensitive: false),
        ' ',
      );
      cleaned = _cleanProductName(cleaned);
      if (cleaned.length < 3) continue;

      final norm = Utils.normalize(cleaned);
      final tokens = norm.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      if (tokens.isEmpty) continue;

      final alphaTokens = tokens.where((t) => RegExp(r'[a-z]{2,}').hasMatch(t)).toList();
      if (alphaTokens.isEmpty) continue;

      // Rejeita se todos os tokens alfabéticos relevantes forem apenas palavras de cartaz/mercado
      final meaningfulTokens = alphaTokens.where((t) => !_boilerplateTokens.contains(t)).toList();
      if (meaningfulTokens.isEmpty) continue;

      final totalLetters = cleaned.replaceAll(RegExp(r'[^a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]'), '').length;
      if (totalLetters < 3) continue;

      double score = meaningfulTokens.length * 10.0 + totalLetters * 0.4;
      if (!priceLineIndexes.contains(i)) {
        score += 8.0;
      }
      // Bonus para descrições típicas com peso/volume/embalagem (ex: 5KG, 395G, 1L, 350ML, TP1)
      if (RegExp(r'\b\d+(?:[.,]\d+)?\s*(?:kg|g|ml|l|lt|un)\b', caseSensitive: false).hasMatch(cleaned)) {
        score += 12.0;
      }
      // Bonus moderado para linhas logo acima dos preços
      if (i <= 2) {
        score += 4.0;
      }
      // Penaliza linhas com cara de razão social
      if (norm.contains('ltda') || norm.contains('cnpj') || norm.contains('eireli')) {
        score -= 30.0;
      }

      if (score > 0) {
        candidates.add((
          index: i,
          text: cleaned,
          score: score,
          cleanLine: !priceLineIndexes.contains(i),
        ));
      }
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) => b.score.compareTo(a.score));
    final best = candidates.first;

    // Se a melhor linha limpa continuar imediatamente na próxima linha limpa (ex: marca + peso/volume),
    // junta as duas linhas quando faz sentido como um único título de produto.
    if (best.cleanLine) {
      final nextIdx = candidates.indexWhere(
        (c) => c.index == best.index + 1 && c.cleanLine && c.score >= 12.0,
      );
      if (nextIdx != -1) {
        final nextCand = candidates[nextIdx];
        final combined = '${best.text} ${nextCand.text}'.trim();
        if (combined.length <= 65 && Utils.normalize(best.text) != Utils.normalize(nextCand.text)) {
          return combined;
        }
      }
    }

    return best.text;
  }

  static int _scoreBarcodeCandidate(String digits, String beforeContextLower) {
    if ((digits.startsWith('789') || digits.startsWith('790')) && digits.length == 13) {
      return 100;
    }
    if (digits.length == 13 || digits.length == 14) {
      return 85;
    }
    if (digits.length == 12) {
      return 70;
    }
    final looksInternal = RegExp(r'(?:cod(?:igo)?\.?|plu|sku|ref\.?|int\.?)\s*[:\-]?\s*$').hasMatch(beforeContextLower) ||
        digits.startsWith('000');
    return looksInternal ? 15 : 50;
  }

  static String _cleanProductName(String raw) {
    var clean = raw.trim();
    clean = clean.replaceFirst(
      RegExp(r'^(?:COD(?:IGO)?\.?|PLU|SKU|REF\.?)(?=\s*[:\-\d]|\s*$)\s*[:\-]?\s*\d*\s*[-–:.]*\s*', caseSensitive: false),
      '',
    );
    // Remove códigos numéricos isolados no início ("0045123 - ARROZ" ou "12345 ARROZ")
    clean = clean.replaceFirst(RegExp(r'^\d{2,14}\s*[-–.:]*\s*'), '');
    clean = clean.replaceAll(RegExp(r'^[\s\-–:|/]+|[\s\-–:|/]+$'), '');
    clean = clean.replaceAll(RegExp(r'\s+'), ' ');
    return clean.trim();
  }
}
