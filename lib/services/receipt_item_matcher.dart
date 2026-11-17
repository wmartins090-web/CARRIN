import 'dart:math' as math;
import '../models/item.dart';
import 'utils.dart';

enum ReceiptMatchType {
  barcode,
  exactName,
  barcodeHistoryName,
  smartName,
  manual,
}

class ReceiptItemMatchResult {
  /// Maps receipt item position (0..N-1) -> matched index in cartItems.
  final Map<int, int> receiptToCartIndex;

  /// Match strategy used for each matched receipt item position.
  final Map<int, ReceiptMatchType> matchTypes;

  /// Receipt item positions that are additional lines for an already-matched cart item
  /// (same product appearing multiple times on the same receipt -> quantities should add).
  final Set<int> additionalLineReceiptIndexes;

  const ReceiptItemMatchResult({
    required this.receiptToCartIndex,
    required this.matchTypes,
    this.additionalLineReceiptIndexes = const {},
  });
}

class _ParsedProductTokens {
  final String canonicalString;
  final List<String> coreTokens;
  final Set<String> postPrepositionTokens;
  final String? headToken;
  final List<double> sizesInBaseUnit; // ml for volume, g for weight

  const _ParsedProductTokens({
    required this.canonicalString,
    required this.coreTokens,
    required this.postPrepositionTokens,
    required this.headToken,
    required this.sizesInBaseUnit,
  });
}

class _MatchCandidate {
  final int receiptIdx;
  final int cartIdx;
  final double score;
  final ReceiptMatchType type;

  const _MatchCandidate({
    required this.receiptIdx,
    required this.cartIdx,
    required this.score,
    required this.type,
  });
}

/// Intelligent matching engine for reconciling scanned receipt items (NFC-e / OCR)
/// against existing shopping list items using barcodes, exact names, abbreviations,
/// synonyms, and token similarity while guarding against false positives.
class ReceiptItemMatcher {
  ReceiptItemMatcher._();

  static const double _matchThreshold = 0.78;

  static const Set<String> _prepositions = {
    'de',
    'da',
    'do',
    'das',
    'dos',
    'com',
    'sem',
    'em',
    'para',
    'ao',
    'aos',
  };

  static const Set<String> _stopWords = {
    'a',
    'o',
    'as',
    'os',
    'e',
    'um',
    'uma',
    'un',
    'und',
    'unid',
    'unidade',
    'unidades',
    'pc',
    'pct',
    'pacote',
    'cx',
    'caixa',
    'fd',
    'fardo',
    'gf',
    'garrafa',
    'pet',
    'lata',
    'lt',
    'uht',
    'tp',
    'tp1',
    'tipo',
    'emb',
    'embalagem',
    'kg',
    'g',
    'gr',
    'mg',
    'l',
    'ml',
    'rolo',
    'rolos',
    'fl',
    'fls',
    'folha',
    'folhas',
  };

