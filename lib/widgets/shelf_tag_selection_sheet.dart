import 'package:flutter/material.dart';
import '../services/shelf_tag_parser.dart';
import '../services/utils.dart';

/// Modal para o usuário escolher entre Preço de Varejo e Preço de Atacado
class ShelfTagSelectionSheet extends StatelessWidget {
  final ShelfTagResult tagResult;
  final Function(ShelfTagPrice selectedPrice, String? productName, String? barcode) onPriceSelected;

  const ShelfTagSelectionSheet({
    super.key,
    required this.tagResult,
    required this.onPriceSelected,
  });

  static Future<void> show(
    BuildContext context, {
    required ShelfTagResult tagResult,
    required Function(ShelfTagPrice selectedPrice, String? productName, String? barcode) onPriceSelected,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ShelfTagSelectionSheet(
        tagResult: tagResult,
        onPriceSelected: onPriceSelected,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final primaryColor = Theme.of(context).primaryColor;

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        MediaQuery.of(context).padding.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Barra de arraste superior
          Center(
            child: Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),

          // Cabeçalho da Etiqueta
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.sell_rounded,
                  color: Color(0xFF10B981),
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Etiqueta de Gôndola',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF10B981),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tagResult.productName?.trim().isNotEmpty == true
                          ? tagResult.productName!
                          : 'Produto Identificado',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),

          if (tagResult.barcode != null && tagResult.barcode!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.qr_code_2_rounded, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text(
                  'EAN: ${tagResult.barcode}',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontFamily: 'monospace'),
                ),
              ],
            ),
          ],

          const SizedBox(height: 16),
          Text(
            'Qual preço você quer colocar no carrinho?',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 14),

          // Cards de Seleção de Preço
          if (tagResult.hasMultiplePrices) ...[
            // Card de Varejo
            _buildPriceCard(
              context,
              priceItem: tagResult.retailPrice!,
              isHighlighted: false,
              badgeText: 'Preço Varejo',
              badgeColor: Colors.blue.shade600,
              icon: Icons.storefront_rounded,
              isDark: isDark,
              onTap: () {
                Navigator.pop(context);
                onPriceSelected(tagResult.retailPrice!, tagResult.productName, tagResult.barcode);
              },
            ),

            const SizedBox(height: 12),

            // Card de Atacado (Destaque Especial)
            _buildPriceCard(
              context,
              priceItem: tagResult.wholesalePrice!,
              isHighlighted: true,
              badgeText: 'Preço Atacado',
              badgeColor: const Color(0xFF10B981),
              savingsText: tagResult.unitSavings != null
                  ? 'Economia de ${Utils.formatCurrency(tagResult.unitSavings!)}/un (${tagResult.discountPercentage?.toStringAsFixed(0)}% OFF)'
                  : null,
              icon: Icons.inventory_2_rounded,
              isDark: isDark,
              onTap: () {
                Navigator.pop(context);
                onPriceSelected(tagResult.wholesalePrice!, tagResult.productName, tagResult.barcode);
              },
            ),
          ] else ...[
            // Quando há apenas 1 preço ou lista geral
            for (final p in tagResult.allPrices) ...[
              _buildPriceCard(
                context,
                priceItem: p,
                isHighlighted: p.isWholesale,
                badgeText: p.label,
                badgeColor: p.isWholesale ? const Color(0xFF10B981) : Colors.blue.shade600,
                icon: p.isWholesale ? Icons.inventory_2_rounded : Icons.local_offer_rounded,
                isDark: isDark,
                onTap: () {
                  Navigator.pop(context);
                  onPriceSelected(p, tagResult.productName, tagResult.barcode);
                },
              ),
              const SizedBox(height: 10),
            ],
          ],

          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancelar',
              style: TextStyle(
                color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPriceCard(
    BuildContext context, {
    required ShelfTagPrice priceItem,
    required bool isHighlighted,
    required String badgeText,
    required Color badgeColor,
    String? savingsText,
    required IconData icon,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final borderColor = isHighlighted
        ? const Color(0xFF10B981)
        : (isDark ? Colors.grey.shade800 : Colors.grey.shade300);

    final bgColor = isHighlighted
        ? const Color(0xFF10B981).withValues(alpha: isDark ? 0.12 : 0.08)
        : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: borderColor,
            width: isHighlighted ? 2.0 : 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: badgeColor, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: badgeColor,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badgeText.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (priceItem.minQuantity != null && priceItem.minQuantity! > 1) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${priceItem.minQuantity}+ un',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    priceItem.formattedPrice,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: isHighlighted ? const Color(0xFF10B981) : (isDark ? Colors.white : Colors.black87),
                    ),
                  ),
                  Text(
                    priceItem.description,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                    ),
                  ),
                  if (savingsText != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      savingsText,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF10B981),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                backgroundColor: isHighlighted ? const Color(0xFF10B981) : Colors.blue.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              child: const Text(
                'Escolher',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
