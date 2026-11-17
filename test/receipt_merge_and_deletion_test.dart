import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/providers/item_provider.dart';
import 'package:lista_compras/services/receipt_item_matcher.dart';
import 'package:lista_compras/services/receipt_parser.dart';
import 'package:lista_compras/services/sefaz_receipt_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Item.parseBarcode & GTIN extraction', () {
    test('normalizes quoted/float barcodes and rejects scientific notation or placeholders', () {
      expect(Item.parseBarcode("'7891000100103"), '7891000100103');
      expect(Item.parseBarcode('7891000100103.0'), '7891000100103');
      expect(Item.parseBarcode('  7894900011517  '), '7894900011517');
      expect(Item.parseBarcode('7.89E+12'), isNull);
      expect(Item.parseBarcode('7,89E+12'), isNull);
      expect(Item.parseBarcode('SEM GTIN'), isNull);
      expect(Item.parseBarcode('  '), isNull);
    });

    test('ReceiptParser.extractValidBarcode normalizes GTIN-14 zero-padded EAN-13 and rejects placeholders', () {
      expect(ReceiptParser.extractValidBarcode('(Código: 7894900011517)'), '7894900011517');
      expect(ReceiptParser.extractValidBarcode('07894900011517'), '7894900011517');
      expect(ReceiptParser.extractValidBarcode('0000000000000'), isNull);
      expect(ReceiptParser.extractValidBarcode('12345'), isNull);
    });

    test('ReceiptParser.parseWithMetadata extracts OCR barcode and KG flag cleanly', () {
      const ocrText = '''
SUPERMERCADO MODELO LTDA
CNPJ: 12.345.678/0001-99
7894900011517 REFRIG COCA COLA 2L 1 UN X 9,99 9,99
CARNE PATINHO MOIDO 1,250 KG X 39,90 49,88
''';
      final parsed = ReceiptParser.parseWithMetadata(ocrText);
      expect(parsed.items.length, greaterThanOrEqualTo(2));

      final coca = parsed.items.firstWhere((it) => it.name.toUpperCase().contains('COCA'));
      expect(coca.barcode, '7894900011517');
      expect(coca.name.contains('7894900011517'), isFalse);

      final carne = parsed.items.firstWhere((it) => it.name.toUpperCase().contains('PATINHO'));
      expect(carne.isKg, isTrue);
      expect(carne.quantity, closeTo(1.25, 0.01));
    });

    test('SefazReceiptService parses ENCAT HTML barcodes (.RCod) and KG unit (.RUN)', () {
      const html = '''
<html><body>
  <div class="txtTopo">SUPERMERCADO CENTRAL</div>
  <table id="tabResult">
    <tr id="Item + 1">
      <td>
        <span class="txtTit">ARROZ TIO JOAO TP1 5KG</span>
        <span class="RCod">(Código: 7896006711117 )</span>
        <span class="Rqtd"><strong>Qtde.:</strong>1</span>
        <span class="RUN"><strong>UN: </strong>UN</span>
        <span class="RvlUnit"><strong>Vl. Unit.:</strong> 29,90</span>
      </td>
      <td class="txtRight"><span class="valor">29,90</span></td>
    </tr>
    <tr id="Item + 2">
      <td>
        <span class="txtTit">BANANA PRATA</span>
        <span class="RCod">(Código: SEM GTIN)</span>
        <span class="Rqtd"><strong>Qtde.:</strong>1,450</span>
        <span class="RUN"><strong>UN: </strong>KG</span>
        <span class="RvlUnit"><strong>Vl. Unit.:</strong> 6,99</span>
      </td>
      <td class="txtRight"><span class="valor">10,14</span></td>
    </tr>
  </table>
</body></html>
''';
      // 7896006711117 check digit check: if synthetic EAN isn't check-digit valid, test valid EAN-13
      final fixedHtml = html.replaceFirst('7896006711117', '7894900011517');
      final res = SefazReceiptService.instance.parseSefazHtml(htmlContent: fixedHtml);
      expect(res.items.length, 2);
      expect(res.storeName, 'Supermercado Central');
      expect(res.items[0].name, 'Arroz tio joao tp1 5kg');
      expect(res.items[0].barcode, '7894900011517');
      expect(res.items[0].isKg, isFalse);
      expect(res.items[1].barcode, isNull);
      expect(res.items[1].isKg, isTrue);
      expect(res.items[1].quantity, closeTo(1.45, 0.001));
    });
  });

  group('ReceiptItemMatcher smart reconciliation', () {
    test('matches by barcode even when names differ completely', () {
      final cart = [
        Item(index: 0, name: 'Meu Refrigerante Favorito', quantity: 1, unitPrice: 8.5, category: 'Bebidas', barcode: '7894900011517'),
      ];
      final receipt = [
        Item(name: 'REFRIG PET TRAD', quantity: 2, unitPrice: 9.49, category: 'Bebidas', barcode: '7894900011517'),
      ];

      final res = ReceiptItemMatcher.matchItems(receiptItems: receipt, cartItems: cart);
      expect(res.receiptToCartIndex[0], 0);
      expect(res.matchTypes[0], ReceiptMatchType.barcode);
    });

    test('matches generic cart names with abbreviated SEFAZ descriptions', () {
      final cart = [
        Item(index: 0, name: 'Arroz', quantity: 1, unitPrice: 25.0, category: 'Grãos e Massas'),
        Item(index: 1, name: 'Queijo Muçarela', quantity: 1, unitPrice: 15.0, category: 'Frios e Laticínios'),
        Item(index: 2, name: 'Coca-Cola 2L', quantity: 1, unitPrice: 9.0, category: 'Bebidas'),
        Item(index: 3, name: 'Sabão em Pó', quantity: 1, unitPrice: 18.0, category: 'Limpeza'),
      ];
      final receipt = [
        Item(name: 'ARROZ TIO JOAO TP1 5KG', quantity: 1, unitPrice: 28.9, category: 'Grãos e Massas'),
        Item(name: 'QJO MUSSARELA FATIADO', quantity: 1, unitPrice: 16.5, category: 'Frios e Laticínios'),
        Item(name: 'REFRIG COCA COLA PET 2L', quantity: 1, unitPrice: 9.99, category: 'Bebidas'),
        Item(name: 'SABAO PO OMO LAVAGEM 1,6KG', quantity: 1, unitPrice: 19.9, category: 'Limpeza'),
        Item(name: 'PAO FRANCES KG', quantity: 1, unitPrice: 8.5, category: 'Padaria'),
      ];

      final res = ReceiptItemMatcher.matchItems(receiptItems: receipt, cartItems: cart);
      expect(res.receiptToCartIndex[0], 0);
      expect(res.receiptToCartIndex[1], 1);
      expect(res.receiptToCartIndex[2], 2);
      expect(res.receiptToCartIndex[3], 3);
      expect(res.receiptToCartIndex.containsKey(4), isFalse);
    });

    test('guards against false positives like Leite vs Leite Condensado or size mismatch', () {
      final cart = [
        Item(index: 0, name: 'Leite', quantity: 2, unitPrice: 5.0, category: 'Frios e Laticínios'),
        Item(index: 1, name: 'Tomate', quantity: 1, unitPrice: 7.0, category: 'Hortifruti'),
        Item(index: 2, name: 'Sal', quantity: 1, unitPrice: 3.0, category: 'Outros'),
        Item(index: 3, name: 'Coca-Cola 2L', quantity: 1, unitPrice: 9.0, category: 'Bebidas'),
      ];
      final receipt = [
        Item(name: 'LEITE CONDENSADO MOCA 395G', quantity: 1, unitPrice: 6.99, category: 'Outros'),
        Item(name: 'MOLHO DE TOMATE TRADICIONAL', quantity: 1, unitPrice: 3.49, category: 'Outros'),
        Item(name: 'MANTEIGA C/ SAL 200G', quantity: 1, unitPrice: 11.9, category: 'Frios e Laticínios'),
        Item(name: 'REFRIG COCA COLA LATA 350ML', quantity: 1, unitPrice: 4.5, category: 'Bebidas'),
      ];

      final res = ReceiptItemMatcher.matchItems(receiptItems: receipt, cartItems: cart);
      expect(res.receiptToCartIndex, isEmpty);
    });

    test('supports manual overrides (force target or force add as new) and duplicate receipt lines', () {
      final cart = [
        Item(index: 10, name: 'Chocolate', quantity: 1, unitPrice: 6.0, category: 'Outros'),
        Item(index: 20, name: 'Biscoito', quantity: 1, unitPrice: 4.0, category: 'Outros'),
      ];
      final receipt = [
        Item(name: 'ITEM CODIGO 999', quantity: 1, unitPrice: 6.5, category: 'Outros'),
        Item(name: 'BISCOITO CREAM CRACKER', quantity: 2, unitPrice: 4.2, category: 'Outros'),
        Item(name: 'BISCOITO CREAM CRACKER', quantity: 1, unitPrice: 4.2, category: 'Outros'),
      ];

      final res = ReceiptItemMatcher.matchItems(
        receiptItems: receipt,
        cartItems: cart,
        manualCartIndexByReceiptPos: {
          0: 10, // force match to cart item index 10
          1: -1, // force add as new
        },
      );
      expect(res.receiptToCartIndex[0], 0);
      expect(res.matchTypes[0], ReceiptMatchType.manual);
      expect(res.receiptToCartIndex.containsKey(1), isFalse);
      // Item 2 ("BISCOITO CREAM CRACKER") can still match cart item "Biscoito" since item 1 was forced new
      expect(res.receiptToCartIndex[2], 1);
    });
  });

  group('ItemProvider mergeReceiptItems, barcode preservation, and delete tombstones', () {
    test('mergeReceiptItems overrides matched items, preserves existing barcodes, adopts new barcodes, and adds missing ones', () async {
      final provider = ItemProvider();
      await provider.initialization;

      provider.setItemsForTesting([
        Item(
          index: 0,
          name: 'Arroz',
          quantity: 1,
          unitPrice: 24.0,
          category: 'Grãos e Massas',
          barcode: '7894900011517',
          isBought: false,
        ),
        Item(
          index: 1,
          name: 'Feijão Carioca',
          quantity: 1,
          unitPrice: 7.0,
          category: 'Grãos e Massas',
          barcode: null,
          isBought: false,
        ),
      ], month: 'Teste Merge');

      final result = await provider.mergeReceiptItems(
        [
          // Barcode absent in receipt -> must preserve existing barcode 7894900011517
          Item(name: 'ARROZ TIO JOAO 5KG', quantity: 2, unitPrice: 27.9, category: 'Grãos e Massas', barcode: null),
          // Barcode present in receipt -> must enrich cart item
          Item(name: 'FEIJAO CARIOCA 1KG', quantity: 2, unitPrice: 8.49, category: 'Grãos e Massas', barcode: '7896006711115'),
          // Missing from list -> must be added
          Item(name: 'Cafe Pilao 500g', quantity: 1, unitPrice: 18.5, category: 'Café e Chá', barcode: '7891000100103'),
        ],
        storeName: 'Supermercado Teste',
      );

      expect(result.updatedCount, 2);
      expect(result.addedCount, 1);
      expect(result.preservedBarcodesCount, 3);
      expect(provider.items.length, 3);

      final arroz = provider.items[0];
      expect(arroz.isBought, isTrue);
      expect(arroz.unitPrice, closeTo(27.9, 0.001));
      expect(arroz.quantity, 2);
      expect(arroz.barcode, '7894900011517');
      expect(arroz.supermarket, 'Supermercado Teste');

      final feijao = provider.items[1];
      expect(feijao.isBought, isTrue);
      expect(feijao.unitPrice, closeTo(8.49, 0.001));
      expect(feijao.barcode, '7896006711115');

      final cafe = provider.items[2];
      expect(cafe.name, 'Cafe Pilao 500g');
      expect(cafe.barcode, '7891000100103');
      expect(cafe.isBought, isTrue);
      expect(provider.findBarcodeForProductName('Cafe Pilao 500g'), '7891000100103');
    });

    test('deleted items stay deleted after cloud sync reconciliation and restoreItem clears tombstone', () async {
      final provider = ItemProvider();
      await provider.initialization;

      const month = 'Teste Exclusao';
      final itemA = Item(
        index: 0,
        name: 'Leite Integral',
        quantity: 2,
        unitPrice: 5.5,
        category: 'Frios e Laticínios',
        barcode: '7894900011517',
      );
      final itemB = Item(
        index: 1,
        name: 'Pao de Forma',
        quantity: 1,
        unitPrice: 9.0,
        category: 'Padaria',
        barcode: null,
      );
      final itemC = Item(
        index: 2,
        name: 'Manteiga',
        quantity: 1,
        unitPrice: 12.0,
        category: 'Frios e Laticínios',
      );

      provider.setItemsForTesting([itemA, itemB, itemC], month: month);

      // Delete Pao de Forma and Manteiga using removeItemObject (simulating rapid swipes)
      await provider.removeItemObject(itemB);
      await provider.removeItemObject(itemC);
      expect(provider.items.map((e) => e.name).toList(), ['Leite Integral']);

      // Simulate stale Google Sheets snapshot that STILL has deleted items AND lost column H barcode on Leite
      final staleCloudItems = [
        Item(index: 0, name: 'Leite Integral', quantity: 2, unitPrice: 5.5, category: 'Frios e Laticínios', barcode: null),
        Item(index: 1, name: 'Pao de Forma', quantity: 1, unitPrice: 9.0, category: 'Padaria'),
        Item(index: 2, name: 'Manteiga', quantity: 1, unitPrice: 12.0, category: 'Frios e Laticínios'),
      ];

      final reconciled = await provider.reconcileCloudItemsForTesting(
        month,
        staleCloudItems,
        provider.items,
      );

      // Deleted items MUST NOT return, and Leite's local barcode MUST be preserved
      expect(reconciled.map((e) => e.name).toList(), ['Leite Integral']);
      expect(reconciled.first.barcode, '7894900011517');

      // Undo/restore clears tombstone so Pao de Forma stays in the list
      await provider.restoreItem(itemB);
      expect(provider.items.map((e) => e.name).toList(), ['Leite Integral', 'Pao de Forma']);
    });

    test('reconcileCloudItems preserves local isBought, price and qty when local edits are pending', () async {
      final provider = ItemProvider();
      await provider.initialization;

      const month = 'Novembro 2026';
      provider.setMonthsForTesting([month]);
      provider.setItemsForTesting([
        Item(
          index: 7,
          name: 'Arroz',
          quantity: 1,
          unitPrice: 0.0,
          category: 'Grãos e Massas',
          isBought: false,
          barcode: '7896006711115',
        ),
      ], month: month);

      await provider.mergeReceiptItems([
        Item(name: 'ARROZ TIO JOAO 5KG', quantity: 2, unitPrice: 28.5, category: 'Grãos e Massas', barcode: '7896006711115'),
      ]);

      expect(provider.items.first.isBought, isTrue);
      expect(provider.items.first.unitPrice, closeTo(28.5, 0.001));

      // Stale cloud snapshot still shows unchecked item with old price
      final staleCloud = [
        Item(index: 7, name: 'Arroz', quantity: 1, unitPrice: 0.0, category: 'Grãos e Massas', isBought: false, barcode: null),
      ];

      final reconciled = await provider.reconcileCloudItemsForTesting(month, staleCloud, provider.items);
      expect(reconciled.first.isBought, isTrue);
      expect(reconciled.first.unitPrice, closeTo(28.5, 0.001));
      expect(reconciled.first.quantity, 2);
      expect(reconciled.first.barcode, '7896006711115');
    });

    test('getAvailableSourceMonthsSummary ranks most complete list first and exportItemsFromMonth keeps barcodes', () async {
      final provider = ItemProvider();
      await provider.initialization;

      provider.setMonthsForTesting(['Setembro 2026', 'Outubro 2026', 'Novembro 2026']);

      // Setembro: 1 item
      provider.setItemsForTesting([
        Item(index: 7, name: 'Cafe', quantity: 1, unitPrice: 18.0, category: 'Café e Chá', barcode: '7891000100103'),
      ], month: 'Setembro 2026');

      // Outubro: 3 items (2 with barcode) -> should be suggested as most complete
      provider.setItemsForTesting([
        Item(index: 7, name: 'ARROZ TIO JOAO 5KG', quantity: 2, unitPrice: 29.9, category: 'Grãos e Massas', isBought: true, barcode: '7896006711115'),
        Item(index: 8, name: 'Leite Integral', quantity: 6, unitPrice: 5.4, category: 'Frios e Laticínios', isBought: true, barcode: '7894900011517'),
        Item(index: 9, name: 'Banana Prata', quantity: 1.5, unitPrice: 6.9, isKg: true, category: 'Hortifruti', isBought: true),
      ], month: 'Outubro 2026');

      // Novembro: already has "Arroz" without barcode
      provider.setItemsForTesting([
        Item(index: 7, name: 'Arroz', quantity: 1, unitPrice: 0.0, category: 'Grãos e Massas', isBought: false, barcode: null),
      ], month: 'Novembro 2026');

      final summaries = await provider.getAvailableSourceMonthsSummary(excludeMonth: 'Novembro 2026');
      expect(summaries.length, 2);
      expect(summaries.first.title, 'Outubro 2026');
      expect(summaries.first.isMostComplete, isTrue);
      expect(summaries.first.itemCount, 3);
      expect(summaries.first.barcodeCount, 2);

      // Export from chosen Outubro 2026 into Novembro 2026 resetting prices & keeping quantities + barcodes
      final exportRes = await provider.exportItemsFromMonth(
        sourceMonth: 'Outubro 2026',
        targetMonth: 'Novembro 2026',
        resetPrices: true,
        resetQuantities: false,
        resetBought: true,
        replaceExisting: false,
      );

      expect(exportRes.updatedCount, 1); // Arroz matched smartly with ARROZ TIO JOAO 5KG
      expect(exportRes.addedCount, 2); // Leite + Banana
      expect(exportRes.preservedBarcodesCount, 2);
      expect(provider.items.length, 3);

      final arroz = provider.items[0];
      expect(arroz.barcode, '7896006711115');
      expect(arroz.quantity, 2);
      expect(arroz.unitPrice, 0.0);
      expect(arroz.isBought, isFalse);

      final leite = provider.items[1];
      expect(leite.barcode, '7894900011517');
      expect(leite.quantity, 6);
      expect(leite.unitPrice, 0.0);
      expect(leite.isBought, isFalse);

      // Also verify createNewMonth using explicit sourceMonth ('Outubro 2026')
      await provider.createNewMonth(
        'Dezembro 2026',
        true,
        sourceMonth: 'Outubro 2026',
        resetPrices: true,
        resetQuantities: false,
      );
      expect(provider.currentMonth, 'Dezembro 2026');
      expect(provider.items.length, 3);
      expect(provider.items[0].barcode, '7896006711115');
      expect(provider.items[0].quantity, 2);
      expect(provider.items[0].unitPrice, 0.0);
      expect(provider.items[0].isBought, isFalse);
      expect(provider.items[1].barcode, '7894900011517');
    });
  });
}
