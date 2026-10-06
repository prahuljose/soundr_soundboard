import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Zen Mode's own teal accent, tuned per brightness so text stays readable:
/// a soft mint on dark surfaces and a deeper teal (≥ 4.5:1 on white) on light.
@immutable
class ZenPalette {
  /// Accent used for text, icons, borders and fills.
  final Color teal;

  /// Text / icon colour on a solid [teal] fill.
  final Color onTeal;

  /// Background of an active (playing) tile or row.
  final Color activeBg;

  /// Background of the secondary round buttons in the dock.
  final Color buttonBg;

  /// Border of the secondary round buttons in the dock.
  final Color buttonBorder;

  final bool isDark;

  const ZenPalette._({
    required this.teal,
    required this.onTeal,
    required this.activeBg,
    required this.buttonBg,
    required this.buttonBorder,
    required this.isDark,
  });

  static const darkTeal = Color(0xFF7FE0C2);
  static const lightTeal = Color(0xFF0E7A60);

  factory ZenPalette.of(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final teal = dark ? darkTeal : lightTeal;
    return ZenPalette._(
      teal: teal,
      onTeal: dark ? const Color(0xFF06221B) : Colors.white,
      activeBg: Color.alphaBlend(
          teal.withValues(alpha: dark ? 0.09 : 0.08), c.surfaceCard),
      buttonBg: dark ? c.surfaceElevated : c.scaffoldBg,
      buttonBorder: c.border,
      isDark: dark,
    );
  }

  Color tint(double alpha) => teal.withValues(alpha: alpha);
}

/// "29:41" under an hour, "1:29:41" above.
String zenClock(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// "15 min", "1 hour", "1½ hours", "2 hours".
String zenMinutesLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final half = minutes % 60 >= 30;
  if (h == 1 && !half) return '1 hour';
  return '$h${half ? '½' : ''} hours';
}

/// 44×44 rounded-square card button used in the Zen header.
class ZenHeaderButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const ZenHeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 20, color: c.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// Round transport button: the big teal Pause/Play or a quieter outlined one.
class ZenRoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool primary;

  const ZenRoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 52,
    this.iconSize = 22,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    final c = Theme.of(context).extension<AppColors>()!;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: primary ? z.teal : z.buttonBg,
        shape: CircleBorder(
          side: primary ? BorderSide.none : BorderSide(color: z.buttonBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon,
                size: iconSize, color: primary ? z.onTeal : c.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// Flexible "🌙 Sleep in 29:41" pill; shows "Sleep timer" when no timer runs.
class ZenSleepPill extends StatelessWidget {
  final Duration? remaining;
  final VoidCallback onPressed;

  const ZenSleepPill({super.key, required this.remaining, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    final c = Theme.of(context).extension<AppColors>()!;
    final base = TextStyle(
      color: c.textPrimary,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    final left = remaining;
    return Semantics(
      button: true,
      label: left == null ? 'Sleep timer' : 'Sleep timer, ${zenClock(left)} left',
      excludeSemantics: true,
      child: Material(
        color: z.buttonBg,
        shape: StadiumBorder(side: BorderSide(color: z.buttonBorder)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bedtime_outlined,
                          size: 18,
                          color: left == null ? c.textPrimary : z.teal),
                      const SizedBox(width: 8),
                      if (left == null)
                        Text('Sleep timer', style: base)
                      else
                        Text.rich(
                          TextSpan(children: [
                            const TextSpan(text: 'Sleep in '),
                            TextSpan(
                              text: zenClock(left),
                              style: TextStyle(
                                color: z.teal,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ]),
                          style: base,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small teal dot with a soft halo that breathes while [animate] is true.
class ZenPulsingDot extends StatefulWidget {
  final bool animate;
  const ZenPulsingDot({super.key, required this.animate});

  @override
  State<ZenPulsingDot> createState() => _ZenPulsingDotState();
}

class _ZenPulsingDotState extends State<ZenPulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _ctrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(ZenPulsingDot old) {
    super.didUpdateWidget(old);
    if (widget.animate == old.animate) return;
    if (widget.animate) {
      _ctrl.repeat(reverse: true);
    } else {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    final c = Theme.of(context).extension<AppColors>()!;
    final color = widget.animate ? z.teal : c.iconSecondary;
    return SizedBox(
      width: 18,
      height: 18,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_ctrl.value);
          return Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.16 + 0.10 * (1 - t)),
                    spreadRadius: 3 + 2.5 * t,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The sleep sheet's 200px progress ring.
class ZenSleepRing extends StatelessWidget {
  final double progress; // 0–1, fraction still to go
  final double size;
  final Widget child;

  const ZenSleepRing({
    super.key,
    required this.progress,
    required this.child,
    this.size = 200,
  });

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          progress: progress.clamp(0.0, 1.0),
          track: z.buttonBg,
          color: z.teal,
        ),
        child: Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color track;
  final Color color;

  _RingPainter({required this.progress, required this.track, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 12.0;
    final rect = Offset.zero & size;
    final r = rect.deflate(stroke / 2);
    canvas.drawArc(
      r, 0, math.pi * 2, false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );
    if (progress <= 0) return;
    canvas.drawArc(
      r,
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.track != track || old.color != color;
}

/// One choice in the sleep timer's 3×2 grid.
class ZenChoiceButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const ZenChoiceButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? z.teal : z.buttonBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: selected ? BorderSide.none : BorderSide(color: z.buttonBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: 48,
            child: Center(
              child: Text(
                label,
                maxLines: 1,
                style: TextStyle(
                  color: selected ? z.onTeal : c.textPrimary,
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-width dashed outline button ("+ Add a sound from the grid").
class ZenDashedButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const ZenDashedButton({super.key, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: CustomPaint(
          painter: _DashedRRectPainter(color: c.border),
          child: SizedBox(
            height: 44,
            width: double.infinity,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_rounded, size: 18, color: c.textSecondary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  _DashedRRectPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 1.5;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(stroke / 2),
      const Radius.circular(14),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = color;
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 6), paint);
        d += 10;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) => old.color != color;
}