  static const Map<String, String> _tokenCanonicalMap = {
    // Spelling / phonetic variations
    'mucarela': 'mussarela',
    'mussarela': 'mussarela',
    'mozarela': 'mussarela',
    'mozzarella': 'mussarela',
    'muss': 'mussarela',
    'iogurte': 'iogurte',
    'yogurte': 'iogurte',
    'yogurt': 'iogurte',
    'iog': 'iogurte',
    'maionese': 'maionese',
    'mayonese': 'maionese',
    'xampu': 'shampoo',
    'shamp': 'shampoo',
    'bolacha': 'biscoito',
    'biscoit': 'biscoito',
    'bisc': 'biscoito',
    // Common Brazilian receipt abbreviations
    'refrig': 'refrigerante',
    'refr': 'refrigerante',
    'refri': 'refrigerante',
    'deterg': 'detergente',
    'det': 'detergente',
    'qjo': 'queijo',
    'qj': 'queijo',
    'marg': 'margarina',
    'mant': 'manteiga',
    'pres': 'presunto',
    'req': 'requeijao',
    'linguica': 'linguica',
    'ling': 'linguica',
    'acuc': 'acucar',
    'caf': 'cafe',
    'feij': 'feijao',
    'arr': 'arroz',
    'mac': 'macarrao',
    'espag': 'espaguete',
    'amac': 'amaciante',
    'desinf': 'desinfetante',
    'sanit': 'sanitaria',
    'hig': 'higienico',
    'condens': 'condensado',
    'condic': 'condicionador',
    'sabon': 'sabonete',
    'cr': 'creme',
    'dent': 'dental',
    'tom': 'tomate',
    'ext': 'extrato',
    'mol': 'molho',
    'integ': 'integral',
    'desnat': 'desnatado',
    'desn': 'desnatado',
    'semidesn': 'semidesnatado',
    'liq': 'liquido',
    'fat': 'fatiado',
    'moid': 'moida',
    'moido': 'moida',
    'bov': 'bovino',
    'bovina': 'bovino',
    'suin': 'suino',
    'suina': 'suino',
    'frang': 'frango',
    'fgo': 'frango',
    'choc': 'chocolate',
    'mor': 'morango',
    'trad': 'tradicional',
    'orig': 'original',
    'refin': 'refinado',
    'crist': 'cristal',
    'parb': 'parboilizado',
    'car': 'carioca',
    'pret': 'preto',
    'preta': 'preto',
    'branc': 'branco',
    'branca': 'branco',
    'lte': 'leite',
    'coz': 'cozido',
    'cozida': 'cozido',
    'ferm': 'fermentado',
    'desc': 'descascado',
    'alum': 'aluminio',
    'toal': 'toalha',
  };

  /// Compound transformer tokens that change the identity of a generic base noun
  /// (e.g. "Leite" vs "Leite Condensado", "Água" vs "Água Sanitária").
  static const Set<String> _compoundTransformers = {
    'condensado',
    'creme',
    'doce',
    'chantilly',
    'fermentado',
    'sanitaria',
    'dental',
    'higienico',
    'toalha',
    'aluminio',
    'filme',
    'alho',
    'ralado',
    'coco',
  };

  /// Head nouns that represent distinct product categories when appearing before
  /// an ingredient (e.g. "Molho de Tomate" != "Tomate", "Suco de Laranja" != "Laranja").
  static const Set<String> _distinctCompoundHeadNouns = {
    'molho',
    'extrato',
    'polpa',
    'doce',
    'creme',
    'suco',
    'refresco',
    'nectar',
    'pao',
    'bolo',
    'torta',
    'iogurte',
    'manteiga',
    'margarina',
    'tempero',
    'sabonete',
    'detergente',
    'amaciante',
    'desinfetante',
    'sorvete',
    'gelatina',
    'cha',
    'biscoito',
    'farinha',
    'oleo',
    'azeite',
    'vinagre',
    'queijo',
    'requeijao',
    'patê',
    'pate',
  };

  /// Generic product-type prefixes that stores often omit on receipts when the
  /// brand or specific type is unambiguous (e.g. "Queijo Muçarela" vs "Mussarela Fatiada").
  static const Set<String> _optionalTypePrefixes = {
    'queijo',
    'cerveja',
    'refrigerante',
    'sabonete',
    'shampoo',
    'condicionador',
    'desodorante',
  };

  /// Mutually exclusive qualifier groups: if item A has one member and item B
  /// has a different member of the same group (without sharing it), they don't match.
  static const List<Set<String>> _exclusiveQualifierGroups = [
    {'preto', 'carioca', 'branco', 'fradinho', 'vermelho', 'mulatinho'},
    {'integral', 'parboilizado'},
    {'integral', 'desnatado', 'semidesnatado'},
    {'soja', 'milho', 'canola', 'girassol', 'oliva', 'coco', 'algodao'},
    {'trigo', 'mandioca', 'milho', 'rosca', 'lactea', 'aveia'},
    {'forma', 'frances', 'alho', 'doce', 'bisnaguinha'},
    {
      'mussarela',
      'prato',
      'minas',
      'coalho',
      'cheddar',
      'parmesao',
      'provolone',
      'gorgonzola',
      'ricota',
      'cottage',
      'ralado',
    },
    {'higienico', 'toalha', 'aluminio', 'filme', 'manteiga'},
    {'po', 'barra', 'liquido'},
    {'coca', 'guarana', 'pepsi', 'fanta', 'sprite', 'sukita', 'kuat', 'soda'},
    {'uva', 'laranja', 'maca', 'manga', 'maracuja', 'pessego', 'goiaba', 'abacaxi', 'limao', 'caju', 'morango'},
    {'bovino', 'suino', 'frango', 'peixe', 'peru', 'calabresa'},
    {'refinado', 'cristal', 'demerara', 'mascavo', 'confeiteiro'},
  ];

