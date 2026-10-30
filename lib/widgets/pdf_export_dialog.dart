import 'package:flutter/material.dart';
import '../models/item.dart';
import '../providers/item_provider.dart';
import '../services/pdf_export_service.dart';

/// Modal dialog for configuring and exporting the shopping list as a PDF document.
class PdfExportDialog extends StatefulWidget {
  final ItemProvider provider;

  const PdfExportDialog({
    super.key,
    required this.provider,
  });

  /// Displays the PDF export configuration dialog with animation.
  static Future<void> show(BuildContext context, ItemProvider provider) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (ctx, anim1, anim2) => PdfExportDialog(provider: provider),
      transitionBuilder: (ctx, anim1, anim2, child) {
        final curve = Curves.easeOutBack.transform(anim1.value);
        return Transform.scale(
          scale: curve,
          child: Opacity(
            opacity: anim1.value,
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<PdfExportDialog> createState() => _PdfExportDialogState();
}

class _PdfExportDialogState extends State<PdfExportDialog> {
  bool _exportBought = true;
  bool _exportPending = true;
  bool _groupByCategories = true;
  bool _showFinancials = true;

  Future<void> _export() async {
    final List<Item> itemsToExport = widget.provider.items.where((it) {
      if (it.isBought) return _exportBought;
      return _exportPending;
    }).toList();

    if (itemsToExport.isEmpty && widget.provider.items.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nenhum item selecionado para exportação.')),
      );
      return;
    }

    Navigator.pop(context); // Close configuration dialog

    // Display loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final pdfBytes = await PdfExportService.buildPdfDocument(
        month: widget.provider.currentMonth,
        budget: widget.provider.budget,
        items: itemsToExport,
        groupByCategories: _groupByCategories,
        showFinancials: _showFinancials,
      );

      if (mounted) {
        Navigator.pop(context); // Close loading dialog
      }

      final filename = 'CARRIN-${widget.provider.currentMonth.replaceAll(' ', '-')}.pdf';
      await PdfExportService.sharePdf(bytes: pdfBytes, filename: filename);
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao exportar PDF: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).primaryColor;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      title: const Text('Exportar PDF', style: TextStyle(fontWeight: FontWeight.bold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(
            title: const Text('Exportar itens comprados'),
            value: _exportBought,
            activeColor: primaryColor,
            onChanged: (val) {
              if (val != null) setState(() => _exportBought = val);
            },
          ),
          CheckboxListTile(
            title: const Text('Incluir itens pendentes'),
            value: _exportPending,
            activeColor: primaryColor,
            onChanged: (val) {
              if (val != null) setState(() => _exportPending = val);
            },
          ),
          CheckboxListTile(
            title: const Text('Agrupar por categorias'),
            value: _groupByCategories,
            activeColor: primaryColor,
            onChanged: (val) {
              if (val != null) setState(() => _groupByCategories = val);
            },
          ),
          CheckboxListTile(
            title: const Text('Exibir valores e totais'),
            value: _showFinancials,
            activeColor: primaryColor,
            onChanged: (val) {
              if (val != null) setState(() => _showFinancials = val);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: (!_exportBought && !_exportPending) ? null : _export,
          child: const Text('Exportar', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
      ],
    );
  }
}
