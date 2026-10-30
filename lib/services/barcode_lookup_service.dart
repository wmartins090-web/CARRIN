import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/item.dart';
import '../providers/item_provider.dart';

/// Informações consolidadas de um produto obtidas via código de barras
class ScannedProductInfo {
  final String barcode;
  final String name;
  final String? brand;
  final String category;
  final String? quantity;
  final String? imageUrl;
  final double? lastPrice;
  final String source; // 'local', 'online', 'community'

  const ScannedProductInfo({
    required this.barcode,
    required this.name,
    this.brand,
    required this.category,
    this.quantity,
    this.imageUrl,
    this.lastPrice,
    required this.source,
  });

  bool get isFromOnline => source == 'online';
}

/// Serviço inteligente para identificar produtos a partir do código de barras
/// Consultando histórico local do usuário e bases abertas (Open Food Facts, Open Beauty Facts, Open Products Facts)
/// Estrutura para códigos de barra de balança (açougue, padaria, frios, hortifrúti)
class ScaleBarcodeInfo {
  final String rawBarcode;
  final String baseCode;
  final double? price;
  final double? weightKg;

  const ScaleBarcodeInfo({
    required this.rawBarcode,
    required this.baseCode,
    this.price,
    this.weightKg,
  });
}

class BarcodeLookupService {
  BarcodeLookupService._privateConstructor();
  static final BarcodeLookupService instance = BarcodeLookupService._privateConstructor();

  final Map<String, ScannedProductInfo> _cache = {};

