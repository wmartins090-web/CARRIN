import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Widget com animação interativa e moderna do Carrinho de Compras em movimento,
/// com estrada animada, itens saltando, efeito de brilho e marca d'água "EM CONSTRUÇÃO".
class UnderConstructionCartAnimation extends StatefulWidget {
  final Widget? childUnderneath;
  final bool showAsOverlay;

  const UnderConstructionCartAnimation({
    super.key,
    this.childUnderneath,
    this.showAsOverlay = false,
  });

  @override
  State<UnderConstructionCartAnimation> createState() => _UnderConstructionCartAnimationState();
}

class _UnderConstructionCartAnimationState extends State<UnderConstructionCartAnimation>
    with TickerProviderStateMixin {
  late AnimationController _driveController;
  late AnimationController _itemsBounceController;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();

    // 1. Animação de locomoção do carrinho e rotação das rodas (loop contínuo)
    _driveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    // 2. Animação de itens saltando e caindo alegremente no carrinho
    _itemsBounceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    // 3. Pulsação suave do badge de construção
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _driveController.dispose();
    _itemsBounceController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final primary = theme.primaryColor;

    return Stack(
      children: [
        // Se houver conteúdo por baixo, renderiza com leve desfoque/opacidade
        if (widget.childUnderneath != null)
          Opacity(
            opacity: 0.18,
            child: widget.childUnderneath!,
          ),

        // 🌊 MARCA D'ÁGUA EM DIAGONAL "EM CONSTRUÇÃO"
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _WatermarkPainter(
                textColor: isDark
                    ? Colors.white.withValues(alpha: 0.055)
                    : Colors.black.withValues(alpha: 0.045),
                watermarkText: 'EM CONSTRUÇÃO • CARRIN COMUNIDADE • ',
              ),
            ),
          ),
        ),

        // 🛒 PALCO CENTRAL DA ANIMAÇÃO DO CARRINHO
        Center(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Halo de iluminação de fundo
                AnimatedBuilder(
                  animation: _driveController,
                  builder: (context, _) {
                    final bounce = math.sin(_driveController.value * math.pi * 4) * 3.5;
                    final tilt = math.sin(_driveController.value * math.pi * 2) * 0.03;
                    final wheelAngle = _driveController.value * 2 * math.pi;
                    final itemBounce = math.sin(_itemsBounceController.value * math.pi) * 8.0;

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Container do Carrinho em Movimento
                        SizedBox(
                          width: 220,
                          height: 160,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // Brilho pulsante radial atrás do carrinho
                              Container(
                                width: 140,
                                height: 140,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: primary.withValues(alpha: 0.22),
                                      blurRadius: 50,
                                      spreadRadius: 15,
                                    ),
                                  ],
                                ),
                              ),

                              // Itens saltando sobre o carrinho (Maçã, Leite, Pão, Caixa)
                              Positioned(
                                top: 12 - itemBounce,
                                left: 75,
                                child: _buildFloatingItem('🍎', 22),
                              ),
                              Positioned(
                                top: 22 - (itemBounce * 0.7),
                                left: 105,
                                child: _buildFloatingItem('🥛', 24),
                              ),
                              Positioned(
                                top: 16 - (itemBounce * 1.1),
                                left: 135,
                                child: _buildFloatingItem('🍞', 22),
                              ),

                              // Corpo do Carrinho com oscilação realista de suspensão
                              Transform.translate(
                                offset: Offset(0, bounce),
                                child: Transform.rotate(
                                  angle: tilt,
                                  child: Stack(
                                    alignment: Alignment.bottomCenter,
                                    children: [
                                      // Cesta e Estrutura metálica do carrinho
                                      Icon(
                                        Icons.shopping_cart_rounded,
                                        size: 96,
                                        color: primary,
                                      ),

                                      // Rodas Dianteira e Traseira girando em alta velocidade
                                      Positioned(
                                        bottom: 12,
                                        left: 56,
                                        child: Transform.rotate(
                                          angle: wheelAngle,
                                          child: _buildSpinningWheel(primary, isDark),
                                        ),
                                      ),
                                      Positioned(
                                        bottom: 12,
                                        right: 76,
                                        child: Transform.rotate(
                                          angle: wheelAngle,
                                          child: _buildSpinningWheel(primary, isDark),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),

                              // Linhas de velocidade (efeito de vento / pressa)
                              Positioned(
                                left: 10,
                                top: 60,
                                child: _buildSpeedLine(35, _driveController.value),
                              ),
                              Positioned(
                                left: 20,
                                top: 78,
                                child: _buildSpeedLine(25, (_driveController.value + 0.3) % 1.0),
                              ),
                              Positioned(
                                left: 8,
                                top: 96,
                                child: _buildSpeedLine(40, (_driveController.value + 0.6) % 1.0),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 10),

                        // Pista/Solo com faixas tracejadas deslizando para trás
                        SizedBox(
                          width: 220,
                          height: 12,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: CustomPaint(
                              painter: _RoadConveyorPainter(
                                offsetPercent: _driveController.value,
                                roadColor: isDark ? Colors.white24 : Colors.black26,
                                lineColor: primary.withValues(alpha: 0.8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 32),

                // 🚧 BADGE PULSANTE DE EM CONSTRUÇÃO
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final scale = 1.0 + (_pulseController.value * 0.04);
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.amber.shade700,
                              Colors.orange.shade800,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.orange.withValues(alpha: 0.35),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('🚧', style: TextStyle(fontSize: 16)),
                            SizedBox(width: 8),
                            Text(
                              'EM CONSTRUÇÃO',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.5,
                                fontSize: 13.5,
                              ),
                            ),
                            SizedBox(width: 8),
                            Text('🚧', style: TextStyle(fontSize: 16)),
                          ],
                        ),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 18),

                // Título e Descrição Elegante
                Text(
                  'Comunidade CARRIN',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Estamos preparando um espaço incrível para você acompanhar ofertas em tempo real, cupons validados e trocar dicas com outros compradores!',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: isDark ? Colors.white70 : Colors.black54,
                      height: 1.45,
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Efeito visual de progresso / carregamento contínuo
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.black.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Novidades em breve nas próximas atualizações...',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFloatingItem(String emoji, double size) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(emoji, style: TextStyle(fontSize: size)),
    );
  }

  Widget _buildSpinningWheel(Color primary, bool isDark) {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade900 : Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: primary, width: 2.2),
      ),
      child: Center(
        child: Container(
          width: 4,
          height: 4,
          decoration: BoxDecoration(
            color: primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedLine(double width, double animPercent) {
    return Opacity(
      opacity: (1.0 - animPercent).clamp(0.0, 1.0),
      child: Container(
        width: width * (0.6 + animPercent * 0.4),
        height: 2.5,
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Pintor da esteira de solo com faixas deslizantes
class _RoadConveyorPainter extends CustomPainter {
  final double offsetPercent;
  final Color roadColor;
  final Color lineColor;

  _RoadConveyorPainter({
    required this.offsetPercent,
    required this.roadColor,
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final roadPaint = Paint()
      ..color = roadColor
      ..style = PaintingStyle.fill;

    // Asfalto
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(4),
      ),
      roadPaint,
    );

    // Linhas pontilhadas em movimento da direita para a esquerda
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    const dashWidth = 14.0;
    const dashGap = 10.0;
    const totalPattern = dashWidth + dashGap;
    final shift = offsetPercent * totalPattern;

    for (double x = -totalPattern; x < size.width + totalPattern; x += totalPattern) {
      final drawX = x - shift;
      if (drawX + dashWidth > 0 && drawX < size.width) {
        final startX = drawX.clamp(0.0, size.width);
        final endX = (drawX + dashWidth).clamp(0.0, size.width);
        canvas.drawLine(
          Offset(startX, size.height / 2),
          Offset(endX, size.height / 2),
          linePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RoadConveyorPainter oldDelegate) =>
      oldDelegate.offsetPercent != offsetPercent;
}

/// Pintor da marca d'água em padrão diagonal contínuo
class _WatermarkPainter extends CustomPainter {
  final Color textColor;
  final String watermarkText;

  _WatermarkPainter({
    required this.textColor,
    required this.watermarkText,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();

    // Rotação diagonal estilosa de -22 graus
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-22 * math.pi / 180);
    canvas.translate(-size.width, -size.height);

    final textStyle = TextStyle(
      color: textColor,
      fontSize: 18,
      fontWeight: FontWeight.w900,
      letterSpacing: 2.5,
    );

    const stepX = 360.0;
    const stepY = 65.0;

    for (double y = -size.height * 0.5; y < size.height * 2.5; y += stepY) {
      final isEven = (y ~/ stepY) % 2 == 0;
      final startOffset = isEven ? 0.0 : stepX / 2;

      for (double x = -size.width * 0.5 + startOffset; x < size.width * 2.5; x += stepX) {
        final textSpan = TextSpan(text: watermarkText, style: textStyle);
        final textPainter = TextPainter(
          text: textSpan,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(canvas, Offset(x, y));
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WatermarkPainter oldDelegate) => false;
}
