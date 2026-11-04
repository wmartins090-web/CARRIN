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
  /// Ex: "A PARTIR DE 3 UN", "LEVE 6 OU MAIS", "A PARTIR DE 12", "CX C/ 24", "3+ UN"
  static final RegExp _wholesaleQtyRegex = RegExp(
    r'(?:a\s*partir\s*de|leve|acima\s*de|cx\s*c\/|caixa\s*c\/|minimo\s*de)\s*(\d{1,3})|(\d{1,3})\s*(?:\+|\s*unidades?|\s*unids?|\s*un\b|\s*pecas?|\s*pc\b|\s*cx\b|\s*latas?|\s*pct\b)',
    caseSensitive: false,
  );

  /// Regex para código de barras EAN-13 / EAN-8
  static final RegExp _barcodeRegex = RegExp(r'\b(789\d{10}|790\d{10}|\d{13}|\d{8})\b');

  /// Analisa o texto bruto extraído via OCR de uma etiqueta de gôndola
  static ShelfTagResult parse(String rawText) {
    if (rawText.trim().isEmpty) {
      return const ShelfTagResult(rawText: '');
    }

    final lines = rawText
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    String? detectedBarcode;
    String? detectedProductName;
    final List<double> extractedValues = [];
    final Map<double, int?> priceToMinQty = {};
    final Map<double, bool> priceIsWholesale = {};

    // 1. Procura código de barras em todas as linhas
    for (final line in lines) {
      final bcMatch = _barcodeRegex.firstMatch(line);
      if (bcMatch != null && detectedBarcode == null) {
        detectedBarcode = bcMatch.group(1);
      }
    }

    // 2. Extrai linhas de texto e identifica potenciais nomes de produto
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lineLower = line.toLowerCase();

      // Ignora linhas que são só metadados fiscais ou código de barras
      if (_barcodeRegex.hasMatch(line) && line.replaceAll(RegExp(r'\D'), '').length >= 8) {
        continue;
      }
      if (lineLower.contains('validade') ||
          lineLower.contains('lote') ||
          lineLower.contains('fabricacao') ||
          lineLower.contains('cod.') ||
          lineLower.contains('plu') ||
          lineLower.contains('trib') ||
          lineLower.contains('ncm')) {
        continue;
      }

      // Se for uma linha com texto alfabético expressivo e sem preço, pode ser o nome do produto
      final hasPriceInLine = _priceRegex.hasMatch(line);
      if (!hasPriceInLine && detectedProductName == null && line.length >= 4) {
        final lettersCount = line.replaceAll(RegExp(r'[^a-zA-ZáéíóúâêîôûãõçÁÉÍÓÚÂÊÎÔÛÃÕÇ]'), '').length;
        if (lettersCount >= 4) {
          detectedProductName = _cleanProductName(line);
        }
      }
    }

    // 3. Procura preços e seus contextos (Atacado vs Varejo)
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lineLower = line.toLowerCase();
      final prevLineLower = (i > 0) ? lines[i - 1].toLowerCase() : '';
      final nextLineLower = (i + 1 < lines.length) ? lines[i + 1].toLowerCase() : '';

      final matches = _priceRegex.allMatches(line);
      for (final match in matches) {
        final valStr = match.group(1)?.replaceAll(',', '.');
        if (valStr == null) continue;
        final val = double.tryParse(valStr);
        if (val == null || val <= 0 || val > 10000) continue;

        // Evita duplicar se já foi adicionado
        if (!extractedValues.contains(val)) {
          extractedValues.add(val);
        }

        // Checa se a linha atual, anterior ou próxima indica atacado
        final combinedContext = '$prevLineLower $lineLower $nextLineLower';
        final isWholesaleIndicator = combinedContext.contains('atacado') ||
            combinedContext.contains('a partir de') ||
            combinedContext.contains('leve') ||
            combinedContext.contains('ou mais') ||
            combinedContext.contains('cada a partir') ||
            combinedContext.contains('cx c/') ||
            combinedContext.contains('caixa c/');

        if (isWholesaleIndicator) {
          priceIsWholesale[val] = true;
          // Tenta extrair a quantidade mínima de atacado
          final qtyMatch = _wholesaleQtyRegex.firstMatch(combinedContext);
          if (qtyMatch != null) {
            final rawNum = qtyMatch.group(1) ?? qtyMatch.group(2) ?? '';
            final q = int.tryParse(rawNum);
            if (q != null && q >= 2 && q <= 999) {
              priceToMinQty[val] = q;
            }
          }
        } else if (combinedContext.contains('varejo') || combinedContext.contains('unidade') || combinedContext.contains('unitario')) {
          priceIsWholesale[val] = false;
        }
      }
    }

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
      // Apenas um preço detectado
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
      // Múltiplos preços detectados (Cenário Atacado x Varejo clássico)
      // No Brasil, em etiquetas de atacarejo, o menor valor é o de atacado e o maior é o de varejo
      final lowerPrice = extractedValues.first;
      final higherPrice = extractedValues.last;

      final minQ = priceToMinQty[lowerPrice] ?? 3; // Padrão inteligente se não detectado: 3 un

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

      // Adiciona outros preços intermediários se houver (ex: clube fidelidade / cartão da loja)
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

  static String _cleanProductName(String raw) {
    var clean = raw.trim();
    // Remove códigos numéricos no início
    clean = clean.replaceFirst(RegExp(r'^[0-9\-\.\s]+'), '');
    return clean.trim();
  }
}