  /// Identifica o padrão técnico do código de leitura escaneado
  static String identifyBarcodePattern(String raw) {
    final clean = raw.trim();
    if (clean.startsWith('carrin://pair') || clean.contains('carrin.app/pair')) {
      return 'Convite de Lista Compartilhada';
    }
    if (clean.contains('sefaz') || clean.contains('fazenda') || RegExp(r'[?&]p=[0-9]{44}').hasMatch(clean)) {
      return 'Cupom Fiscal NFC-e (SEFAZ)';
    }
    final digits = clean.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 44) {
      return 'Chave de Acesso Danfe/NFC-e';
    }
    if (digits.length == 13) {
      if (digits.startsWith('2')) {
        return 'Etiqueta de Balança (Açougue/Padaria)';
      }
      if (digits.startsWith('789') || digits.startsWith('790')) {
        return 'EAN-13 Brasil (GS1)';
      }
      return 'EAN-13 Internacional';
    }
    if (digits.length == 8) {
      return 'EAN-8 (Compacto)';
    }
    if (digits.length == 12) {
      return 'UPC-A (Importado)';
    }
    if (digits.length == 14) {
      return 'ITF-14 / Caixa Atacado';
    }
    if (clean.startsWith('http://') || clean.startsWith('https://')) {
      return 'QR Code / Link Web';
    }
    return 'Código de Barras (Padrão 1D/2D)';
  }

  /// Extrai informações de etiquetas de balança brasileiras (EAN-13 iniciando com 2)
  ScaleBarcodeInfo? parseScaleBarcode(String barcode) {
    final clean = barcode.replaceAll(RegExp(r'\D'), '');
    if (clean.length == 13 && clean.startsWith('2')) {
      final baseCode = clean.substring(0, 6);
      final valuePart = clean.substring(6, 11);
      final cents = int.tryParse(valuePart);
      final price = (cents != null && cents > 0) ? cents / 100.0 : null;
      return ScaleBarcodeInfo(
        rawBarcode: clean,
        baseCode: baseCode,
        price: price,
      );
    }
    return null;
  }

  /// Retorna imediatamente se o código de barras já estiver em cache ou no histórico local
  ScannedProductInfo? getCachedOrLocal(String barcode, {ItemProvider? itemProvider}) {
    final cleanBarcode = Item.parseBarcode(barcode);
    if (cleanBarcode == null || cleanBarcode.isEmpty) return null;

    if (itemProvider != null) {
      final local = itemProvider.findProductByBarcode(cleanBarcode);
      if (local != null) {
        final name = (local['name'] as String? ?? '').trim();
        if (name.isNotEmpty) {
          final info = ScannedProductInfo(
            barcode: cleanBarcode,
            name: name,
            category: (local['category'] as String?) ?? ItemProvider.suggestCategoryForName(name),
            lastPrice: (local['price'] as num?)?.toDouble(),
            source: 'local',
          );
          _cache[cleanBarcode] = info;
          return info;
        }
      }
    }

    return _cache[cleanBarcode];
  }

  /// Formata strings em Title Case (primeira letra de cada palavra maiúscula)
  String _toTitleCase(String text) {
    if (text.isEmpty) return text;
    final words = text.toLowerCase().split(' ');
    final capitalized = words.map((w) {
      if (w.isEmpty) return w;
      if (['de', 'da', 'do', 'das', 'dos', 'em', 'com', 'e'].contains(w)) return w;
      return w[0].toUpperCase() + w.substring(1);
    });
    return capitalized.join(' ');
  }

  /// Limpa e formata o nome do produto combinando marca e quantidade se relevante
  String _formatProductName(String rawName, String? brand, String? quantity) {
    String cleanName = rawName.trim();
    if (cleanName.isEmpty && brand != null && brand.isNotEmpty) {
      cleanName = brand;
    }

    cleanName = _toTitleCase(cleanName);

    // Se tiver marca e ela não estiver contida no nome, adiciona suavemente
    if (brand != null && brand.trim().isNotEmpty) {
      final cleanBrand = brand.split(',')[0].trim();
      final normName = cleanName.toLowerCase();
      final normBrand = cleanBrand.toLowerCase();
      if (!normName.contains(normBrand) && cleanBrand.length > 2) {
        cleanName = '$cleanName ${_toTitleCase(cleanBrand)}';
      }
    }

    // Se tiver quantidade/gramatura e não estiver contida no nome, adiciona ao final
    if (quantity != null && quantity.trim().isNotEmpty) {
      final cleanQty = quantity.trim();
      final normName = cleanName.toLowerCase();
      final normQty = cleanQty.toLowerCase();
      if (!normName.contains(normQty)) {
        cleanName = '$cleanName $cleanQty';
      }
    }

    return cleanName.trim();
  }

  Future<ScannedProductInfo?> _queryOpenFactsHost(
    String host,
    String cleanBarcode, {
    ItemProvider? itemProvider,
  }) async {
    try {
      final endpoint = Uri.parse(
        'https://$host/api/v2/product/$cleanBarcode.json?fields=product_name,product_name_pt,generic_name_pt,generic_name,abbreviated_product_name,brands,categories,quantity,image_url',
      );

      final response = await http.get(
        endpoint,
        headers: {
          'User-Agent': 'CarrinApp/1.3 (Android; pt-BR; https://github.com/wmartins090-web/CARRIN)',
        },
      ).timeout(const Duration(milliseconds: 3200));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['status'] == 1 && data['product'] != null) {
          final p = data['product'] as Map<String, dynamic>;
          final candidates = [
            p['product_name_pt'] as String?,
            p['product_name'] as String?,
            p['abbreviated_product_name'] as String?,
            p['generic_name_pt'] as String?,
            p['generic_name'] as String?,
            p['brands'] as String?,
          ];
          final rawName = candidates.firstWhere(
            (c) => c != null && c.trim().isNotEmpty,
            orElse: () => null,
          );

          if (rawName != null && rawName.trim().isNotEmpty) {
            final brand = p['brands'] as String?;
            final quantity = p['quantity'] as String?;
            final imageUrl = p['image_url'] as String?;

            final formattedName = _formatProductName(rawName, brand, quantity);
            final suggestedCategory = ItemProvider.suggestCategoryForName(formattedName);

            double? foundPrice;
            if (itemProvider != null) {
              final hist = itemProvider.getPriceHistorySync(formattedName, barcode: cleanBarcode);
              if (hist.isNotEmpty) {
                foundPrice = (hist.last['price'] as num?)?.toDouble();
              }
            }

            return ScannedProductInfo(
              barcode: cleanBarcode,
              name: formattedName,
              brand: brand != null ? _toTitleCase(brand.split(',')[0].trim()) : null,
              category: suggestedCategory,
              quantity: quantity?.trim(),
              imageUrl: imageUrl,
              lastPrice: foundPrice,
              source: 'online',
            );
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Busca informações detalhadas de um produto pelo código de barras
  Future<ScannedProductInfo?> lookup(
    String barcode, {
    ItemProvider? itemProvider,
  }) async {
    final cleanBarcode = Item.parseBarcode(barcode);
    if (cleanBarcode == null || cleanBarcode.isEmpty) return null;

    // 1. Verifica cache em memória ou histórico local
    final cached = getCachedOrLocal(cleanBarcode, itemProvider: itemProvider);
    if (cached != null) return cached;

    // 2. Consulta primária no Open Food Facts (alimentos, bebidas, mercearia)
    var info = await _queryOpenFactsHost(
      'world.openfoodfacts.org',
      cleanBarcode,
      itemProvider: itemProvider,
    );

    // 3. Fallback rápido para Open Beauty Facts (higiene/perfumaria) e Open Products Facts (limpeza/bazar)
    if (info == null) {
      final results = await Future.wait([
        _queryOpenFactsHost('world.openbeautyfacts.org', cleanBarcode, itemProvider: itemProvider),
        _queryOpenFactsHost('world.openproductsfacts.org', cleanBarcode, itemProvider: itemProvider),
      ]);
      info = results.firstWhere((r) => r != null, orElse: () => null);
    }

    if (info != null) {
      _cache[cleanBarcode] = info;
      debugPrint('🔍 BarcodeLookup: Produto identificado online -> ${info.name} (${info.category})');
      return info;
    }

    return null;
  }
}
