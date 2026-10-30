import 'dart:math' as math;
import '../services/location_service.dart';

class CommunityPrice {
  final String id;
  final String productName;
  final String? category;
  final String? unit;
  final double price;
  final String supermarketName;
  final double? latitude;
  final double? longitude;
  final String submittedBy;
  final bool verifiedReceipt;
  final DateTime createdAt;
  final double? distanceMeters;

  CommunityPrice({
    required this.id,
    required this.productName,
    this.category,
    this.unit,
    required this.price,
    required this.supermarketName,
    this.latitude,
    this.longitude,
    this.submittedBy = 'Cliente da Comunidade',
    this.verifiedReceipt = false,
    required this.createdAt,
    this.distanceMeters,
  });

  String get formattedDistance {
    if (distanceMeters == null) return '';
    return LocationService.instance.formatDistance(distanceMeters!);
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'product_name': productName,
      'category': category,
      'unit': unit,
      'price': price,
      'supermarket_name': supermarketName,
      'latitude': latitude,
      'longitude': longitude,
      'submitted_by': submittedBy,
      'verified_receipt': verifiedReceipt ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory CommunityPrice.fromMap(Map<String, dynamic> map, {double? userLat, double? userLng}) {
    final lat = (map['latitude'] as num?)?.toDouble();
    final lng = (map['longitude'] as num?)?.toDouble();
    double? dist;

    if (userLat != null && userLng != null && lat != null && lng != null) {
      dist = LocationService.instance.calculateDistance(userLat, userLng, lat, lng);
    }

    DateTime parsedDate;
    try {
      parsedDate = map['created_at'] != null 
          ? DateTime.parse(map['created_at'].toString()) 
          : DateTime.now();
    } catch (_) {
      parsedDate = DateTime.now();
    }

    return CommunityPrice(
      id: map['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      productName: (map['product_name'] ?? '').toString().trim(),
      category: map['category']?.toString(),
      unit: map['unit']?.toString() ?? 'un',
      price: (map['price'] as num?)?.toDouble() ?? 0.0,
      supermarketName: (map['supermarket_name'] ?? 'Supermercado').toString().trim(),
      latitude: lat,
      longitude: lng,
      submittedBy: (map['submitted_by'] ?? 'Cliente da Comunidade').toString(),
      verifiedReceipt: map['verified_receipt'] == 1 || map['verified_receipt'] == true,
      createdAt: parsedDate,
      distanceMeters: dist,
    );
  }
}

class MarketComparison {
  final String supermarketName;
  final double? latitude;
  final double? longitude;
  final double? distanceMeters;
  final int itemsCount;
  final double averageItemPrice;
  final int cheapestCount;
  final bool isCheapest;

  MarketComparison({
    required this.supermarketName,
    this.latitude,
    this.longitude,
    this.distanceMeters,
    required this.itemsCount,
    required this.averageItemPrice,
    required this.cheapestCount,
    this.isCheapest = false,
  });

  MarketComparison copyWith({
    String? supermarketName,
    double? latitude,
    double? longitude,
    double? distanceMeters,
    int? itemsCount,
    double? averageItemPrice,
    int? cheapestCount,
    bool? isCheapest,
  }) {
    return MarketComparison(
      supermarketName: supermarketName ?? this.supermarketName,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      itemsCount: itemsCount ?? this.itemsCount,
      averageItemPrice: averageItemPrice ?? this.averageItemPrice,
      cheapestCount: cheapestCount ?? this.cheapestCount,
      isCheapest: isCheapest ?? this.isCheapest,
    );
  }

  String get formattedDistance {
    if (distanceMeters == null) return '';
    return LocationService.instance.formatDistance(distanceMeters!);
  }
}

class MarketBasketEstimate {
  final String supermarketName;
  final double? latitude;
  final double? longitude;
  final double? distanceMeters;
  final double totalPrice;
  final int matchedItemsCount;
  final int totalRequestedItems;
  final List<CommunityPrice> matchedPrices;
  final List<String> missingItemNames;

  MarketBasketEstimate({
    required this.supermarketName,
    this.latitude,
    this.longitude,
    this.distanceMeters,
    required this.totalPrice,
    required this.matchedItemsCount,
    required this.totalRequestedItems,
    required this.matchedPrices,
    required this.missingItemNames,
  });

  bool get isComplete => matchedItemsCount == totalRequestedItems && totalRequestedItems > 0;
  double get matchPercentage => totalRequestedItems > 0 ? (matchedItemsCount / totalRequestedItems) * 100 : 0.0;
}

class ProductComparison {
  final String productName;
  final String unit;
  final double averagePrice;
  final double minPrice;
  final double maxPrice;
  final String cheapestMarket;
  final double? cheapestMarketDistance;
  final String mostExpensiveMarket;
  final int totalQuotes;
  final List<CommunityPrice> prices;

  ProductComparison({
    required this.productName,
    required this.unit,
    required this.averagePrice,
    required this.minPrice,
    required this.maxPrice,
    required this.cheapestMarket,
    this.cheapestMarketDistance,
    required this.mostExpensiveMarket,
    required this.totalQuotes,
    required this.prices,
  });

  double get maxSavingsPercent {
    if (maxPrice <= 0) return 0.0;
    return math.max(0.0, ((maxPrice - minPrice) / maxPrice) * 100);
  }
}
