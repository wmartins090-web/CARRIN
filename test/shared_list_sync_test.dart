import 'package:flutter_test/flutter_test.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/services/shared_list_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedListService & Peer Sync Unit Tests', () {
    test('encodeSingleList embeds syncId and decodeList extracts it accurately', () {
      final items = [
        Item(
          index: 7,
          name: 'Arroz Tio João 5kg',
          quantity: 2.0,
          unitPrice: 28.50,
          category: 'Alimentos',
          isKg: false,
          isBought: true,
          barcode: '7891234567890',
        ),
        Item(
          index: 8,
          name: 'Tomate Italiano',
          quantity: 1.5,
          unitPrice: 8.90,
          category: 'Hortifruti',
          isKg: true,
          isBought: false,
        ),
      ];

      const testSyncId = 'c_test_sync_9918';
      final encoded = SharedListService.instance.encodeSingleList(
        title: 'Churrasco de Domingo',
        budget: 250.0,
        items: items,
        syncId: testSyncId,
      );

      expect(encoded.startsWith('carrin://share?z='), isTrue);

      final decoded = SharedListService.instance.decodeList(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.title, equals('Churrasco de Domingo'));
      expect(decoded.budget, equals(250.0));
      expect(decoded.syncId, equals(testSyncId));
      expect(decoded.items.length, equals(2));

      final first = decoded.items[0];
      expect(first.name, equals('Arroz Tio João 5kg'));
      expect(first.quantity, equals(2.0));
      expect(first.unitPrice, equals(28.50));
      expect(first.isBought, isTrue);
      expect(first.barcode, equals('7891234567890'));

      final second = decoded.items[1];
      expect(second.name, equals('Tomate Italiano'));
      expect(second.quantity, equals(1.5));
      expect(second.unitPrice, equals(8.90));
      expect(second.isKg, isTrue);
      expect(second.isBought, isFalse);
    });

    test('decodeList handles raw URI and auto-generates syncId if omitted in legacy payload', () {
      final items = [Item(index: 7, name: 'Feijão', quantity: 1.0, unitPrice: 7.99, isBought: false)];
      final encoded = SharedListService.instance.encodeSingleList(
        title: 'Compras Rápidas',
        budget: 0.0,
        items: items,
      );

      final decoded = SharedListService.instance.decodeList(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.title, equals('Compras Rápidas'));
      expect(decoded.items.length, equals(1));
      expect(decoded.syncId, isNotNull);
      expect(decoded.syncId!.startsWith('c_'), isTrue);
    });
  });
}
