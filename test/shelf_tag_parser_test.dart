import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/services/shelf_tag_parser.dart';

void main() {
  group('ShelfTagParser Unit Tests', () {
    test('parses classic atacarejo shelf tag with retail, wholesale and minimum qty', () {
      const tagText = r'''
LEITE CONDENSADO MOCOCA 395G
R$ 6,89 UNIDADE
A PARTIR DE 4 UNIDADES
R$ 5,99 CADA
7891000100103
''';

      final result = ShelfTagParser.parse(tagText);

      expect(result.productName, contains('LEITE CONDENSADO'));
      expect(result.barcode, equals('7891000100103'));
      expect(result.hasMultiplePrices, isTrue);

      expect(result.retailPrice?.price, equals(6.89));
      expect(result.retailPrice?.label, equals('Varejo'));

      expect(result.wholesalePrice?.price, equals(5.99));
      expect(result.wholesalePrice?.label, equals('Atacado'));
      expect(result.wholesalePrice?.minQuantity, equals(4));

      expect(result.unitSavings, closeTo(0.90, 0.01));
      expect(result.discountPercentage, closeTo(13.06, 0.1));
    });

    test('parses tag with explicit VAREJO and ATACADO keywords', () {
      const tagText = r'''
ARROZ TIO JOAO 5KG
VAREJO: R$ 32,90
ATACADO A PARTIR DE 6 UN: R$ 29,90
''';

      final result = ShelfTagParser.parse(tagText);

      expect(result.productName, equals('ARROZ TIO JOAO 5KG'));
      expect(result.retailPrice?.price, equals(32.90));
      expect(result.wholesalePrice?.price, equals(29.90));
      expect(result.wholesalePrice?.minQuantity, equals(6));
      expect(result.unitSavings, closeTo(3.00, 0.01));
    });

    test('parses single price tag gracefully', () {
      const tagText = r'''
SABAO EM PO OMO 1.6KG
R$ 21,99
7891234567890
''';

      final result = ShelfTagParser.parse(tagText);

      expect(result.productName, contains('SABAO EM PO'));
      expect(result.hasMultiplePrices, isFalse);
      expect(result.retailPrice?.price, equals(21.99));
      expect(result.wholesalePrice, isNull);
    });

    test('handles empty or whitespace text without crashing', () {
      final result = ShelfTagParser.parse('   ');
      expect(result.hasAnyPrice, isFalse);
      expect(result.productName, isNull);
      expect(result.barcode, isNull);
    });

    test('parses tag with club/card intermediate price', () {
      const tagText = r'''
CERVEJA HEINEKEN LATA 350ML
R$ 5,99 VAREJO
R$ 5,49 CARTAO CLUBE
R$ 4,99 A PARTIR DE 12 UNIDADES
7891234567890
''';
      final result = ShelfTagParser.parse(tagText);
      expect(result.hasMultiplePrices, isTrue);
      expect(result.retailPrice?.price, equals(5.99));
      expect(result.wholesalePrice?.price, equals(4.99));
      expect(result.wholesalePrice?.minQuantity, equals(12));
      expect(result.allPrices.length, equals(3));
      expect(result.allPrices.any((p) => p.price == 5.49), isTrue);
    });

    test('ignores store header, per-kg reference prices, validity dates and merges multi-line product name', () {
      const tagText = r'''
ATACADAO
ARROZ BRANCO TIO JOAO TP1
PACOTE 5KG
PRECO VAREJO
R$ 29,90
PRECO ATACADO A PARTIR DE 3 UNIDADES
R$ 26,90
COD: 00041258  7896006711115  PRECO P/ KG: R$ 5,38
VALIDO DE 10/11 A 20/11/2026
''';
      final result = ShelfTagParser.parse(tagText);
      expect(result.productName, equals('ARROZ BRANCO TIO JOAO TP1 PACOTE 5KG'));
      expect(result.barcode, equals('7896006711115'));
      expect(result.retailPrice?.price, equals(29.90));
      expect(result.wholesalePrice?.price, equals(26.90));
      expect(result.wholesalePrice?.minQuantity, equals(3));
      expect(result.allPrices.length, equals(2));
    });

    test('handles split currency lines, spaced cents and same-line name/barcode/price', () {
      const tagText = r'''
7894900011517 REFRIG COCA COLA 1.50L
R$
9
,49
''';
      final result = ShelfTagParser.parse(tagText);
      expect(result.barcode, equals('7894900011517'));
      expect(result.productName, contains('REFRIG COCA COLA 1.50L'));
      expect(result.retailPrice?.price, equals(9.49));
      expect(result.allPrices.length, equals(1));

      const spacedCentsTag = 'CAFE PILAO 500G\nR\$ 18 99';
      final spaced = ShelfTagParser.parse(spacedCentsTag);
      expect(spaced.productName, equals('CAFE PILAO 500G'));
      expect(spaced.retailPrice?.price, equals(18.99));
    });

    test('requirePriceContext ignores nutrition table numbers on product packaging while accepting real shelf tags', () {
      const packagingBackText = '''
INFORMACAO NUTRICIONAL
PORCAO 150,00g
VALOR ENERGETICO 120,00 kcal
GORDURAS 5,50g
LOTE 12.34
7891000100103
''';
      final pkgRes = ShelfTagParser.parse(packagingBackText, requirePriceContext: true);
      expect(pkgRes.hasAnyPrice, isFalse);

      const liveShelfFrameText = '''
LEITE UHT INTEGRAL PIRACANJUBA 1L
R\$ 5 49
7898215151784
''';
      final shelfRes = ShelfTagParser.parse(liveShelfFrameText, requirePriceContext: true);
      expect(shelfRes.hasAnyPrice, isTrue);
      expect(shelfRes.productName, equals('LEITE UHT INTEGRAL PIRACANJUBA 1L'));
      expect(shelfRes.retailPrice?.price, equals(5.49));
      expect(shelfRes.barcode, equals('7898215151784'));
    });

    test('extracts spaced EAN-13 without confusing dates for 8-digit barcodes', () {
      const tagText = '''
SABONETE DOVE 90G
VALIDO 10 11 2026
R\$ 4,29
7 891150 012349
''';
      final res = ShelfTagParser.parse(tagText);
      expect(res.barcode, equals('7891150012349'));
      expect(res.retailPrice?.price, equals(4.29));
      expect(res.productName, equals('SABONETE DOVE 90G'));
    });

    test('parseOcrLines reconstructs side-by-side large price digits and superscript cents', () {
      // Simula ML Kit retornando blocos fora de ordem e dígitos grandes separados dos centavos
      const ocrLines = [
        ShelfTagOcrLine(text: ',90', left: 260, top: 185, right: 330, bottom: 225),
        ShelfTagOcrLine(text: '7896006711115', left: 40, top: 320, right: 260, bottom: 342),
        ShelfTagOcrLine(text: 'R\$', left: 40, top: 195, right: 85, bottom: 230),
        ShelfTagOcrLine(text: '29', left: 90, top: 180, right: 255, bottom: 295),
        ShelfTagOcrLine(text: 'ARROZ TIPO 1 CAMIL 5KG', left: 40, top: 60, right: 420, bottom: 105),
        ShelfTagOcrLine(text: 'R\$ 5,12', left: 40, top: 360, right: 110, bottom: 374),
      ];

      final res = ShelfTagParser.parseOcrLines(ocrLines);
      expect(res.productName, equals('ARROZ TIPO 1 CAMIL 5KG'));
      expect(res.barcode, equals('7896006711115'));
      expect(res.retailPrice?.price, equals(29.90));
      expect(res.allPrices.length, equals(1)); // filtro visual removeu R$ 5,12 minúsculo do rodapé
    });

    test('parseOcrLines joins integer + superscript cents without comma when price symbol is adjacent', () {
      const ocrLines = [
        ShelfTagOcrLine(text: 'CAFE MELITTA 500G', left: 30, top: 40, right: 350, bottom: 80),
        ShelfTagOcrLine(text: 'R\$', left: 30, top: 140, right: 75, bottom: 175),
        ShelfTagOcrLine(text: '18', left: 80, top: 130, right: 185, bottom: 230),
        ShelfTagOcrLine(text: '99', left: 190, top: 135, right: 245, bottom: 175),
      ];

      final res = ShelfTagParser.parseOcrLines(ocrLines);
      expect(res.productName, equals('CAFE MELITTA 500G'));
      expect(res.retailPrice?.price, equals(18.99));
    });
  });
}