  /// Compares two barcodes accounting for `.0` stripping and optional GTIN-14 leading zero padding.
  static bool barcodesMatch(String? a, String? b) {
    final cleanA = Item.parseBarcode(a);
    final cleanB = Item.parseBarcode(b);
    if (cleanA == null || cleanB == null) return false;
    if (cleanA == cleanB) return true;

    final strippedA = cleanA.replaceFirst(RegExp(r'^0+'), '');
    final strippedB = cleanB.replaceFirst(RegExp(r'^0+'), '');
    if (strippedA.length >= 7 && strippedA == strippedB) {
      return true;
    }
    return false;
  }

  /// Normalizes a product name for comparison while preserving unit expressions.
  static String canonicalizeName(String raw) {
    var norm = Utils.normalize(raw);
    if (norm.isEmpty) return '';

    // Expand Portuguese slash shorthands before stripping punctuation
    norm = norm
        .replaceAll(RegExp(r'\bc\s*/\s*', caseSensitive: false), ' com ')
        .replaceAll(RegExp(r'\bs\s*/\s*', caseSensitive: false), ' sem ')
        .replaceAll(RegExp(r'\bp\s*/\s*', caseSensitive: false), ' para ');

    // Normalize decimal numbers in weights/volumes: "1,5 l" -> "1.5l", "5 kg" -> "5kg"
    norm = norm.replaceAllMapped(
      RegExp(r'(\d+)[.,](\d+)\s*(kg|g|mg|l|lt|ml)\b'),
      (m) => '${m.group(1)}.${m.group(2)}${m.group(3)}',
    );
    norm = norm.replaceAllMapped(
      RegExp(r'\b(\d+)\s+(kg|g|mg|l|lt|ml)\b'),
      (m) => '${m.group(1)}${m.group(2)}',
    );

    // Replace remaining punctuation with spaces
    norm = norm.replaceAll(RegExp(r'[^a-z0-9.]'), ' ');
    norm = norm.replaceAll(RegExp(r'(?<!\d)\.|\.(?!\d)'), ' ');

    // Multi-word Brazilian product synonyms
    norm = norm
        .replaceAll(RegExp(r'\blava\s+roupas?\b'), 'sabao')
        .replaceAll(RegExp(r'\bpasta\s+(?:de\s+)?dente\b'), 'creme dental');

    norm = norm.replaceAll(RegExp(r'\s+'), ' ').trim();
    return norm;
  }

  static _ParsedProductTokens _parseTokens(String rawName) {
    final canonical = canonicalizeName(rawName);
    if (canonical.isEmpty) {
      return const _ParsedProductTokens(
        canonicalString: '',
        coreTokens: [],
        postPrepositionTokens: {},
        headToken: null,
        sizesInBaseUnit: [],
      );
    }

    final rawParts = canonical.split(' ');
    final List<String> coreTokens = [];
    final Set<String> postPrep = {};
    final List<double> sizes = [];
    bool sawPreposition = false;

    for (final part in rawParts) {
      if (part.isEmpty) continue;

      final sizeVal = _parseSizeInBaseUnit(part);
      if (sizeVal != null) {
        sizes.add(sizeVal);
        continue;
      }

      if (_prepositions.contains(part)) {
        sawPreposition = true;
        continue;
      }

      if (_stopWords.contains(part)) {
        continue;
      }

      // Skip standalone tiny quantity numbers like "1" or "12"
      if (RegExp(r'^\d+(?:\.\d+)?$').hasMatch(part)) {
        continue;
      }

      final mapped = _tokenCanonicalMap[part] ?? part;
      // Handle multi-word expansion like "pasta de dente" -> "creme dental"
      for (final sub in mapped.split(' ')) {
        if (sub.isEmpty) continue;
        coreTokens.add(sub);
        if (sawPreposition) {
          postPrep.add(sub);
        }
      }
    }

    return _ParsedProductTokens(
      canonicalString: canonical,
      coreTokens: coreTokens,
      postPrepositionTokens: postPrep,
      headToken: coreTokens.isNotEmpty ? coreTokens.first : null,
      sizesInBaseUnit: sizes,
    );
  }

