import 'package:flutter/material.dart';
import '../providers/item_provider.dart';
import '../services/utils.dart';

/// Modal inteligente para escolher de qual lista exportar itens para a próxima lista
/// (ou importar/substituir para a lista atual), mantendo os códigos de barras (EAN).
class ExportListItemsSheet extends StatefulWidget {
  final ItemProvider provider;

  /// Se informado, a lista de origem já começa fixada (ex.: exportar a partir de um mês específico).
  final String? fixedSourceMonth;

  /// Se informado, o destino já está definido (ex.: lista atual ou lista recém-nomeada).
  final String? targetMonth;

  /// Quando true, o fluxo cria a lista [targetMonth] (com orçamento/finalidade) ao confirmar.
  final bool isCreatingNewList;
  final double? newListBudget;
  final String newListPurpose;

  const ExportListItemsSheet({
    super.key,
    required this.provider,
    this.fixedSourceMonth,
    this.targetMonth,
    this.isCreatingNewList = false,
    this.newListBudget,
    this.newListPurpose = 'geral',
  });

  /// Fluxo 1: Escolher lista de origem ao criar uma nova lista/mês.
  static Future<bool?> showForNewList(
    BuildContext context, {
    required ItemProvider provider,
    required String newMonthTitle,
    double? budget,
    String purpose = 'geral',
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ExportListItemsSheet(
        provider: provider,
        targetMonth: newMonthTitle,
        isCreatingNewList: true,
        newListBudget: budget,
        newListPurpose: purpose,
      ),
    );
  }

  /// Fluxo 2: Importar / substituir itens na lista já aberta a partir de outra lista escolhida.
  static Future<bool?> showForExistingTarget(
    BuildContext context, {
    required ItemProvider provider,
    required String targetMonth,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ExportListItemsSheet(
        provider: provider,
        targetMonth: targetMonth,
        isCreatingNewList: false,
      ),
    );
  }

  /// Fluxo 3: A partir de uma lista específica (ex.: a mais completa), escolher para qual lista exportar.
  static Future<String?> showFromSource(
    BuildContext context, {
    required ItemProvider provider,
    required String sourceMonth,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ExportListItemsSheet(
        provider: provider,
        fixedSourceMonth: sourceMonth,
      ),
    );
  }

  @override
  State<ExportListItemsSheet> createState() => _ExportListItemsSheetState();
}

class _ExportListItemsSheetState extends State<ExportListItemsSheet> {
  static const String _newTargetSentinel = '__CREATE_NEW_LIST__';

  bool _isLoading = true;
  bool _isSubmitting = false;
  List<MonthExportSummary> _summaries = [];
  String? _selectedSource;
  String? _selectedTarget;
  final TextEditingController _newTargetCtrl = TextEditingController();

  bool _resetPrices = true;
  bool _keepQuantities = true;
  bool _replaceExisting = false;

  @override
  void initState() {
    super.initState();
    _newTargetCtrl.text = _suggestNextMonthTitle();
    _loadSummaries();
  }

  @override
  void dispose() {
    _newTargetCtrl.dispose();
    super.dispose();
  }

  String _suggestNextMonthTitle() {
    final now = DateTime.now();
    const monthsPt = [
      'Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
      'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro',
    ];
    final nextMonthDate = DateTime(now.year, now.month + 1, 1);
    final candidate = '${monthsPt[nextMonthDate.month - 1]} ${nextMonthDate.year}';
    if (!widget.provider.months.contains(candidate)) {
      return candidate;
    }
    return 'Próxima Lista';
  }

