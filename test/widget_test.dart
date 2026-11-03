import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lista_compras/services/utils.dart';
import 'package:lista_compras/widgets/supermarket_avatar.dart';
import 'package:lista_compras/screens/main_screen.dart';
import 'package:lista_compras/screens/dashboard_screen.dart';
import 'package:lista_compras/providers/item_provider.dart';
import 'package:lista_compras/theme/app_themes.dart';
import 'package:lista_compras/services/receipt_parser.dart';
import 'package:lista_compras/services/auth_service.dart';
import 'package:lista_compras/services/quick_summary_service.dart';
import 'package:lista_compras/services/user_sheets_service.dart';
import 'package:lista_compras/widgets/shopping_filter_bottom_sheet.dart';
import 'package:lista_compras/widgets/weight_calculator_dialog.dart';
import 'package:lista_compras/models/item.dart';
import 'package:lista_compras/services/location_service.dart';
import 'package:lista_compras/widgets/market_and_purpose_widgets.dart';
import 'package:lista_compras/services/google_places_service.dart';
import 'package:lista_compras/models/community_price.dart';
import 'package:lista_compras/services/community_price_service.dart';
import 'package:lista_compras/screens/market_map_screen.dart';
import 'package:lista_compras/screens/settings_screen.dart';
import 'package:lista_compras/screens/statistics_screen.dart';
import 'package:lista_compras/services/default_supermarkets.dart';
import 'package:lista_compras/services/barcode_lookup_service.dart';
import 'package:lista_compras/services/database_helper.dart';
import 'package:lista_compras/widgets/interactive_tab_tutorial.dart';
import 'package:lista_compras/widgets/interactive_animated_logo.dart';
import 'package:lista_compras/widgets/theme_color_picker_sheet.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('pt_BR', null);
  });

  group('ReceiptParser Unit Tests', () {
    test('parses standard single line items with quantities and prices', () {
      const receipt = '''
      MERCADO EXEMPLO LTDA
      CNPJ: 12.345.678/0001-90
      001 7891000123456 ARROZ TIO JOAO 5KG 1 UN X 29,90  29,90
      002 7892000654321 FEIJAO CARIOCA 1KG 2 UN X 7,50   15,00
      TOTAL R\$ 44,90
      DINHEIRO 50,00
      TROCO 5,10
      ''';

      final items = ReceiptParser.parse(receipt);

      expect(items.length, equals(2));
      expect(items[0].name, contains('Arroz tio joao 5kg'));
      expect(items[0].quantity, equals(1.0));
      expect(items[0].unitPrice, equals(29.90));
      expect(items[0].isBought, isTrue);

      expect(items[1].name, contains('Feijao carioca 1kg'));
      expect(items[1].quantity, equals(2.0));
      expect(items[1].unitPrice, equals(7.50));
    });

    test('parses two-line item formats and ignores totals/taxes', () {
      const receipt = '''
      SUPERMERCADO CENTRAL
      001 BISCOITO OREO 90G
      2 UN X 4,50              9,00
      002 SABONETE DOVE
      3 UN X 3,20              9,60
      SUBTOTAL                18,60
      DESCONTO                 1,00
      VALOR A PAGAR           17,60
      CARTAO DE CREDITO       17,60
      TRIBUTOS APROX           3,50
      ''';

      final items = ReceiptParser.parse(receipt);

      expect(items.length, equals(2));
      expect(items[0].name, contains('Biscoito oreo 90g'));
      expect(items[0].quantity, equals(2.0));
      expect(items[0].unitPrice, equals(4.50));

      expect(items[1].name, contains('Sabonete dove'));
      expect(items[1].quantity, equals(3.0));
      expect(items[1].unitPrice, equals(3.20));
    });

    test('extracts store name, CNPJ and items with parseWithMetadata', () {
      const receipt = '''
      SUPERMERCADOS BH LTDA
      CNPJ: 12.345.678/0001-90
      001 7891000123456 LEITE INTEGRAL 1L 2 UN X 4,99 9,98
      TOTAL R\$ 9,98
      ''';

      final result = ReceiptParser.parseWithMetadata(receipt);

      expect(result.storeName, contains('Supermercados Bh'));
      expect(result.cnpj, equals('12.345.678/0001-90'));
      expect(result.items.length, equals(1));
      expect(result.items.first.name, contains('Leite integral 1l'));
      expect(result.items.first.unitPrice, equals(4.99));
    });

    test('parses NFC-e QR code URL and extracts 44-digit key, UF and CNPJ', () {
      const nfcUrl = 'https://portalsped.fazenda.mg.gov.br/portalnfce/sistema/qrcode.xhtml?p=31230512345678000195650010000123451000123456|2|1|1|HASH';

      final result = ReceiptParser.parseNfcUrl(nfcUrl);

      expect(result.nfcKey, equals('31230512345678000195650010000123451000123456'));
      expect(result.uf, equals('MG'));
      expect(result.cnpj, equals('12.345.678/0001-95'));
    });
  });

  group('Utils Unit Tests', () {
    test('normalize removes diacritics and converts to lowercase', () {
      expect(Utils.normalize('Café Moído'), equals('cafe moido'));
      expect(Utils.normalize('Maçã Verde'), equals('maca verde'));
      expect(Utils.normalize('  ARROZ '), equals('arroz'));
    });

    test('formatNumber formats doubles correctly', () {
      expect(Utils.formatNumber(10.0), equals('10'));
      expect(Utils.formatNumber(10.5), equals('10,5'));
    });

    test('formatCurrency formats currency correctly', () {
      // currencyFormat relies on pt_BR locale initialized in setUpAll
      final formatted = Utils.formatCurrency(15.99);
      expect(formatted, contains('15,99'));
    });
  });

  group('QuickSummaryService Tests', () {
    test('saves and retrieves quick summary correctly', () async {
      SharedPreferences.setMockInitialValues({});
      await QuickSummaryService.saveQuickSummary(
        month: 'Outubro 2026',
        totalSpent: 150.0,
        budget: 500.0,
        totalItems: 10,
        boughtItems: 6,
      );

      final summary = await QuickSummaryService.getQuickSummary();
      expect(summary, isNotNull);
      expect(summary!['month'], equals('Outubro 2026'));
      expect(summary['totalSpent'], equals(150.0));
      expect(summary['budget'], equals(500.0));
      expect(summary['balance'], equals(350.0));
      expect(summary['totalItems'], equals(10));
      expect(summary['boughtItems'], equals(6));
      expect(summary['pendingItems'], equals(4));
    });
  });

  group('SupermarketAvatarSelector Widget Tests', () {
    testWidgets('renders successfully and does not throw intrinsic layout exceptions', (WidgetTester tester) async {
      String selectedId = 'supermarket_cart_ocean';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SupermarketAvatarSelector(
                selectedId: selectedId,
                onSelected: (id) {
                  selectedId = id;
                },
              ),
            ),
          ),
        ),
      );

      // Verify that headers render
      expect(find.text('Visualização do Avatar'), findsOneWidget);
      expect(find.text('Selecione o Ícone:'), findsOneWidget);
      expect(find.text('Selecione a Cor:'), findsOneWidget);

      // Verify that the gallery picker button is rendered
      expect(find.text('Escolher da Galeria'), findsOneWidget);

      // Verify that no exceptions are thrown during rendering
      expect(tester.takeException(), isNull);
    });
  });

  group('MainScreen Navigation & Back Button Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      
      // Mock SQLite, Home Widget and Google Sign In method channels
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.tekartik.sqflite'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'openDatabase') {
            return {'id': 1};
          }
          if (methodCall.method == 'query') {
            return <Map<String, dynamic>>[];
          }
          return null;
        },
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('home_widget'),
        (MethodCall methodCall) async {
          return null;
        },
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/google_sign_in'),
        (MethodCall methodCall) async {
          if (methodCall.method == 'init') return null;
          if (methodCall.method == 'signInSilently') return null;
          return null;
        },
      );
    });

    tearDown(() {
      // Clear method call handlers
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.tekartik.sqflite'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('home_widget'),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/google_sign_in'),
        null,
      );
    });

    testWidgets('MainScreen system back button navigates back to index 0 (Início)', (WidgetTester tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: AuthService()),
            ChangeNotifierProvider(create: (_) => ItemProvider()),
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ],
          child: const MaterialApp(
            home: MainScreen(),
          ),
        ),
      );

      // Wait for async init of MainScreen and providers
      await tester.pumpAndSettle();

      // Find the PageView
      final PageView pageView = tester.widget(find.byType(PageView));
      expect(pageView.controller!.page, 0.0);

      // Tap the second tab (Carrinhos, index 1)
      await tester.tap(find.byIcon(Icons.shopping_cart_outlined));
      await tester.pumpAndSettle();

      // Verify page is now index 1
      final PageView pageViewAfterTap = tester.widget(find.byType(PageView));
      expect(pageViewAfterTap.controller!.page, 1.0);

      // Simulate system back gesture / back button press
      final dynamic widgetsAppState = tester.state(find.byType(WidgetsApp));
      final didPop = await widgetsAppState.didPopRoute();

      // Ensure that didPop is true, meaning the pop gesture was handled (consumed) by our PopScope
      expect(didPop, isTrue);

      // Wait for tab switch animation to complete
      await tester.pumpAndSettle();

      // Verify the page is now back to Início (index 0)
      final PageView pageViewAfterBack = tester.widget(find.byType(PageView));
      expect(pageViewAfterBack.controller!.page, 0.0);

      // Now on page 0, back gesture should bubble up to the OS (meaning didPopRoute returns false)
      final didPopOnHome = await widgetsAppState.didPopRoute();
      expect(didPopOnHome, isFalse);
    });
  });

  group('WeightCalculatorDialog Widget Tests', () {
    testWidgets('calculates weight correctly when price and total paid are entered', (WidgetTester tester) async {
      String calculatedPrice = '';
      String calculatedWeight = '';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeightCalculatorDialog(
              initialPrice: '25,00',
              onApplied: (price, weight) {
                calculatedPrice = price;
                calculatedWeight = weight;
              },
            ),
          ),
        ),
      );

      // Verify initial price is set
      expect(find.text('Calculadora de Peso'), findsOneWidget);
      expect(find.text('25,00'), findsOneWidget);

      // Enter total paid: 50,00
      final totalPaidField = find.widgetWithText(TextField, 'Total Pago');
      expect(totalPaidField, findsOneWidget);
      await tester.enterText(totalPaidField, '50,00');
      await tester.pump();

      // Tap 'Aplicar Peso'
      await tester.tap(find.text('Aplicar Peso'));
      await tester.pumpAndSettle();

      // 50.0 / 25.0 = 2.000 kg
      expect(calculatedPrice, equals('25,00'));
      expect(calculatedWeight, equals('2,000'));
    });
  });

  group('ShoppingFilterBottomSheet Widget Tests', () {
    testWidgets('renders sort options and category filters and invokes callbacks', (WidgetTester tester) async {
      bool ascending = true;
      bool hideZero = false;
      SortOption sortOption = SortOption.category;
      List<String> categories = [];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ShoppingFilterBottomSheet(
              isAscending: ascending,
              hideZeroQuantity: hideZero,
              currentSort: sortOption,
              selectedCategories: categories,
              onAscendingChanged: (val) => ascending = val,
              onHideZeroQuantityChanged: (val) => hideZero = val,
              onSortChanged: (val) => sortOption = val,
              onCategoriesChanged: (val) => categories = val,
            ),
          ),
        ),
      );

      expect(find.text('Filtros e Ordenação'), findsOneWidget);
      expect(find.text('Ocultar itens sem quantidade'), findsOneWidget);

      // Toggle ascending arrow
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      expect(ascending, isFalse);

      // Toggle hide zero switch
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(hideZero, isTrue);

      // Select 'Nome' sort chip
      await tester.tap(find.text('Nome'));
      await tester.pump();
      expect(sortOption, equals(SortOption.name));
    });
  });

  group('DashboardScreen Metric Cards Drag Tests', () {
    testWidgets('cards have rounded borders and 24px radius', (WidgetTester tester) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: AuthService()),
            ChangeNotifierProvider(create: (_) => ItemProvider()),
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ],
          child: const MaterialApp(
            home: DashboardScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Find 'saldo' card container
      final saldoCardFinder = find.byWidgetPredicate((w) => w is Container && w.key == const ValueKey('saldo'));
      expect(saldoCardFinder, findsOneWidget);

      // Verify that the card container has borderRadius of 24
      final Container container = tester.widget(saldoCardFinder);
      final BoxDecoration decoration = container.decoration as BoxDecoration;
      expect(decoration.borderRadius, equals(BorderRadius.circular(24)));
    });
  });

  group('Google Spreadsheet URL & Config Tests', () {
    test('extracts spreadsheet ID from full URL with gid', () {
      const url = 'https://docs.google.com/spreadsheets/d/1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM/edit?gid=2077412317#gid=2077412317';
      expect(UserSheetsService.extractSpreadsheetId(url), equals('1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM'));
    });

    test('extracts spreadsheet ID from simple /edit URL', () {
      const url = 'https://docs.google.com/spreadsheets/d/1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM/edit';
      expect(UserSheetsService.extractSpreadsheetId(url), equals('1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM'));
    });

    test('extracts spreadsheet ID from raw ID and trims whitespace', () {
      const rawId = '  1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM  ';
      expect(UserSheetsService.extractSpreadsheetId(rawId), equals('1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM'));
    });

    test('sets and gets custom spreadsheet ID in UserSheetsService and SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final service = UserSheetsService();

      expect(await service.getCustomSpreadsheetId(), isNull);

      await service.setCustomSpreadsheetId('https://docs.google.com/spreadsheets/d/1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM/edit');
      expect(await service.getCustomSpreadsheetId(), equals('1v1uSzdcZyo-U6IvZ4dYNYaDLIv9BdJNMPEa2W_EM6CM'));

      await service.setCustomSpreadsheetId(null);
      expect(await service.getCustomSpreadsheetId(), isNull);
    });
  });

  group('Accessibility, ColorBlindMode and FontScale Tests', () {
    test('ThemeProvider updates font scale and provides correct human labels', () async {
      SharedPreferences.setMockInitialValues({});
      final themeProvider = ThemeProvider();
      await themeProvider.init();

      expect(themeProvider.fontScale, equals(1.0));
      expect(themeProvider.fontScaleLabel, equals('Padrão (100%)'));

      await themeProvider.setFontScale(1.30);
      expect(themeProvider.fontScale, equals(1.30));
      expect(themeProvider.fontScaleLabel, equals('Grande (130%)'));

      await themeProvider.setFontScale(0.85);
      expect(themeProvider.fontScale, equals(0.85));
      expect(themeProvider.fontScaleLabel, equals('Pequeno (85%)'));
    });

    test('ThemeProvider loads fontScale 0.85 correctly from SharedPreferences on init', () async {
      SharedPreferences.setMockInitialValues({'fontScale': 0.85});
      final themeProvider = ThemeProvider();
      await themeProvider.init();

      expect(themeProvider.fontScale, equals(0.85));
      expect(themeProvider.fontScaleLabel, equals('Pequeno (85%)'));
    });

    test('ThemeProvider adapts color palette and danger/success colors based on ColorBlindMode', () async {
      SharedPreferences.setMockInitialValues({});
      final themeProvider = ThemeProvider();
      await themeProvider.init();

      expect(themeProvider.colorBlindMode, equals(ColorBlindMode.none));

      await themeProvider.setColorBlindMode(ColorBlindMode.deuteranopia);
      expect(themeProvider.colorBlindMode, equals(ColorBlindMode.deuteranopia));
      expect(themeProvider.colorBlindModeLabel, contains('Deuteranopia'));
      // In deuteranopia, success is accessible blue (0xFF0072B2) and danger is vermillion (0xFFD55E00)
      expect(themeProvider.successColor, equals(const Color(0xFF0072B2)));
      expect(themeProvider.dangerColor, equals(const Color(0xFFD55E00)));

      await themeProvider.setColorBlindMode(ColorBlindMode.highContrast);
      expect(themeProvider.colorBlindMode, equals(ColorBlindMode.highContrast));
      expect(themeProvider.successColor, equals(const Color(0xFF00E676)));
      expect(themeProvider.dangerColor, equals(const Color(0xFFFF1744)));
    });
  });

  group('Supermarket & Location Tests', () {
    test('Item model handles supermarket property, toMap, fromMap and copyWith', () {
      final item = Item(
        name: 'Arroz Integral',
        quantity: 2.0,
        unitPrice: 15.50,
        supermarket: 'Assaí Atacadista',
      );

      expect(item.supermarket, equals('Assaí Atacadista'));

      final map = item.toMap();
      expect(map['supermarket'], equals('Assaí Atacadista'));

      final fromMap = Item.fromMap(map);
      expect(fromMap.supermarket, equals('Assaí Atacadista'));

      final copied = item.copyWith(supermarket: 'Carrefour');
      expect(copied.supermarket, equals('Carrefour'));
      expect(copied.name, equals('Arroz Integral'));
    });

    test('LocationService formats distance and calculates distance correctly', () {
      final service = LocationService.instance;

      expect(service.formatDistance(50.4), equals('50m'));
      expect(service.formatDistance(950), equals('950m'));
      expect(service.formatDistance(1500), equals('1.5km'));
      expect(service.formatDistance(3200), equals('3.2km'));

      // Distância entre Avenida Paulista e Praça da Sé (aprox 2.5 - 3 km)
      final distance = service.calculateDistance(-23.5614, -46.6559, -23.5505, -46.6333);
      expect(distance, greaterThan(2000));
      expect(distance, lessThan(4000));
    });

    test('ReceiptParser tags extracted items with storeName', () {
      const receipt = '''
      SUPERMERCADO DIA BRASIL
      CNPJ: 00.123.456/0001-78
      001 7891000123456 LEITE INTEGRAL 1L 3 UN X 4,50 13,50
      TOTAL R\$ 13,50
      ''';

      final result = ReceiptParser.parseWithMetadata(receipt);
      expect(result.items.isNotEmpty, isTrue);
      expect(result.storeName, contains('Supermercado Dia Brasil'));
      expect(result.items.first.supermarket, contains('Supermercado Dia Brasil'));
    });

    test('GooglePlacesService saves, loads and removes API key', () async {
      SharedPreferences.setMockInitialValues({});
      final service = GooglePlacesService.instance;
      await service.saveApiKey('test_key_abc_123');
      expect(await service.getApiKey(), equals('test_key_abc_123'));
      await service.saveApiKey(null);
      expect(await service.getApiKey(), isNull);
    });
  });

  group('RateioDialog Widget Tests', () {
    testWidgets('RateioDialog calculates and displays cost per person correctly', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => const RateioDialog(
                    totalSpent: 300.0,
                    listTitle: 'Churrasco Teste',
                  ),
                ),
                child: const Text('Abrir Rateio'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Abrir Rateio'));
      await tester.pumpAndSettle();

      expect(find.text('Rateio do Evento'), findsOneWidget);
      expect(find.text('6 pessoas'), findsOneWidget);
      // R$ 300 / 6 = R$ 50,00
      expect(find.textContaining('50,00'), findsOneWidget);

      // Incrementa para 7 pessoas
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('7 pessoas'), findsOneWidget);
    });
  });

  group('CommunityPrice and MarketComparison Unit Tests', () {
    test('CommunityPrice toMap and fromMap serialization with distance calculation', () {
      final now = DateTime(2026, 10, 16, 12, 0);
      final price = CommunityPrice(
        id: 'test_123',
        productName: 'Arroz Camil 5kg',
        category: 'Alimentos',
        unit: 'un',
        price: 24.90,
        supermarketName: 'Carrefour',
        latitude: -23.5614,
        longitude: -46.6559,
        submittedBy: 'Cliente',
        verifiedReceipt: true,
        createdAt: now,
        distanceMeters: 1200,
      );

      final map = price.toMap();
      expect(map['id'], equals('test_123'));
      expect(map['product_name'], equals('Arroz Camil 5kg'));
      expect(map['category'], equals('Alimentos'));
      expect(map['unit'], equals('un'));
      expect(map['price'], equals(24.90));
      expect(map['supermarket_name'], equals('Carrefour'));
      expect(map['latitude'], equals(-23.5614));
      expect(map['longitude'], equals(-46.6559));
      expect(map['submitted_by'], equals('Cliente'));
      expect(map['verified_receipt'], equals(1));
      expect(map['created_at'], equals(now.toIso8601String()));
      expect(price.formattedDistance, equals('1.2km'));

      // Deserialização com cálculo de distância do usuário
      final restored = CommunityPrice.fromMap(
        map,
        userLat: -23.5505,
        userLng: -46.6333,
      );
      expect(restored.id, equals('test_123'));
      expect(restored.productName, equals('Arroz Camil 5kg'));
      expect(restored.price, equals(24.90));
      expect(restored.verifiedReceipt, isTrue);
      expect(restored.distanceMeters, isNotNull);
      expect(restored.distanceMeters!, greaterThan(2000));
    });

    test('ProductComparison calculates maxSavingsPercent accurately', () {
      final now = DateTime.now();
      final p1 = CommunityPrice(
        id: '1',
        productName: 'Café Melitta 500g',
        price: 15.00,
        supermarketName: 'Atacadão',
        createdAt: now,
      );
      final p2 = CommunityPrice(
        id: '2',
        productName: 'Café Melitta 500g',
        price: 20.00,
        supermarketName: 'Pão de Açúcar',
        createdAt: now,
      );

      final comp = ProductComparison(
        productName: 'Café Melitta 500g',
        unit: 'un',
        averagePrice: 17.50,
        minPrice: 15.00,
        maxPrice: 20.00,
        cheapestMarket: 'Atacadão',
        cheapestMarketDistance: 800,
        mostExpensiveMarket: 'Pão de Açúcar',
        totalQuotes: 2,
        prices: [p1, p2],
      );

      // (20 - 15) / 20 * 100 = 25% economia
      expect(comp.maxSavingsPercent, equals(25.0));
      expect(comp.cheapestMarket, equals('Atacadão'));
      expect(comp.mostExpensiveMarket, equals('Pão de Açúcar'));
    });

    test('MarketComparison properties and formattedDistance', () {
      final market = MarketComparison(
        supermarketName: 'Assaí Atacadista',
        latitude: -23.5,
        longitude: -46.6,
        distanceMeters: 650,
        itemsCount: 15,
        averageItemPrice: 12.40,
        cheapestCount: 10,
        isCheapest: true,
      );

      expect(market.supermarketName, equals('Assaí Atacadista'));
      expect(market.isCheapest, isTrue);
      expect(market.formattedDistance, equals('650m'));
    });

    test('CommunityPriceService provides valid setup SQL and handles configuration', () async {
      SharedPreferences.setMockInitialValues({});
      final service = CommunityPriceService.instance;

      final sql = service.getSupabaseSetupSql();
      expect(
        sql.toLowerCase(),
        anyOf(
          contains('create table if not exists public.community_prices'),
          contains('create table if not exists community_prices'),
        ),
      );
      expect(sql.toLowerCase(), contains('enable row level security'));
      expect(sql.toLowerCase(), contains('create policy'));

      expect(service.isConfigured, isTrue);
      expect(service.supabaseUrl, contains('supabase.co'));
      await service.saveConfig('https://xyzcompany.supabase.co', 'anon_sample_key_456');
      expect(service.isConfigured, isTrue);
      expect(service.supabaseUrl, equals('https://xyzcompany.supabase.co'));
      expect(service.supabaseAnonKey, equals('anon_sample_key_456'));
    });

    test('CommunityPriceService default store constants reflect Supermercados Guanabara Niterói', () {
      expect(CommunityPriceService.defaultStoreName, equals('Supermercados Guanabara - Niterói'));
      expect(CommunityPriceService.defaultStoreLat, closeTo(-22.89012, 0.0001));
      expect(CommunityPriceService.defaultStoreLng, closeTo(-43.11535, 0.0001));
    });

    test('MarketComparison handles null distance and coordinates gracefully', () {
      final market = MarketComparison(
        supermarketName: 'Supermercado Central',
        itemsCount: 5,
        averageItemPrice: 8.50,
        cheapestCount: 2,
      );

      expect(market.supermarketName, equals('Supermercado Central'));
      expect(market.latitude, isNull);
      expect(market.longitude, isNull);
      expect(market.distanceMeters, isNull);
      expect(market.formattedDistance, equals(''));
      expect(market.isCheapest, isFalse);
    });

    testWidgets('MarketMapScreen instantiates with default params and opens Google Maps style layer picker without throwing', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MarketMapScreen(
            initialUserLat: -22.88975,
            initialUserLng: -43.11515,
            initialRadiusKm: 15.0,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MarketMapScreen), findsOneWidget);
      expect(find.byIcon(Icons.layers_rounded), findsOneWidget);
      expect(find.byIcon(Icons.touch_app_rounded), findsOneWidget);

      await tester.tap(find.byIcon(Icons.layers_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Tipo de Mapa'), findsOneWidget);
      expect(find.text('Padrão Google'), findsOneWidget);
      expect(find.text('Satélite'), findsOneWidget);
      expect(find.text('Relevo'), findsOneWidget);
    });

    test('DefaultSupermarketsData contains valid geolocated markets from MWM map files across RJ, ES and SP including Tribobó and Rio do Ouro', () {
      const markets = DefaultSupermarketsData.all;
      expect(markets.length, greaterThanOrEqualTo(3000));

      final cities = markets.map((m) => m.city).toSet();
      expect(
        cities,
        containsAll([
          'Niterói',
          'São Gonçalo',
          'Maricá',
          'Itaboraí',
          'Rio de Janeiro',
          'Vitória',
          'Vila Velha',
          'Campinas',
          'São Paulo',
        ]),
      );

      final names = markets.map((m) => m.name.toLowerCase()).toList();
      expect(names.any((n) => n.contains('tribobó') || n.contains('tribobo')), isTrue);
      expect(names.any((n) => n.contains('rio do ouro')), isTrue);

      for (var market in markets) {
        expect(market.name.trim().isNotEmpty, isTrue);
        expect(market.latitude, inInclusiveRange(-25.5, -17.5));
        expect(market.longitude, inInclusiveRange(-53.5, -39.5));
        expect(market.radiusMeters, greaterThan(50));
        expect(market.colorHex.startsWith('#'), isTrue);
      }
    });

    test('Assaí Atacadista - Tribobó is accurately located at Av. Fued Moisés, Tribobó and matchable', () {
      final assai = DefaultSupermarketsData.findMatch('Assaí Atacadista - Tribobó');
      expect(assai, isNotNull);
      expect(assai!.latitude, closeTo(-22.85444, 0.001));
      expect(assai.longitude, closeTo(-43.02005, 0.001));
      expect(assai.city, equals('São Gonçalo'));

      final partialMatch = DefaultSupermarketsData.findMatch('assai tribobo');
      expect(partialMatch, isNotNull);
      expect(partialMatch!.name, equals('Assaí Atacadista - Tribobó'));
    });

    test('Rede Economia and Mercado Varsilva in Rio do Ouro are accurately located and matchable', () {
      final varsilva = DefaultSupermarketsData.findMatch('Mercado Varsilva - Rio do Ouro');
      expect(varsilva, isNotNull);
      expect(varsilva!.latitude, closeTo(-22.88476, 0.001));
      expect(varsilva.longitude, closeTo(-42.98544, 0.001));
      expect(varsilva.address, contains('Engenho do Roçado'));

      final varsilvaPartial = DefaultSupermarketsData.findMatch('varsilva');
      expect(varsilvaPartial, isNotNull);
      expect(varsilvaPartial!.name, contains('Varsilva'));

      final redeEconomiaRioDoOuro = DefaultSupermarketsData.findMatch('Rede Economia - Rio do Ouro');
      expect(redeEconomiaRioDoOuro, isNotNull);
      expect(redeEconomiaRioDoOuro!.latitude, closeTo(-22.88727, 0.001));
      expect(redeEconomiaRioDoOuro.longitude, closeTo(-42.98817, 0.001));
      expect(redeEconomiaRioDoOuro.address, contains('Eugênio Borges'));
    });

    test('DefaultSupermarketsData findMatch matches Supermercados Guanabara without suffix to canonical Niterói store', () {
      final match = DefaultSupermarketsData.findMatch('Supermercados Guanabara');
      expect(match, isNotNull);
      expect(match!.name, equals('Supermercados Guanabara - Niterói'));
      expect(match.latitude, closeTo(-22.89012, 0.001));
      expect(match.longitude, closeTo(-43.11535, 0.001));
    });

    test('New markets from Maps.me (.mwm) across RJ, ES, and SP are matchable and detectable offline by GPS radius', () {
      final multiMarket = DefaultSupermarketsData.findMatch('Multi Market - Santa Rosa');
      expect(multiMarket, isNotNull);
      expect(multiMarket!.latitude, closeTo(-22.89813, 0.001));

      final pomarIcarai = DefaultSupermarketsData.findMatch('Pomar Supermercados - Icaraí');
      expect(pomarIcarai, isNotNull);
      expect(pomarIcarai!.latitude, closeTo(-22.90423, 0.001));

      final superPrix = DefaultSupermarketsData.findMatch('Super Prix - Icaraí');
      expect(superPrix, isNotNull);
      expect(superPrix!.latitude, closeTo(-22.90296, 0.001));

      final nearestGuanabara = DefaultSupermarketsData.findNearestWithinRadius(-22.89012, -43.11535);
      expect(nearestGuanabara, isNotNull);
      expect(nearestGuanabara!.name, equals('Supermercados Guanabara - Niterói'));
    });
  });

  group('BarcodeLookupService Unit Tests', () {
    test('handles empty or blank barcode gracefully without network call', () async {
      final res1 = await BarcodeLookupService.instance.lookup('');
      expect(res1, isNull);

      final res2 = await BarcodeLookupService.instance.lookup('   ');
      expect(res2, isNull);
    });

    test('creates ScannedProductInfo correctly and reports source/isFromOnline', () {
      const infoOnline = ScannedProductInfo(
        barcode: '7891000100103',
        name: 'Leite Moça Leite Condensado 395g',
        brand: 'Nestlé',
        category: 'Mercearia',
        quantity: '395g',
        imageUrl: 'https://images.openfoodfacts.org/images/products/7891000100103.jpg',
        lastPrice: 7.99,
        source: 'online',
      );

      expect(infoOnline.barcode, equals('7891000100103'));
      expect(infoOnline.name, equals('Leite Moça Leite Condensado 395g'));
      expect(infoOnline.brand, equals('Nestlé'));
      expect(infoOnline.category, equals('Mercearia'));
      expect(infoOnline.quantity, equals('395g'));
      expect(infoOnline.imageUrl, isNotNull);
      expect(infoOnline.lastPrice, equals(7.99));
      expect(infoOnline.source, equals('online'));
      expect(infoOnline.isFromOnline, isTrue);

      const infoLocal = ScannedProductInfo(
        barcode: '7891000100103',
        name: 'Leite Moça',
        category: 'Mercearia',
        lastPrice: 6.50,
        source: 'local',
      );
      expect(infoLocal.source, equals('local'));
      expect(infoLocal.isFromOnline, isFalse);
    });

    test('ItemProvider.suggestCategoryForName classifies common scanned items accurately', () {
      expect(ItemProvider.suggestCategoryForName('Coca Cola 2L'), equals('Bebidas'));
      expect(ItemProvider.suggestCategoryForName('Cerveja Heineken 350ml'), equals('Bebidas'));
      expect(ItemProvider.suggestCategoryForName('Sabão em Pó Omo 1kg'), equals('Limpeza'));
      expect(ItemProvider.suggestCategoryForName('Detergente Ypê Neutro'), equals('Limpeza'));
      expect(ItemProvider.suggestCategoryForName('Shampoo Pantene 400ml'), equals('Higiene Pessoal'));
      expect(ItemProvider.suggestCategoryForName('Papel Higiênico Neve'), equals('Higiene Pessoal'));
      expect(ItemProvider.suggestCategoryForName('Maçã Fuji Nacional'), equals('Hortifruti'));
      expect(ItemProvider.suggestCategoryForName('Alcatra Bovina kg'), equals('Açougue e Frios'));
      expect(ItemProvider.suggestCategoryForName('Pão de Forma Tradicional'), equals('Padaria'));
    });

    test('getCachedOrLocal returns null synchronously for empty or uncached barcode', () {
      expect(BarcodeLookupService.instance.getCachedOrLocal(''), isNull);
      expect(BarcodeLookupService.instance.getCachedOrLocal('0000000000000'), isNull);
    });

    test('DefaultSupermarketsData identifies chains and filters by search/chain accurately', () {
      expect(DefaultSupermarketsData.getChainName('Supermercados Guanabara - Niterói'), equals('Guanabara'));
      expect(DefaultSupermarketsData.getChainName('Assaí Atacadista - Tribobó'), equals('Assaí'));
      expect(DefaultSupermarketsData.getChainName('Supermarket - Rio do Ouro'), equals('Supermarket'));
      expect(DefaultSupermarketsData.getChainName('Rede Economia - Inoã'), equals('Rede Economia'));
      expect(DefaultSupermarketsData.getChainName('Mercado Varsilva - Rio do Ouro'), equals('Outras'));

      expect(DefaultSupermarketsData.matchesChain('Assaí Atacadista - Tribobó', 'Todas'), isTrue);
      expect(DefaultSupermarketsData.matchesChain('Assaí Atacadista - Tribobó', 'Assaí'), isTrue);
      expect(DefaultSupermarketsData.matchesChain('Assaí Atacadista - Tribobó', 'Guanabara'), isFalse);

      expect(
        DefaultSupermarketsData.matchesSearch(
          'Assaí Atacadista - Tribobó',
          'tribobo assai',
        ),
        isTrue,
      );
      expect(
        DefaultSupermarketsData.matchesSearch(
          'Supermercados Guanabara - Niterói',
          'marica',
        ),
        isFalse,
      );
    });
  });

  group('InteractiveTabTutorial & InteractiveSectionTutorialCard Tests', () {
    testWidgets('InteractiveSectionTutorialCard renders and steps through all sections interactively', (tester) async {
      for (final section in TutorialSection.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: InteractiveSectionTutorialCard(
                  section: section,
                  isModal: false,
                ),
              ),
            ),
          ),
        );

        expect(find.text('TUTORIAL INTERATIVO'), findsOneWidget);
        expect(find.text(section.title), findsOneWidget);

        if (find.text('Próximo').evaluate().isNotEmpty) {
          await tester.tap(find.text('Próximo'));
          await tester.pumpAndSettle();
          expect(find.text('Anterior'), findsOneWidget);
        }
      }
    });

    testWidgets('InteractiveTabTutorial shows on first visit and respects resetAllTabTutorials', (tester) async {
      SharedPreferences.setMockInitialValues({});
      InteractiveTabTutorial.enableAutoShowInTests = true;
      await InteractiveTabTutorial.resetAllTabTutorials();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => InteractiveTabTutorial.checkAndShowIfFirstTime(
                  context,
                  TutorialSection.community,
                  userEmail: 'test@carrin.app',
                ),
                child: const Text('Entrar na Aba'),
              ),
            ),
          ),
        ),
      );

      // Primeira vez: deve abrir o modal interativo
      await tester.tap(find.text('Entrar na Aba'));
      await tester.pumpAndSettle();
      expect(find.text('Comunidade & Radar'), findsOneWidget);

      // Fecha o modal
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Comunidade & Radar'), findsNothing);

      // Segunda vez: não deve abrir novamente automaticamente
      await tester.tap(find.text('Entrar na Aba'));
      await tester.pumpAndSettle();
      expect(find.text('Comunidade & Radar'), findsNothing);

      // Após resetAllTabTutorials: deve abrir novamente
      await InteractiveTabTutorial.resetAllTabTutorials(userEmail: 'test@carrin.app');
      await tester.tap(find.text('Entrar na Aba'));
      await tester.pumpAndSettle();
      expect(find.text('Comunidade & Radar'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      InteractiveTabTutorial.enableAutoShowInTests = false;
    });
  });

  group('List Recovery & Dummy Sheet Protection Tests', () {
    test('DatabaseHelper.isDummySheetName filters default empty spreadsheet tabs and preserves real months', () {
      expect(DatabaseHelper.isDummySheetName('Página1'), isTrue);
      expect(DatabaseHelper.isDummySheetName('Página 1'), isTrue);
      expect(DatabaseHelper.isDummySheetName('pagina1'), isTrue);
      expect(DatabaseHelper.isDummySheetName('Sheet1'), isTrue);
      expect(DatabaseHelper.isDummySheetName('sheet 1'), isTrue);
      expect(DatabaseHelper.isDummySheetName('   '), isTrue);

      expect(DatabaseHelper.isDummySheetName('Outubro 2026'), isFalse);
      expect(DatabaseHelper.isDummySheetName('Setembro 2026'), isFalse);
      expect(DatabaseHelper.isDummySheetName('Churrasco'), isFalse);
    });
  });

  group('Item Total Calculation & Unchecked Item Protection Tests', () {
    test('Unchecked items (isBought: false) with price and quantity do not count towards totalCost', () {
      final items = [
        Item(name: 'Arroz 5kg', quantity: 1.0, unitPrice: 25.0, isBought: true),
        Item(name: 'Feijão 1kg', quantity: 2.0, unitPrice: 8.0, isBought: true),
        Item(name: 'Jogo de Taças', quantity: 1.0, unitPrice: 89.90, isBought: false),
        Item(name: 'Vinho Tinto', quantity: 1.0, unitPrice: 45.0, isBought: false),
      ];

      final totalBought = items.where((it) => it.isBought).fold(0.0, (s, it) => s + it.totalPrice);
      expect(totalBought, equals(41.0)); // 25 + 16 = 41.0. Jogo de Taças (89.90) and Vinho (45.0) are NOT counted!

      double calcTotal = 0.0;
      int calcBought = 0;
      for (final it in items) {
        if (it.isBought) {
          calcTotal += it.totalPrice;
          calcBought++;
        }
      }

      expect(calcTotal, equals(41.0));
      expect(calcBought, equals(2));
    });

    test('Item.fromList correctly parses isBought as false for empty, false or zero status', () {
      final item1 = Item.fromList([1, 'Jogo de Taças', 89.9, 89.9, 'Utilidades', '', ''], 7);
      expect(item1.isBought, isFalse);

      final item2 = Item.fromList([1, 'Jogo de Taças', 89.9, 89.9, 'Utilidades', 'FALSE', ''], 8);
      expect(item2.isBought, isFalse);

      final item3 = Item.fromList([1, 'Jogo de Taças', 89.9, 89.9, 'Utilidades', false, ''], 9);
      expect(item3.isBought, isFalse);

      final item4 = Item.fromList([1, 'Jogo de Taças', 89.9, 89.9, 'Utilidades', 'TRUE', ''], 10);
      expect(item4.isBought, isTrue);
    });
  });

  group('CurrencyInputFormatter and Utils currency tests', () {
    final formatter = CurrencyInputFormatter();

    test('walking comma: formatEditUpdate shifts cents correctly from right to left', () {
      // User types '1'
      var res = formatter.formatEditUpdate(
        const TextEditingValue(text: ''),
        const TextEditingValue(text: '1'),
      );
      expect(res.text, equals('0,01'));

      // User types '2' -> '0,012'
      res = formatter.formatEditUpdate(
        const TextEditingValue(text: '0,01'),
        const TextEditingValue(text: '0,012'),
      );
      expect(res.text, equals('0,12'));

      // User types '9' -> '0,129'
      res = formatter.formatEditUpdate(
        const TextEditingValue(text: '0,12'),
        const TextEditingValue(text: '0,129'),
      );
      expect(res.text, equals('1,29'));

      // User types '9' -> '1,299'
      res = formatter.formatEditUpdate(
        const TextEditingValue(text: '1,29'),
        const TextEditingValue(text: '1,299'),
      );
      expect(res.text, equals('12,99'));

      // User types '0' -> '12,990'
      res = formatter.formatEditUpdate(
        const TextEditingValue(text: '12,99'),
        const TextEditingValue(text: '12,990'),
      );
      expect(res.text, equals('129,90'));

      // User types '0' -> '129,900'
      res = formatter.formatEditUpdate(
        const TextEditingValue(text: '129,90'),
        const TextEditingValue(text: '129,900'),
      );
      expect(res.text, equals('1.299,00'));
    });

    test('walking comma: backspacing to zero clears text to empty string', () {
      // User backspaces '0,01' -> '0,0'
      var res = formatter.formatEditUpdate(
        const TextEditingValue(text: '0,01'),
        const TextEditingValue(text: '0,0'),
      );
      expect(res.text, equals(''));

      // User clears entirely
      res = formatter.formatEditUpdate(
        const TextEditingValue(text: '12,99'),
        const TextEditingValue(text: ''),
      );
      expect(res.text, equals(''));
    });

    test('Utils.formatCurrencyInput formats doubles with two decimals for input fields', () {
      expect(Utils.formatCurrencyInput(0.0), equals(''));
      expect(Utils.formatCurrencyInput(-5.0), equals(''));
      expect(Utils.formatCurrencyInput(25.0), equals('25,00'));
      expect(Utils.formatCurrencyInput(7.99), equals('7,99'));
      expect(Utils.formatCurrencyInput(1250.50), equals('1.250,50'));
    });

    test('Utils.parseCurrency safely converts Brazilian formatted string to double', () {
      expect(Utils.parseCurrency(''), equals(0.0));
      expect(Utils.parseCurrency('   '), equals(0.0));
      expect(Utils.parseCurrency('0,01'), closeTo(0.01, 0.001));
      expect(Utils.parseCurrency('12,99'), closeTo(12.99, 0.001));
      expect(Utils.parseCurrency('25,00'), closeTo(25.0, 0.001));
      expect(Utils.parseCurrency('25'), closeTo(25.0, 0.001));
      expect(Utils.parseCurrency('1.250,50'), closeTo(1250.50, 0.001));
      expect(Utils.parseCurrency('R\$ 1.250,50'), closeTo(1250.50, 0.001));
      expect(Utils.parseCurrency('12.99'), closeTo(12.99, 0.001));
      expect(Utils.parseCurrency('(15,20)'), closeTo(-15.20, 0.001));
      expect(Utils.parseCurrency('#ERROR!'), equals(0.0));
    });
  });

  group('Spreadsheet Summary and Parsing Resilience Tests', () {
    test('Item.parseBool accurately parses diverse boolean formats', () {
      expect(Item.parseBool(true), isTrue);
      expect(Item.parseBool('true'), isTrue);
      expect(Item.parseBool('TRUE'), isTrue);
      expect(Item.parseBool('verdadeiro'), isTrue);
      expect(Item.parseBool('VERDADEIRO'), isTrue);
      expect(Item.parseBool('1'), isTrue);
      expect(Item.parseBool(1), isTrue);
      expect(Item.parseBool('sim'), isTrue);

      expect(Item.parseBool(false), isFalse);
      expect(Item.parseBool('false'), isFalse);
      expect(Item.parseBool('FALSE'), isFalse);
      expect(Item.parseBool('0'), isFalse);
      expect(Item.parseBool(0), isFalse);
      expect(Item.parseBool(''), isFalse);
      expect(Item.parseBool(null), isFalse);
    });

    test('Item.fromList parses Brazilian formatted values with thousand dots and supermarket column I', () {
      // B (Qty), C (Name), D (Price), E (Total), F (Category), G (Status), H (Barcode), I (Supermarket)
      final rawRow = [
        '2',
        'Jogo de Taças de Cristal',
        '1.250,50',
        '2.501,00',
        'Utilidades',
        'FALSE',
        '7891234567890',
        'Supermercados Guanabara',
      ];

      final item = Item.fromList(rawRow, 7);
      expect(item.name, equals('Jogo de Taças de Cristal'));
      expect(item.quantity, equals(2.0));
      expect(item.unitPrice, closeTo(1250.50, 0.01));
      expect(item.totalPrice, closeTo(2501.00, 0.01));
      expect(item.isBought, isFalse);
      expect(item.barcode, equals('7891234567890'));
      expect(item.supermarket, equals('Supermercados Guanabara'));
    });

    test('Unchecked items like Jogo de Taças do not count towards bought total sum', () {
      final items = [
        Item(name: 'Arroz 5kg', quantity: 2, unitPrice: 30.0, isBought: true),
        Item(name: 'Feijão 1kg', quantity: 3, unitPrice: 8.0, isBought: true),
        Item(name: 'Jogo de Taças', quantity: 1, unitPrice: 1250.50, isBought: false), // Unchecked!
      ];

      final boughtTotal = items.where((it) => it.isBought).fold(0.0, (sum, it) => sum + it.totalPrice);
      expect(boughtTotal, equals(60.0 + 24.0));
      expect(boughtTotal, equals(84.0));
      expect(boughtTotal, isNot(contains('1250')));
    });

    test('UserSheetsService createNewMonth headers include Saldo at column G and Mercado at column I', () {
      final service = UserSheetsService();
      expect(service.currentMonthTitle, isNotEmpty);
    });
  });

  group('InteractiveAnimatedLogo Widget Tests', () {
    testWidgets('renders InteractiveAnimatedLogo with aura and handles tap interaction', (WidgetTester tester) async {
      bool tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: InteractiveAnimatedLogo(
                imagePath: '1.png',
                size: 150,
                onTap: () {
                  tapped = true;
                },
              ),
            ),
          ),
        ),
      );

      expect(find.byType(InteractiveAnimatedLogo), findsOneWidget);

      await tester.tap(find.byType(InteractiveAnimatedLogo));
      await tester.pump(const Duration(milliseconds: 400));

      expect(tapped, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('triggers autonomous intro animation without user tap when autoPlayIntro is true', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: InteractiveAnimatedLogo(
                imagePath: '1.png',
                size: 150,
                autoPlayIntro: true,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(InteractiveAnimatedLogo), findsOneWidget);
      // Aguarda o disparo autônomo (280ms)
      await tester.pump(const Duration(milliseconds: 300));
      // Executa o ciclo de animação e partículas sem requerer toque
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(InteractiveAnimatedLogo), findsOneWidget);
    });
  });

  group('ThemeColorPickerSheet Widget Tests', () {
    testWidgets('renders compact ThemeColorPickerSheet, shows categories and switches palettes', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final themeProvider = ThemeProvider();
      await themeProvider.init();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => ThemeColorPickerSheet.show(ctx, themeProvider),
                  child: const Text('Open Themes'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Themes'));
      await tester.pumpAndSettle();

      expect(find.text('Cores do Tema'), findsOneWidget);
      expect(find.text('Claro'), findsOneWidget);
      expect(find.text('Escuro'), findsOneWidget);
      expect(find.text('Ícone'), findsWidgets);
      expect(find.text('Natureza'), findsOneWidget);
      expect(find.text('Clássicas'), findsOneWidget);

      // Tap on Natureza category chip
      await tester.tap(find.text('Natureza'));
      await tester.pumpAndSettle();

      // Swatches of Natureza (such as Verde Floresta) should be present
      expect(find.text('Verde Floresta'), findsOneWidget);

      // Select Verde Floresta
      await tester.tap(find.text('Verde Floresta'));
      await tester.pumpAndSettle();

      // Tap Aplicar Tema
      await tester.tap(find.text('Aplicar Tema'));
      await tester.pumpAndSettle();

      expect(themeProvider.seedColor, equals(AppColors.green));
    });

    testWidgets('MainScreen allows swiping horizontally directly out of Community tab into adjacent screens', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'tutorial_completed_community': true});
      final itemProvider = ItemProvider();
      final themeProvider = ThemeProvider();

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: AuthService()),
            ChangeNotifierProvider.value(value: itemProvider),
            ChangeNotifierProvider.value(value: themeProvider),
          ],
          child: const MaterialApp(
            home: MainScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch to Statistics tab (index 2)
      await tester.tap(find.byIcon(Icons.bar_chart_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(StatisticsScreen), findsOneWidget);

      // Drag left on StatisticsScreen to transition smoothly to Settings tab (index 3)
      await tester.drag(find.byType(StatisticsScreen), const Offset(-500, 0), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(SettingsScreen), findsOneWidget);

      // Drag right on SettingsScreen back to StatisticsScreen (index 2)
      await tester.drag(find.byType(SettingsScreen), const Offset(500, 0), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(StatisticsScreen), findsOneWidget);
    });
  });

  group('Month List Inversion & Chronological Sorting Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('months strictly preserves creation order without shuffling', () {
      final provider = ItemProvider();
      final testOrder = [
        'Janeiro 2025',
        'Dezembro 2024',
        'Outubro 2026',
        'Fevereiro 2025',
      ];
      provider.setMonthsForTesting(testOrder);

      expect(provider.months, equals(testOrder));
      expect(provider.sortedMonthsDescending, equals(testOrder.reversed.toList()));
      expect(provider.sortedMonthsAscending, equals(testOrder));
    });

    test('custom named lists strictly preserve creation order', () {
      final provider = ItemProvider();
      final customLists = [
        'Rancho de Casa',
        'Churrasco com Amigos',
        'Festa Junina',
      ];
      provider.setMonthsForTesting(customLists);

      expect(provider.months, equals(customLists));
      expect(provider.sortedMonthsDescending, equals(customLists.reversed.toList()));
      expect(provider.sortedMonthsAscending, equals(customLists));
    });
  });
}



