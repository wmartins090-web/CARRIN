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
  });
}