  Future<void> _loadSummaries() async {
    final exclude = widget.isCreatingNewList
        ? widget.targetMonth
        : (widget.fixedSourceMonth ?? widget.targetMonth);
    final loaded = await widget.provider.getAvailableSourceMonthsSummary(
      excludeMonth: exclude,
    );

    if (!mounted) return;
    setState(() {
      _summaries = loaded;
      if (widget.fixedSourceMonth != null) {
        _selectedSource = widget.fixedSourceMonth;
        final targets = _summaries
            .where((s) => s.title != widget.fixedSourceMonth && !s.isFinalized)
            .toList();
        _selectedTarget = targets.isNotEmpty ? targets.first.title : _newTargetSentinel;
      } else {
        final nonEmpty = _summaries.where((s) => s.itemCount > 0).toList();
        _selectedSource = nonEmpty.isNotEmpty
            ? nonEmpty.first.title
            : (_summaries.isNotEmpty ? _summaries.first.title : null);
        _selectedTarget = widget.targetMonth;
      }
      _isLoading = false;
    });
  }

  Future<void> _confirmExport() async {
    if (_isSubmitting || _selectedSource == null) return;

    final String effectiveTarget;
    bool createTargetFirst = widget.isCreatingNewList;

    if (widget.fixedSourceMonth != null) {
      if (_selectedTarget == _newTargetSentinel) {
        final typed = _newTargetCtrl.text.trim();
        if (typed.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Digite o nome da nova lista de destino.')),
          );
          return;
        }
        effectiveTarget = typed;
        createTargetFirst = !widget.provider.months.contains(typed);
      } else {
        if (_selectedTarget == null || _selectedTarget!.isEmpty) return;
        effectiveTarget = _selectedTarget!;
        createTargetFirst = false;
      }
    } else {
      if (widget.targetMonth == null || widget.targetMonth!.trim().isEmpty) return;
      effectiveTarget = widget.targetMonth!.trim();
    }

    setState(() => _isSubmitting = true);