  static double? _parseSizeInBaseUnit(String token) {
    final m = RegExp(r'^(\d+(?:\.\d+)?)(kg|g|mg|l|lt|ml)$').firstMatch(token);
    if (m == null) return null;
    final val = double.tryParse(m.group(1)!);
    if (val == null || val <= 0) return null;
    final unit = m.group(2)!;
    switch (unit) {
      case 'kg':
      case 'l':
      case 'lt':
        return val * 1000.0;
      case 'g':
      case 'ml':
        return val;
      case 'mg':
        return val / 1000.0;
      default:
        return null;
    }
  }

  static bool _hasIncompatibleSizes(List<double> sizesA, List<double> sizesB) {
    if (sizesA.isEmpty || sizesB.isEmpty) return false;
    for (final a in sizesA) {
      for (final b in sizesB) {
        final ratio = a > b ? a / b : b / a;
        if (ratio <= 1.5) {
          return false;
        }
      }
    }
    return true;
  }

  static bool _violatesGuards(_ParsedProductTokens a, _ParsedProductTokens b) {
    final setA = a.coreTokens.toSet();
    final setB = b.coreTokens.toSet();

    // 1. Compound-identity guard for single/generic noun items
    for (final transformer in _compoundTransformers) {
      final aHas = setA.contains(transformer);
      final bHas = setB.contains(transformer);
      if (aHas != bHas) {
        // If the item without the transformer only has 1-2 generic tokens
        // (e.g. "Leite", "Água", "Pão", "Queijo", "Papel", "Creme"), don't match compound form.
        final withoutTransformer = aHas ? setB : setA;
        if (withoutTransformer.length <= 2) {
          return true;
        }
      }
    }

    // 2. Mutually exclusive qualifier groups
    for (final group in _exclusiveQualifierGroups) {
      final inA = setA.intersection(group);
      final inB = setB.intersection(group);
      if (inA.isNotEmpty && inB.isNotEmpty && inA.intersection(inB).isEmpty) {
        return true;
      }
    }

    // 3. Incompatible explicit sizes (e.g. Coca-Cola 2L vs Coca-Cola 350ml)
    if (_hasIncompatibleSizes(a.sizesInBaseUnit, b.sizesInBaseUnit)) {
      return true;
    }

    return false;
  }

  static double _tokenSimilarity(String a, String b) {
    if (a == b) return 1.0;

    final shorter = a.length <= b.length ? a : b;
    final longer = a.length <= b.length ? b : a;

    // Prefix/abbreviation match (e.g. "muss" -> "mussarela", "condens" -> "condensado")
    if (shorter.length >= 3 && longer.startsWith(shorter)) {
      final lenRatio = shorter.length / longer.length;
      return lenRatio >= 0.45 ? 0.88 : 0.82;
    }

    // Levenshtein fuzzy match for longer words (handles OCR typos like "aroz", "sabonet")
    if (shorter.length >= 4 && longer.length >= 4) {
      final dist = _levenshtein(a, b);
      final maxLen = math.max(a.length, b.length);
      final sim = 1.0 - (dist / maxLen);
      if (sim >= 0.78) {
        return 0.82 * sim + 0.08;
      }
    }

    return 0.0;
  }

  static int _levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    List<int> v0 = List<int>.generate(t.length + 1, (i) => i);
    List<int> v1 = List<int>.filled(t.length + 1, 0);

