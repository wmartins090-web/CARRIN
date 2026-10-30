import 'dart:typed_data';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/item.dart';
import '../providers/item_provider.dart';
import 'utils.dart';

/// Service responsible for generating and sharing PDF documents for shopping lists.
class PdfExportService {
  /// Builds the PDF document bytes for the specified items and configuration.
  static Future<Uint8List> buildPdfDocument({
    required String month,
    required double budget,
    required List<Item> items,
    required bool groupByCategories,
    required bool showFinancials,
  }) async {
    final pdf = pw.Document();
    final total = items.where((it) => it.isBought).fold(0.0, (sum, it) => sum + it.totalPrice);
    final balance = budget - total;
    final healthPercent = budget > 0 ? total / budget : 0.0;

    final font = await PdfGoogleFonts.nunitoRegular();
    final fontBold = await PdfGoogleFonts.nunitoBold();
    final emojiFont = await PdfGoogleFonts.notoEmojiRegular();
    const primaryColor = PdfColor.fromInt(0xFF10B981);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        theme: pw.ThemeData.withFont(base: font, bold: fontBold, fontFallback: [emojiFont]),
        build: (pw.Context context) {
          return [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'CARRIN',
                      style: pw.TextStyle(
                        fontSize: 28,
                        fontWeight: pw.FontWeight.bold,
                        color: primaryColor,
                        letterSpacing: 1.2,
                      ),
                    ),
                    pw.Text(
                      'Sua lista, sem complicação.',
                      style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      month,
                      style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
                    ),
                  ],
                ),
                pw.Text(
                  DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now()),
                  style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey500),
                ),
              ],
            ),
            pw.SizedBox(height: 24),
            if (showFinancials) ...[
              pw.Container(
                padding: const pw.EdgeInsets.all(20),
                decoration: const pw.BoxDecoration(
                  color: primaryColor,
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(16)),
                ),
                child: pw.Row(
                  children: [
                    pw.Container(
                      width: 50,
                      height: 50,
                      decoration: pw.BoxDecoration(
                        shape: pw.BoxShape.circle,
                        border: pw.Border.all(color: PdfColors.blueGrey700, width: 4),
                      ),
                      child: pw.Center(
                        child: pw.Text(
                          '${(healthPercent * 100).toInt()}%',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.white,
                          ),
                        ),
                      ),
                    ),
                    pw.SizedBox(width: 20),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(
                                'GASTO ATUAL',
                                style: const pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey300,
                                  letterSpacing: 1,
                                ),
                              ),
                              pw.Text(
                                'SALDO',
                                style: const pw.TextStyle(
                                  fontSize: 9,
                                  color: PdfColors.grey300,
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                          pw.SizedBox(height: 4),
                          pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(
                                Utils.formatCurrency(total),
                                style: pw.TextStyle(
                                  fontSize: 16,
                                  fontWeight: pw.FontWeight.bold,
                                  color: PdfColors.white,
                                ),
                              ),
                              pw.Text(
                                Utils.formatCurrency(balance),
                                style: pw.TextStyle(
                                  fontSize: 16,
                                  fontWeight: pw.FontWeight.bold,
                                  color: balance < 0 ? PdfColors.red200 : PdfColors.green200,
                                ),
                              ),
                            ],
                          ),
                          pw.SizedBox(height: 8),
                          pw.Divider(color: PdfColors.blueGrey800, thickness: 0.5),
                          pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(
                                'Orçamento: ${Utils.formatCurrency(budget)}',
                                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey400),
                              ),
                              pw.Text(
                                'Total de Itens: ${items.length}',
                                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey400),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 32),
            ],
            pw.Text(
              'ITENS DA LISTA',
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                color: primaryColor,
                letterSpacing: 1,
              ),
            ),
            pw.SizedBox(height: 16),
            if (items.isEmpty)
              pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 20),
                padding: const pw.EdgeInsets.all(24),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300, width: 1),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(12)),
                ),
                child: pw.Center(
                  child: pw.Text(
                    'Lista em branco - Pronta para anotações e compras',
                    style: const pw.TextStyle(color: PdfColors.grey600, fontSize: 12),
                  ),
                ),
              )
            else if (groupByCategories)
              ..._buildGroupedItems(items, emojiFont, primaryColor, showFinancials)
            else
              ...items.map((item) => _buildItemRow(item, emojiFont, primaryColor, showFinancials)),
            pw.SizedBox(height: 30),
            pw.Center(
              child: pw.Text(
                'Documento gerado pelo app CARRIN',
                style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey400),
              ),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  /// Shares the generated PDF document using the platform share dialog.
  static Future<void> sharePdf({
    required Uint8List bytes,
    required String filename,
  }) async {
    await Printing.sharePdf(bytes: bytes, filename: filename);
  }

  static List<pw.Widget> _buildGroupedItems(
    List<Item> items,
    pw.Font emojiFont,
    PdfColor primaryColor,
    bool showFinancials,
  ) {
    final Map<String, List<Item>> grouped = {};
    for (var it in items) {
      grouped.putIfAbsent(it.category, () => []).add(it);
    }

    final List<pw.Widget> widgets = [];
    grouped.forEach((category, catItems) {
      final emoji = ItemProvider.categoryEmojis[category] ?? '📦';
      widgets.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 14, bottom: 8),
          child: pw.Row(
            children: [
              pw.Text('$emoji ', style: pw.TextStyle(font: emojiFont, fontSize: 12)),
              pw.Text(
                category.toUpperCase(),
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.grey600,
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(child: pw.Divider(color: PdfColors.grey200, thickness: 0.5)),
            ],
          ),
        ),
      );

      for (var item in catItems) {
        widgets.add(_buildItemRow(item, emojiFont, primaryColor, showFinancials));
      }
    });

    return widgets;
  }

  static pw.Widget _buildItemRow(
    Item item,
    pw.Font emojiFont,
    PdfColor primaryColor,
    bool showFinancials,
  ) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 6),
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
        border: pw.Border.all(color: PdfColors.grey100, width: 0.5),
      ),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Row(
            children: [
              pw.Container(
                width: 14,
                height: 14,
                decoration: pw.BoxDecoration(
                  shape: pw.BoxShape.rectangle,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
                  border: pw.Border.all(color: primaryColor, width: 1),
                  color: item.isBought ? primaryColor : null,
                ),
                child: item.isBought
                    ? pw.Center(
                        child: pw.Text(
                          '✓',
                          style: pw.TextStyle(
                            font: emojiFont,
                            fontSize: 8,
                            color: PdfColors.white,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                      )
                    : null,
              ),
              pw.SizedBox(width: 10),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text(
                    item.name,
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                      color: primaryColor,
                      decoration: item.isBought ? pw.TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (item.barcode != null && item.barcode!.trim().isNotEmpty)
                    pw.Text(
                      'Cód: ${item.barcode!.trim()}',
                      style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
                    ),
                  if (showFinancials)
                    pw.Text(
                      '${Utils.formatNumber(item.quantity)}${item.isKg ? "kg" : " un"} x ${Utils.formatCurrency(item.unitPrice)}',
                      style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
                    )
                  else
                    pw.Text(
                      'Qtd: ${Utils.formatNumber(item.quantity)}${item.isKg ? "kg" : " un"}',
                      style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
                    ),
                ],
              ),
            ],
          ),
          if (showFinancials)
            pw.Text(
              Utils.formatCurrency(item.totalPrice),
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: primaryColor,
              ),
            ),
        ],
      ),
    );
  }
}
