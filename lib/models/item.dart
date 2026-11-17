import '../services/utils.dart';

/// Represents a single shopping list item.
/// 
/// Contains data about the product, its quantity, price, category, and
/// synchronization status with Google Sheets.
class Item {
  /// The row index in the Google Sheets worksheet.
  final int? index;
  
  String name;
  double quantity;
  double unitPrice;
  bool isKg;
  String category;
  bool isBought;
  String? barcode;
  String? supermarket;

  Item({
    this.index,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.isKg = false,
    this.category = 'Outros',
    this.isBought = false,
    this.barcode,
    this.supermarket,
  });

  /// Calculates the total price for this item based on quantity and unit price.
  double get totalPrice => quantity * unitPrice;

  /// Creates an [Item] from a raw list of values fetched from Google Sheets.
  /// 
  /// Expected order of columns: B (Qty), C (Name), D (Price), E (Total), F (Category), G (Status), H (Barcode), I (Supermarket).
  factory Item.fromList(List<dynamic> list, int rowIndex) {
    return Item(
      index: rowIndex,
      quantity: _parseNum(list.isNotEmpty ? list[0] : 0),
      name: list.length > 1 ? list[1].toString() : '',
      unitPrice: _parseNum(list.length > 2 ? list[2] : 0),
      isKg: list.length > 1 && list[1].toString().toLowerCase().contains('(kg)'), 
      category: list.length > 4 ? list[4].toString() : 'Outros',
      isBought: list.length > 5 ? _parseBool(list[5]) : false,
      barcode: list.length > 6 ? parseBarcode(list[6]) : null,
      supermarket: list.length > 7 && list[7] != null && list[7].toString().trim().isNotEmpty
          ? list[7].toString().trim()
          : null,
    );
  }

  /// Parses and normalizes barcodes (removes trailing '.0', leading quote escapes, and whitespace).
  /// Rejects corrupted scientific-notation strings produced by spreadsheet auto-formatting.
  static String? parseBarcode(dynamic val) {
    if (val == null) return null;
    String s = val.toString().trim();
    if (s.startsWith("'")) {
      s = s.substring(1).trim();
    }
    if (s.isEmpty || s.toLowerCase() == 'null' || s.toLowerCase() == 'sem gtin') {
      return null;
    }
    if (s.endsWith('.0')) {
      s = s.substring(0, s.length - 2);
    }
    if (RegExp(r'^\d+(?:[.,]\d+)?[eE][+-]?\d+$').hasMatch(s)) {
      return null;
    }
    return s.isNotEmpty ? s : null;
  }

  /// Parses boolean values in various formats (bool, TRUE, VERDADEIRO, 1, etc.)
  static bool parseBool(dynamic val) {
    if (val == null) return false;
    if (val is bool) return val;
    if (val is num) return val == 1;
    final s = val.toString().trim().toLowerCase();
    return s == 'true' || s == 'verdadeiro' || s == '1' || s == 'sim' || s == 'v';
  }

  static bool _parseBool(dynamic val) => parseBool(val);

  /// Parses various numerical formats (including Brazilian R$) into a double.
  static double _parseNum(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    return Utils.parseCurrency(val.toString());
  }

  /// Converts the item into a list format suitable for Google Sheets insertion.
  List<dynamic> toList() {
    return [
      quantity,     // Column B
      name,         // Column C
      unitPrice,    // Column D
      totalPrice,   // Column E
      category,     // Column F
      isBought,     // Column G
      parseBarcode(barcode) ?? '', // Column H
      supermarket ?? '', // Column I
    ];
  }

  /// Converts the item into a Map for local JSON serialization.
  Map<String, dynamic> toMap() {
    return {
      'index': index,
      'name': name,
      'quantity': quantity,
      'unitPrice': unitPrice,
      'isKg': isKg,
      'category': category,
      'isBought': isBought,
      'barcode': barcode,
      'supermarket': supermarket,
    };
  }

  /// Creates an [Item] from a Map (usually from local cache).
  factory Item.fromMap(Map<String, dynamic> map) {
    return Item(
      index: map['index'],
      name: map['name'] ?? '',
      quantity: (map['quantity'] ?? 0.0).toDouble(),
      unitPrice: (map['unitPrice'] ?? 0.0).toDouble(),
      isKg: map['isKg'] ?? false,
      category: map['category'] ?? 'Outros',
      isBought: _parseBool(map['isBought']),
      barcode: parseBarcode(map['barcode']),
      supermarket: map['supermarket']?.toString(),
    );
  }

  /// Clones the current item with updated properties.
  Item copyWith({
    int? index,
    String? name,
    double? quantity,
    double? unitPrice,
    bool? isKg,
    String? category,
    bool? isBought,
    String? barcode,
    String? supermarket,
  }) {
    return Item(
      index: index ?? this.index,
      name: name ?? this.name,
      quantity: quantity ?? this.quantity,
      unitPrice: unitPrice ?? this.unitPrice,
      isKg: isKg ?? this.isKg,
      category: category ?? this.category,
      isBought: isBought ?? this.isBought,
      barcode: barcode != null ? parseBarcode(barcode) : this.barcode,
      supermarket: supermarket ?? this.supermarket,
    );
  }
}