    for (int i = 0; i < s.length; i++) {
      v1[0] = i + 1;
      for (int j = 0; j < t.length; j++) {
        final cost = s.codeUnitAt(i) == t.codeUnitAt(j) ? 0 : 1;
        v1[j + 1] = math.min(
          math.min(v1[j] + 1, v0[j + 1] + 1),
          v0[j] + cost,
        );
      }
      final tmp = v0;
      v0 = v1;
      v1 = tmp;
    }
    return v0[t.length];
  }

  /// Scores similarity between two product names in [0.0, 0.98].
  static double scoreNameMatch(String nameA, String nameB) {
    final parsedA = _parseTokens(nameA);
    final parsedB = _parseTokens(nameB);

    if (parsedA.canonicalString.isEmpty || parsedB.canonicalString.isEmpty) {
      return 0.0;
    }
    if (parsedA.canonicalString == parsedB.canonicalString) {
      return 0.98;
    }

    // Also equal after stopword/synonym normalization
    if (parsedA.coreTokens.isNotEmpty &&
        parsedA.coreTokens.join(' ') == parsedB.coreTokens.join(' ')) {
      return 0.96;
    }

    if (parsedA.coreTokens.isEmpty || parsedB.coreTokens.isEmpty) {
      return 0.0;
    }

    if (_violatesGuards(parsedA, parsedB)) {
      return 0.0;
    }

    final bool aIsSmaller = parsedA.coreTokens.length <= parsedB.coreTokens.length;
    final smaller = aIsSmaller ? parsedA : parsedB;
    final larger = aIsSmaller ? parsedB : parsedA;

    // Single-token head-noun & preposition protection
    if (smaller.coreTokens.length == 1) {
      final singleToken = smaller.coreTokens.first;
      // If larger starts with a distinct compound head noun (e.g. "Molho de Tomate", "Suco de Laranja")
      // and the single token is NOT that head noun, reject matching "Tomate" -> "Molho de Tomate".
      if (larger.headToken != null &&
          _distinctCompoundHeadNouns.contains(larger.headToken) &&
          _tokenSimilarity(singleToken, larger.headToken!) < 0.8) {
        return 0.0;
      }
      // Reject if the token only appears after a preposition (e.g. "Sal" in "Manteiga c/ Sal")
      if (larger.postPrepositionTokens.contains(singleToken) &&
          (larger.headToken == null || _tokenSimilarity(singleToken, larger.headToken!) < 0.8)) {
        return 0.0;
      }
    }

    // Compute greedy best 1-to-1 token match from smaller -> larger
    final usedLarger = <int>{};
    double matchedScoreSum = 0.0;
    int matchedCount = 0;
    bool headMatched = false;

    for (int i = 0; i < smaller.coreTokens.length; i++) {
      final tok = smaller.coreTokens[i];
      double bestSim = 0.0;
      int bestIdx = -1;

      for (int j = 0; j < larger.coreTokens.length; j++) {
        if (usedLarger.contains(j)) continue;
        final sim = _tokenSimilarity(tok, larger.coreTokens[j]);
        if (sim > bestSim) {
          bestSim = sim;
          bestIdx = j;
        }
      }

      if (bestSim >= 0.78 && bestIdx != -1) {
        usedLarger.add(bestIdx);
        matchedScoreSum += bestSim;
        matchedCount++;
        if (i == 0 || bestIdx == 0) {
          headMatched = true;
        }
      }
    }

    if (matchedCount == 0) return 0.0;

    final coverageSmall = matchedScoreSum / smaller.coreTokens.length;
    final coverageLarge = matchedScoreSum / larger.coreTokens.length;

    if (smaller.coreTokens.length == 1) {
      // Single-token item (e.g. "Arroz" vs "Arroz Tio Joao 5kg")
      if (coverageSmall < 0.84) return 0.0;
      // Ensure it matched at head or right after a generic container prefix (e.g. "Refrig Coca")
      final matchedIdx = usedLarger.first;
      if (matchedIdx > 1) return 0.0;
      return (0.76 + 0.14 * coverageSmall + 0.08 * coverageLarge).clamp(0.0, 0.95);
    }

    if (smaller.coreTokens.length == 2) {
      // Allow matching when token[0] is an optional category prefix ("Queijo Muçarela" vs "Mussarela Fatiada")
      // and token[1] is an exact non-post-preposition specific type/brand match in larger.
      const nonDistinctSecondTokens = {
        'ralado',
        'fatiado',
        'picado',
        'moida',
        'liquido',
        'po',
        'barra',
        'zero',
        'light',
        'diet',
        'integral',
        'tradicional',
        'original',
        'branco',
        'preto',
      };
      if (matchedCount == 1 &&
          _optionalTypePrefixes.contains(smaller.coreTokens[0]) &&
          !larger.coreTokens.contains(smaller.coreTokens[0])) {
        final secondTok = smaller.coreTokens[1];
        if (!nonDistinctSecondTokens.contains(secondTok) &&
            !larger.postPrepositionTokens.contains(secondTok) &&
            larger.coreTokens.any((t) => t == secondTok)) {
          return 0.84;
        }
      }
      // Require both tokens to match well (prevents "Molho de Tomate" matching "Molho Shoyu")
      if (matchedCount < 2 || coverageSmall < 0.80) return 0.0;
      return (0.78 + 0.12 * coverageSmall + 0.08 * coverageLarge).clamp(0.0, 0.96);
    }

    // 3+ tokens: allow missing a brand/descriptor word if >= 66% tokens match & >= 2 match & head matches
    if (matchedCount < 2 || coverageSmall < 0.66 || !headMatched) {
      return 0.0;
    }

    double score = 0.72 + 0.18 * coverageSmall + 0.08 * coverageLarge;
    if (smaller.sizesInBaseUnit.isNotEmpty &&
        larger.sizesInBaseUnit.isNotEmpty &&
        !_hasIncompatibleSizes(smaller.sizesInBaseUnit, larger.sizesInBaseUnit)) {
      score += 0.02;
    }
    return score.clamp(0.0, 0.96);
  }

  /// Scores how likely [receiptItem] corresponds to [cartItem].
  static ({double score, ReceiptMatchType type}) scoreItemMatch(
    Item receiptItem,
    Item cartItem, {
    String? barcodeResolvedName,
  }) {
    if (barcodesMatch(receiptItem.barcode, cartItem.barcode)) {
      return (score: 1.0, type: ReceiptMatchType.barcode);
    }

    final normReceipt = canonicalizeName(receiptItem.name);
    final normCart = canonicalizeName(cartItem.name);
    if (normReceipt.isNotEmpty && normReceipt == normCart) {
      return (score: 0.98, type: ReceiptMatchType.exactName);
    }

    double bestScore = scoreNameMatch(receiptItem.name, cartItem.name);
    ReceiptMatchType bestType = ReceiptMatchType.smartName;

    if (barcodeResolvedName != null && barcodeResolvedName.trim().isNotEmpty) {
      final histScore = scoreNameMatch(barcodeResolvedName, cartItem.name) * 0.96;
      if (histScore > bestScore) {
        bestScore = histScore;
        bestType = ReceiptMatchType.barcodeHistoryName;
      }
    }

    return (score: bestScore, type: bestType);
  }

  /// Checks whether two receipt lines represent the exact same product
  /// (identical barcode or identical canonicalized name).
  static bool areSameReceiptProduct(Item a, Item b) {
    if (barcodesMatch(a.barcode, b.barcode)) return true;
    final ca = canonicalizeName(a.name);
    final cb = canonicalizeName(b.name);
    return ca.isNotEmpty && ca == cb;
  }

  /// Reconciles [receiptItems] against [cartItems] using global best-score assignment.
  static ReceiptItemMatchResult matchItems({
    required List<Item> receiptItems,
    required List<Item> cartItems,
    String? Function(String barcode)? barcodeNameResolver,
    Map<int, int?>? manualCartIndexByReceiptPos,
  }) {
    final Map<int, int> receiptToCartIndex = {};
    final Map<int, ReceiptMatchType> matchTypes = {};
    final Set<int> additionalLines = {};
    final Set<int> claimedCartPositions = {};
    final Set<int> forcedNewPositions = {};

    // 1. Apply manual overrides first
    if (manualCartIndexByReceiptPos != null && manualCartIndexByReceiptPos.isNotEmpty) {
      for (final entry in manualCartIndexByReceiptPos.entries) {
        final rIdx = entry.key;
        if (rIdx < 0 || rIdx >= receiptItems.length) continue;
        final targetCartItemIndex = entry.value;
        if (targetCartItemIndex == null || targetCartItemIndex == -1) {
          forcedNewPositions.add(rIdx);
          continue;
        }
        final cartPos = cartItems.indexWhere((it) => it.index == targetCartItemIndex);
        if (cartPos != -1) {
          if (claimedCartPositions.contains(cartPos)) {
            additionalLines.add(rIdx);
          }
          receiptToCartIndex[rIdx] = cartPos;
          matchTypes[rIdx] = ReceiptMatchType.manual;
          claimedCartPositions.add(cartPos);
        }
      }
    }

    // 2. Build all valid candidates for remaining receipt items
    final List<_MatchCandidate> candidates = [];
    for (int rIdx = 0; rIdx < receiptItems.length; rIdx++) {
      if (receiptToCartIndex.containsKey(rIdx) || forcedNewPositions.contains(rIdx)) {
        continue;
      }
      final rItem = receiptItems[rIdx];
      String? resolvedName;
      final bc = Item.parseBarcode(rItem.barcode);
      if (bc != null && barcodeNameResolver != null) {
        resolvedName = barcodeNameResolver(bc);
      }

      for (int cIdx = 0; cIdx < cartItems.length; cIdx++) {
        if (claimedCartPositions.contains(cIdx)) continue;
        final res = scoreItemMatch(
          rItem,
          cartItems[cIdx],
          barcodeResolvedName: resolvedName,
        );
        if (res.score >= _matchThreshold) {
          candidates.add(_MatchCandidate(
            receiptIdx: rIdx,
            cartIdx: cIdx,
            score: res.score,
            type: res.type,
          ));
        }
      }
    }

    // 3. Global greedy best-score 1-to-1 assignment
    candidates.sort((a, b) {
      final cmp = b.score.compareTo(a.score);
      if (cmp != 0) return cmp;
      final rCmp = a.receiptIdx.compareTo(b.receiptIdx);
      if (rCmp != 0) return rCmp;
      return a.cartIdx.compareTo(b.cartIdx);
    });

    for (final cand in candidates) {
      if (receiptToCartIndex.containsKey(cand.receiptIdx)) continue;
      if (claimedCartPositions.contains(cand.cartIdx)) continue;
      receiptToCartIndex[cand.receiptIdx] = cand.cartIdx;
      matchTypes[cand.receiptIdx] = cand.type;
      claimedCartPositions.add(cand.cartIdx);
    }

    // 4. Handle duplicate lines within the same receipt for an already-matched product
    // (e.g., two lines of "ARROZ TIO JOAO 5KG" with same barcode/name on one receipt).
    for (int rIdx = 0; rIdx < receiptItems.length; rIdx++) {
      if (receiptToCartIndex.containsKey(rIdx) || forcedNewPositions.contains(rIdx)) {
        continue;
      }
      for (final matchedEntry in receiptToCartIndex.entries) {
        if (areSameReceiptProduct(receiptItems[rIdx], receiptItems[matchedEntry.key])) {
          receiptToCartIndex[rIdx] = matchedEntry.value;
          matchTypes[rIdx] = matchTypes[matchedEntry.key] ?? ReceiptMatchType.exactName;
          additionalLines.add(rIdx);
          break;
        }
      }
    }

    return ReceiptItemMatchResult(
      receiptToCartIndex: receiptToCartIndex,
      matchTypes: matchTypes,
      additionalLineReceiptIndexes: additionalLines,
    );
  }
}
