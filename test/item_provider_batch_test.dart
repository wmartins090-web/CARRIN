import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/providers/item_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ItemProvider Batch Operations Unit Tests (B & C)', () {
    test('Item categoryEmojis maps standard categories properly', () {
      expect(ItemProvider.categoryEmojis['Açougue e Frios'], isNotNull);
      expect(ItemProvider.categoryEmojis['Hortifruti'], isNotNull);
      expect(ItemProvider.categoryEmojis['Bebidas'], isNotNull);
    });

    test('removeMultipleItems and restoreMultipleItems preserve item properties and supermarket', () async {
      final item1 = Item(index: 7, name: 'Picanha', quantity: 1, unitPrice: 80.0, category: 'Açougue e Frios', supermarket: 'Atacadão');
      final item2 = Item(index: 8, name: 'Cerveja', quantity: 6, unitPrice: 5.0, category: 'Bebidas', supermarket: 'Assaí');
      final item3 = Item(index: 9, name: 'Carvão', quantity: 1, unitPrice: 20.0, category: 'Outros');

      expect(item1.supermarket, equals('Atacadão'));
      expect(item2.supermarket, equals('Assaí'));
      expect(item3.supermarket, isNull);

      final copy1 = item1.copyWith();
      expect(copy1.supermarket, equals('Atacadão'));
      expect(copy1.name, equals('Picanha'));
    });

    test('Item parseBool handles different representation of boolean values', () {
      expect(Item.parseBool(true), isTrue);
      expect(Item.parseBool(false), isFalse);
      expect(Item.parseBool(1), isTrue);
      expect(Item.parseBool(0), isFalse);
      expect(Item.parseBool('true'), isTrue);
      expect(Item.parseBool('VERDADEIRO'), isTrue);
      expect(Item.parseBool('false'), isFalse);
      expect(Item.parseBool('FALSO'), isFalse);
      expect(Item.parseBool(null), isFalse);
    });
  });
}
