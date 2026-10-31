import 'dart:convert';
import 'dart:io';
import '../models/item.dart';
import '../providers/item_provider.dart';

/// Payload estruturado de uma única lista compartilhada entre dispositivos
class SharedListPayload {
  final String title;
  final double budget;
  final List<Item> items;
  final String? spreadsheetId; // ID da planilha do Google dedicada a esta lista única

  const SharedListPayload({
    required this.title,
    required this.budget,
    required this.items,
    this.spreadsheetId,
  });
}

/// Serviço responsável por codificar e decodificar listas compartilhadas
/// via NFC, QR Code e links universais, garantindo isolamento total por lista.
class SharedListService {
  SharedListService._();
  static final SharedListService instance = SharedListService._();

  /// Codifica exclusivamente os itens da lista informada com compressão ultra-leve GZIP
  String encodeSingleList({
    required String title,
    required double budget,
    required List<Item> items,
    String? spreadsheetId,
  }) {
    final itemsMap = items.map((it) {
      final map = <String, dynamic>{'n': it.name};
      if (it.quantity != 1.0) map['q'] = it.quantity;
      if (it.unitPrice > 0.0) map['p'] = it.unitPrice;
      if (it.category != 'Outros' && it.category.isNotEmpty) map['c'] = it.category;
      if (it.isKg) map['k'] = 1;
      if (it.isBought) map['b'] = 1;
      if (it.barcode != null && it.barcode!.isNotEmpty) map['bc'] = it.barcode;
      return map;
    }).toList();

    final data = {
      't': title,
      if (budget > 0.0) 'b': budget,
      'i': itemsMap,
      if (spreadsheetId != null && spreadsheetId.isNotEmpty) 'ss': spreadsheetId,
      'mode': 'single_list',
    };

    final jsonStr = jsonEncode(data);
    final utf8Bytes = utf8.encode(jsonStr);
    final compressed = gzip.encode(utf8Bytes);
    final base64Str = base64UrlEncode(compressed);
    return 'carrin://share?z=$base64Str';
  }

  /// Codifica a lista atualmente ativa ou selecionada do provider
  String encodeList(ItemProvider provider, {String? targetMonth, String? spreadsheetId}) {
    final listTitle = targetMonth ?? provider.currentMonth;
    final items = (listTitle == provider.currentMonth)
        ? provider.items
        : (provider.getCachedItemsForMonth(listTitle) ?? []);
    final budget = (listTitle == provider.currentMonth) ? provider.budget : 0.0;
    return encodeSingleList(
      title: listTitle,
      budget: budget,
      items: items,
      spreadsheetId: spreadsheetId,
    );
  }

  /// Decodifica uma URI ou string bruta no objeto de lista compartilhada isolada
  SharedListPayload? decodeList(String rawInput) {
    try {
      String clean = rawInput.trim();
      String? encoded;

      if (clean.contains('z=')) {
        final uri = Uri.tryParse(clean);
        if (uri != null && uri.queryParameters.containsKey('z')) {
          encoded = uri.queryParameters['z'];
        } else {
          final idx = clean.indexOf('z=');
          encoded = clean.substring(idx + 2);
          if (encoded.contains('&')) {
            encoded = encoded.substring(0, encoded.indexOf('&'));
          }
        }
      } else if (clean.contains('d=')) {
        final uri = Uri.tryParse(clean);
        if (uri != null && uri.queryParameters.containsKey('d')) {
          encoded = uri.queryParameters['d'];
        } else {
          final idx = clean.indexOf('d=');
          encoded = clean.substring(idx + 2);
          if (encoded.contains('&')) {
            encoded = encoded.substring(0, encoded.indexOf('&'));
          }
        }
      } else if (clean.startsWith('carrin://share?')) {
        encoded = clean.replaceFirst('carrin://share?', '').trim();
      }

      if (encoded == null || encoded.isEmpty) return null;

      // Normaliza padding de base64 se necessário
      String padded = encoded;
      while (padded.length % 4 != 0) {
        padded += '=';
      }

      List<int> bytes = base64Url.decode(padded);
      // Auto-detecção de compressão GZIP (magic bytes 0x1F, 0x8B)
      if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
        bytes = gzip.decode(bytes);
      }
      final jsonStr = utf8.decode(bytes);
      final Map<String, dynamic> data = jsonDecode(jsonStr);

      final title = (data['t'] as String?) ?? 'Lista Compartilhada';
      final budget = (data['b'] as num?)?.toDouble() ?? 0.0;
      final ss = (data['ss'] as String?);

      final rawItems = data['i'] as List<dynamic>? ?? [];
      final List<Item> items = [];

      for (int i = 0; i < rawItems.length; i++) {
        final it = rawItems[i] as Map<String, dynamic>;
        items.add(Item(
          index: i + 7,
          name: (it['n'] as String?) ?? 'Item',
          quantity: (it['q'] as num?)?.toDouble() ?? 1.0,
          unitPrice: (it['p'] as num?)?.toDouble() ?? 0.0,
          category: (it['c'] as String?) ?? 'Outros',
          isKg: it['k'] == true || it['k'] == 1,
          isBought: it['b'] == true || it['b'] == 1,
          barcode: it['bc'] as String?,
        ));
      }

      return SharedListPayload(
        title: title,
        budget: budget,
        items: items,
        spreadsheetId: ss,
      );
    } catch (_) {
      return null;
    }
  }
}