    try {
      if (createTargetFirst) {
        await widget.provider.createNewMonth(
          effectiveTarget,
          true,
          initialBudget: widget.newListBudget,
          purpose: widget.newListPurpose,
          sourceMonth: _selectedSource,
          resetPrices: _resetPrices,
          resetQuantities: !_keepQuantities,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lista "$effectiveTarget" criada com itens e códigos de barras de "$_selectedSource"!',
            ),
            backgroundColor: Colors.green,
          ),
        );
        if (widget.fixedSourceMonth != null) {
          Navigator.pop(context, effectiveTarget);
        } else {
          Navigator.pop(context, true);
        }
      } else {
        final result = await widget.provider.exportItemsFromMonth(
          sourceMonth: _selectedSource!,
          targetMonth: effectiveTarget,
          resetPrices: _resetPrices,
          resetQuantities: !_keepQuantities,
          resetBought: true,
          replaceExisting: _replaceExisting,
        );
        if (!mounted) return;
        final String msg = result.updatedCount > 0
            ? '${result.updatedCount} substituídos e ${result.addedCount} adicionados (${result.preservedBarcodesCount} EANs mantidos)!'
            : '${result.addedCount} itens exportados para "$effectiveTarget" (${result.preservedBarcodesCount} EANs mantidos)!';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.green),
        );
        if (widget.fixedSourceMonth != null) {
          Navigator.pop(context, effectiveTarget);
        } else {
          Navigator.pop(context, true);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao exportar itens: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final primaryColor = Theme.of(context).primaryColor;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final bool isFixedSourceFlow = widget.fixedSourceMonth != null;

    final int targetExistingCount = !widget.isCreatingNewList &&
            widget.targetMonth != null &&
            widget.targetMonth == widget.provider.currentMonth
        ? widget.provider.items.length
        : (_summaries
                .where((s) => s.title == _selectedTarget)
                .map((s) => s.itemCount)
                .firstOrNull ??
            0);

    final bool showReplaceOption = !widget.isCreatingNewList &&
        !(isFixedSourceFlow && _selectedTarget == _newTargetSentinel) &&
        targetExistingCount > 0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.88,
        ),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          MediaQuery.of(context).padding.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: primaryColor.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.playlist_add_check_rounded, color: primaryColor, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isFixedSourceFlow
                              ? 'Exportar de "${widget.fixedSourceMonth}"'
                              : (widget.isCreatingNewList
                                  ? 'Exportar itens para "${widget.targetMonth}"'
                                  : 'Trazer itens para "${widget.targetMonth}"'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Mantém códigos de barras (EAN) e facilita atualizar só os preços.',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              if (_isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (!isFixedSourceFlow) ...[
                const Text(
                  'QUAL LISTA USAR COMO BASE?',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                if (_summaries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Nenhuma outra lista encontrada.',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _summaries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (ctx, i) {
                        final s = _summaries[i];
                        final selected = _selectedSource == s.title;
                        return InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: s.itemCount == 0
                              ? null
                              : () => setState(() => _selectedSource = s.title),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              color: selected
                                  ? primaryColor.withValues(alpha: 0.1)
                                  : (isDark ? const Color(0xFF0F172A) : Colors.grey.shade50),
                              border: Border.all(
                                color: selected ? primaryColor : Colors.grey.withValues(alpha: 0.25),
                                width: selected ? 1.8 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  selected
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  color: selected ? primaryColor : Colors.grey,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              s.title,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: s.itemCount == 0 ? Colors.grey : null,
                                              ),
                                            ),
                                          ),
                                          if (s.isMostComplete) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF10B981).withValues(alpha: 0.16),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: const Text(
                                                'Mais itens',
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF059669),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${s.itemCount} itens • ${s.barcodeCount} códigos de barras',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (s.total > 0)
                                  Text(
                                    Utils.formatCurrency(s.total),
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ] else ...[
                const Text(
                  'PARA QUAL LISTA EXPORTAR?',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _selectedTarget,
                  isExpanded: true,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: _newTargetSentinel,
                      child: Text('➕ Criar nova lista agora', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    ..._summaries
                        .where((s) => s.title != widget.fixedSourceMonth && !s.isFinalized)
                        .map((s) => DropdownMenuItem<String>(
                              value: s.title,
                              child: Text(
                                '${s.title} (${s.itemCount} itens)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            )),
                  ],
                  onChanged: (val) => setState(() => _selectedTarget = val),
                ),
                if (_selectedTarget == _newTargetSentinel) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _newTargetCtrl,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Nome da nova lista',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                ],
              ],

              const SizedBox(height: 14),
              Container(
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
                ),
                child: Column(
                  children: [
                    SwitchListTile.adaptive(
                      dense: true,
                      title: const Text(
                        'Zerar preços para atualizar na compra',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        _resetPrices
                            ? 'Itens entram com R\$ 0,00 para você só atualizar o preço'
                            : 'Traz o último preço pago como referência',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      value: _resetPrices,
                      onChanged: (v) => setState(() => _resetPrices = v),
                    ),
                    const Divider(height: 1),
                    SwitchListTile.adaptive(
                      dense: true,
                      title: const Text(
                        'Manter quantidades usuais',
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        _keepQuantities
                            ? 'Preserva 1x, 2x, etc. em vez de zerar para 0'
                            : 'Zera quantidades para preencher do zero',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      value: _keepQuantities,
                      onChanged: (v) => setState(() => _keepQuantities = v),
                    ),
                    if (showReplaceOption) ...[
                      const Divider(height: 1),
                      SwitchListTile.adaptive(
                        dense: true,
                        title: const Text(
                          'Substituir toda a lista atual',
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          _replaceExisting
                              ? 'Apaga itens antigos e mantém códigos de barras equivalentes'
                              : 'Mescla: substitui equivalentes (por EAN/nome) e adiciona os faltantes',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        value: _replaceExisting,
                        onChanged: (v) => setState(() => _replaceExisting = v),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.qr_code_2_rounded, size: 18, color: Colors.teal),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Todos os códigos de barras (EAN) e categorias são preservados automaticamente.',
                        style: TextStyle(fontSize: 11.5, color: Colors.teal, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isSubmitting ? null : () => Navigator.pop(context),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: (_isLoading || _isSubmitting || _selectedSource == null)
                          ? null
                          : _confirmExport,
                      icon: _isSubmitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check_rounded),
                      label: Text(
                        widget.isCreatingNewList
                            ? 'Criar e Exportar'
                            : 'Exportar Agora',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
