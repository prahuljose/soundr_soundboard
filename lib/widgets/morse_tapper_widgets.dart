import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Building blocks for the Morse Tapper screen (artboard 11).
///
/// Dots and dashes are drawn as shapes rather than '·' / '−' glyphs so they
/// render identically in every font and at every size.

/// A row of morse symbols drawn as shapes. [code] uses '.' and '-'.
class MorseSymbols extends StatelessWidget {
  final String code;
  final Color color;
  final double dot;
  final double dashWidth;
  final double gap;

  const MorseSymbols({
    super.key,
    required this.code,
    required this.color,
    this.dot = 6,
    this.dashWidth = 15,
    this.gap = 3,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < code.length; i++) {
      if (i > 0) children.add(SizedBox(width: gap));
      children.add(MorseSymbol(
        isDash: code[i] == '-',
        color: color,
        dot: dot,
        dashWidth: dashWidth,
      ));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// A single dot (circle) or dash (pill).
class MorseSymbol extends StatelessWidget {
  final bool isDash;
  final Color color;
  final double dot;
  final double dashWidth;

  const MorseSymbol({
    super.key,
    required this.isDash,
    required this.color,
    this.dot = 14,
    this.dashWidth = 34,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: isDash ? dashWidth : dot,
      height: dot,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(dot / 2),
      ),
    );
  }
}

/// The dashed "next symbol goes here" slot in the current-letter pill.
class MorseNextSlot extends StatelessWidget {
  final Color color;
  final double width;
  final double height;

  const MorseNextSlot({
    super.key,
    required this.color,
    this.width = 34,
    this.height = 14,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(width, height),
      painter: _DashedPillPainter(color),
    );
  }
}

class _DashedPillPainter extends CustomPainter {
  final Color color;
  _DashedPillPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)));
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const dash = 4.0, space = 3.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + space;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedPillPainter old) => old.color != color;
}

/// Blinking accent caret shown after the decoded text.
class MorseBlinkingCursor extends StatefulWidget {
  final double height;
  const MorseBlinkingCursor({super.key, required this.height});

  @override
  State<MorseBlinkingCursor> createState() => _MorseBlinkingCursorState();
}

class _MorseBlinkingCursorState extends State<MorseBlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return FadeTransition(
      // On for the first 60% of each cycle, then off — a crisp caret blink.
      opacity: _blink.drive(TweenSequence<double>([
        TweenSequenceItem(tween: ConstantTween(1), weight: 60),
        TweenSequenceItem(tween: ConstantTween(0), weight: 40),
      ])),
      child: Container(
        width: 3,
        height: widget.height,
        decoration: BoxDecoration(
          color: accent,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 44x44 rounded-14 header button.
class MorseSquareButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final double iconSize;

  const MorseSquareButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.iconSize = 20,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final radius = BorderRadius.circular(14);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: Material(
          color: c.surfaceCard,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: c.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            onLongPress: enabled ? onLongPress : null,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                icon,
                size: iconSize,
                color: enabled
                    ? c.textPrimary
                    : c.textPrimary.withValues(alpha: 0.3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A letter + its morse code, as in the hint row and the reference chart.
class MorseHintChip extends StatelessWidget {
  final String letter;
  final String code;
  final bool highlighted;

  const MorseHintChip({
    super.key,
    required this.letter,
    required this.code,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      label: '$letter: ${code.split('').map((s) => s == '-' ? 'dash' : 'dot').join(' ')}',
      excludeSemantics: true,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: highlighted ? accent.withValues(alpha: 0.14) : c.surfaceCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: highlighted ? accent.withValues(alpha: 0.5) : c.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              letter,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            MorseSymbols(code: code, color: accent),
          ],
        ),
      ),
    );
  }
}

/// Bottom-row toggle chip (Sound / Flash / Vibrate) or plain action chip
/// (Timing) when [selected] is null.
class MorseToggleChip extends StatelessWidget {
  final String label;
  final bool? selected;
  final bool available;
  final VoidCallback onTap;

  const MorseToggleChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected,
    this.available = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final on = selected == true;
    final radius = BorderRadius.circular(20);
    return Semantics(
      button: true,
      toggled: selected,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: available ? 1 : 0.45,
        child: Material(
          color: on ? accent.withValues(alpha: 0.14) : c.surfaceCard,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(
              color: on ? accent.withValues(alpha: 0.5) : c.border,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  color: on ? c.textPrimary : c.textSecondary,
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The big tap pad. Purely visual: the caller wraps it in the gesture
/// detector and drives [pressed] / [dashMode].
class MorseTapPad extends StatelessWidget {
  final bool pressed;
  final bool dashMode;
  final double height;

  const MorseTapPad({
    super.key,
    required this.pressed,
    required this.dashMode,
    this.height = 220,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final ink = Theme.of(context).colorScheme.onPrimary;
    final fill = dashMode ? 0.28 : (pressed ? 0.22 : 0.12);
    final label = !pressed
        ? 'Tap for dot · hold for dash'
        : dashMode
            ? 'Dash'
            : 'Dot · keep holding for dash';

    return AnimatedScale(
      scale: pressed ? 0.975 : 1,
      duration: const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        height: height,
        width: double.infinity,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: fill),
          borderRadius: BorderRadius.circular(34),
          border: Border.all(color: accent, width: pressed ? 2 : 1.5),
          boxShadow: pressed
              ? [BoxShadow(color: accent.withValues(alpha: 0.22), blurRadius: 24)]
              : const [],
        ),
        child: CustomPaint(
          painter: _InnerGlowPainter(
            accent.withValues(alpha: pressed ? 0.28 : 0.16),
            radius: 34,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                width: pressed ? 72 : 64,
                height: pressed ? 72 : 64,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                  boxShadow: pressed
                      ? [BoxShadow(color: accent.withValues(alpha: 0.45), blurRadius: 18)]
                      : const [],
                ),
                alignment: Alignment.center,
                // The small dark dot stretches into a dash once the hold
                // crosses the dash threshold.
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOutBack,
                  width: dashMode ? 36 : 18,
                  height: dashMode ? 14 : 18,
                  decoration: BoxDecoration(
                    color: ink,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Inset glow: a blurred band just inside the rounded edge.
class _InnerGlowPainter extends CustomPainter {
  final Color color;
  final double radius;
  _InnerGlowPainter(this.color, {required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
        Offset.zero & size, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(rrect);
    final ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect((Offset.zero & size).inflate(40))
      ..addRRect(rrect);
    canvas.drawPath(
      ring,
      Paint()
        ..color = color
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 20),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InnerGlowPainter old) =>
      old.color != color || old.radius != radius;
}
