import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/guitar_tuning.dart';
import '../theme/app_colors.dart';

/// Guitar tuner colours, tuned for contrast in light and dark mode.
class TunerPalette {
  final Color good; // in tune
  final Color warn; // flat / sharp
  final Color accent;
  final bool dark;

  const TunerPalette._(this.good, this.warn, this.accent, this.dark);

  static TunerPalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = Theme.of(context).colorScheme.primary;
    return dark
        ? TunerPalette._(
            const Color(0xFF5FD08A),
            const Color(0xFFFFB86B),
            accent,
            true,
          )
        : TunerPalette._(
            const Color(0xFF16804A),
            const Color(0xFFB4610C),
            accent,
            false,
          );
  }

  Color forStatus(TunerStatus s, AppColors c) => switch (s) {
    TunerStatus.inTune => good,
    TunerStatus.flat || TunerStatus.sharp => warn,
    TunerStatus.waiting => c.iconSecondary,
  };
}

// ── Gauge ───────────────────────────────────────────────────────────────────

/// Arc meter from −50 to +50 cents. The needle glides to each new reading
/// (critically damped) instead of jumping, and rests at the centre, dimmed,
/// while waiting for a note.
class TunerGauge extends StatefulWidget {
  final double? cents;
  final TunerStatus status;

  const TunerGauge({super.key, required this.cents, required this.status});

  @override
  State<TunerGauge> createState() => _TunerGaugeState();
}

class _TunerGaugeState extends State<TunerGauge>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  double _value = 0; // shown needle position, cents (clamped ±55)
  double _glow = 0; // 0..1 in-tune glow
  double _presence = 0; // 0..1 active vs waiting

  double get _target => widget.status == TunerStatus.waiting
      ? 0
      : (widget.cents ?? 0).clamp(-52.0, 52.0);
  double get _glowTarget => widget.status == TunerStatus.inTune ? 1 : 0;
  double get _presenceTarget => widget.status == TunerStatus.waiting ? 0 : 1;

  @override
  void initState() {
    super.initState();
    _value = _target;
    _glow = _glowTarget;
    _presence = _presenceTarget;
  }

  @override
  void didUpdateWidget(TunerGauge old) {
    super.didUpdateWidget(old);
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration now) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : (now - _last).inMicroseconds / 1e6;
    _last = now;
    double ease(double from, double to, double speed) =>
        from + (to - from) * (1 - exp(-dt * speed));
    final v = ease(_value, _target, 11);
    final g = ease(_glow, _glowTarget, 8);
    final p = ease(_presence, _presenceTarget, 6);
    final settled =
        (v - _target).abs() < 0.05 &&
        (g - _glowTarget).abs() < 0.01 &&
        (p - _presenceTarget).abs() < 0.01;
    setState(() {
      _value = settled ? _target : v;
      _glow = settled ? _glowTarget : g;
      _presence = settled ? _presenceTarget : p;
    });
    if (settled) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    final needle = widget.status == TunerStatus.waiting
        ? c.iconSecondary
        : p.forStatus(widget.status, c);
    return ExcludeSemantics(
      child: AspectRatio(
        aspectRatio: 2.05,
        child: CustomPaint(
          painter: _GaugePainter(
            value: _value,
            glow: _glow,
            presence: _presence,
            needle: needle,
            palette: p,
            colors: c,
            textStyle: DefaultTextStyle.of(context).style,
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double value, glow, presence;
  final Color needle;
  final TunerPalette palette;
  final AppColors colors;
  final TextStyle textStyle;

  _GaugePainter({
    required this.value,
    required this.glow,
    required this.presence,
    required this.needle,
    required this.palette,
    required this.colors,
    required this.textStyle,
  });

  static const _sweep = 72 * pi / 180; // ± from vertical at ±50 cents

  double _angle(double cents) => -pi / 2 + cents / 50 * _sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final pivot = Offset(size.width / 2, size.height - 14);
    final r = min(size.width / 2 - 18, size.height - 30);
    final c = colors;

    // In-tune zone (±5 cents): a soft band that blooms when in tune.
    final zone = Rect.fromCircle(center: pivot, radius: r + 2);
    final zoneStart = _angle(-TunerEngine.inTuneCents);
    final zoneSweep = _angle(TunerEngine.inTuneCents) - zoneStart;
    if (glow > 0.01) {
      canvas.drawArc(
        zone,
        zoneStart - 0.04,
        zoneSweep + 0.08,
        false,
        Paint()
          ..color = palette.good.withValues(alpha: 0.35 * glow)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 26
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
    }
    canvas.drawArc(
      zone,
      zoneStart,
      zoneSweep,
      false,
      Paint()
        ..color = palette.good.withValues(alpha: 0.18 + 0.5 * glow)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 14,
    );

    // Ticks every 5 cents. Ticks near the needle light up.
    for (var i = -10; i <= 10; i++) {
      final cents = i * 5.0;
      final a = _angle(cents);
      final major = i == 0 || i.abs() == 5 || i.abs() == 10;
      final len = i == 0
          ? 24.0
          : major
          ? 16.0
          : 10.0;
      final near = presence * exp(-pow((cents - value) / 7, 2));
      final base = i == 0
          ? c.textSecondary
          : c.iconSecondary.withValues(alpha: major ? 0.8 : 0.5);
      final color = Color.lerp(base, needle, near * 0.9)!;
      final dir = Offset(cos(a), sin(a));
      canvas.drawLine(
        pivot + dir * (r - len),
        pivot + dir * r,
        Paint()
          ..color = color
          ..strokeWidth = i == 0
              ? 3.5
              : major
              ? 2.5
              : 2
          ..strokeCap = StrokeCap.round,
      );
    }

    // ♭ / ♯ at the ends.
    void label(String s, double cents) {
      final a = _angle(cents);
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: textStyle.copyWith(
            color: c.textMuted,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // Just inside and below the end tick.
      final at = pivot + Offset(cos(a), sin(a)) * (r - 6) + const Offset(0, 18);
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }

    label('−50', -50);
    label('+50', 50);

    // Needle: a tapered blade with a glow when in tune.
    final a = _angle(value);
    final dir = Offset(cos(a), sin(a));
    final normal = Offset(-dir.dy, dir.dx);
    final tip = pivot + dir * (r - 4);
    final blade = Path()
      ..moveTo(pivot.dx + normal.dx * 4, pivot.dy + normal.dy * 4)
      ..lineTo(tip.dx + normal.dx * 1.2, tip.dy + normal.dy * 1.2)
      ..lineTo(tip.dx - normal.dx * 1.2, tip.dy - normal.dy * 1.2)
      ..lineTo(pivot.dx - normal.dx * 4, pivot.dy - normal.dy * 4)
      ..close();
    if (glow > 0.01) {
      canvas.drawPath(
        blade,
        Paint()
          ..color = needle.withValues(alpha: 0.55 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
    }
    canvas.drawPath(
      blade,
      Paint()..color = needle.withValues(alpha: 0.45 + 0.55 * presence),
    );

    // Pivot.
    canvas.drawCircle(pivot, 11, Paint()..color = c.surfaceCard);
    canvas.drawCircle(
      pivot,
      11,
      Paint()
        ..color = needle.withValues(alpha: 0.45 + 0.55 * presence)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter o) =>
      o.value != value ||
      o.glow != glow ||
      o.presence != presence ||
      o.needle != needle ||
      o.colors != colors ||
      o.palette.accent != palette.accent;
}

// ── Headstock ───────────────────────────────────────────────────────────────

/// A 3 + 3 headstock seen from the front. Low E is bottom-left, high E
/// bottom-right, as on the guitar in your hands. Tapping a peg picks that
/// string.
class TunerHeadstock extends StatelessWidget {
  final GuitarTuning tuning;

  /// The string being tuned (lit in the accent colour), or null.
  final int? active;
  final Set<int> tuned;
  final bool enabled;
  final ValueChanged<int> onPeg;

  const TunerHeadstock({
    super.key,
    required this.tuning,
    required this.active,
    required this.tuned,
    required this.onPeg,
    this.enabled = true,
  });

  // Left column top→bottom: strings 2, 1, 0. Right: 3, 4, 5.
  static const _left = [2, 1, 0];
  static const _right = [3, 4, 5];

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight.isFinite ? box.maxHeight : 250.0;
        final w = box.maxWidth;
        // Crown above the top pegs, nut below the bottom ones.
        const crown = 30.0, neck = 40.0;
        final rowArea = max(h - crown - neck, 90.0);
        // Keep a gap between pegs on short screens.
      final peg = min((rowArea / 3.5).clamp(40.0, 56.0), rowArea / 3 - 6);
        final headW = min(w * 0.42, 170.0);
        double rowY(int row) => crown + rowArea * (row + 0.5) / 3;
        final cx = w / 2;
        final pegInset = min((w - headW) / 2 - peg - 6, 34.0).clamp(4.0, 34.0);
        final leftPegX = cx - headW / 2 - pegInset - peg / 2;
        final rightPegX = cx + headW / 2 + pegInset + peg / 2;

        Widget pegAt(int stringIndex, double x, double y) => Positioned(
          left: x - peg / 2,
          top: y - peg / 2,
          width: peg,
          height: peg,
          child: _Peg(
            label: tuning.label(stringIndex),
            stringNumber: 6 - stringIndex,
            active: active == stringIndex,
            tuned: tuned.contains(stringIndex),
            enabled: enabled,
            onTap: () => onPeg(stringIndex),
          ),
        );

        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _HeadstockPainter(
                  headW: headW,
                  peg: peg,
                  rows: [rowY(0), rowY(1), rowY(2)],
                  leftPegX: leftPegX,
                  rightPegX: rightPegX,
                  active: active,
                  tuned: tuned,
                  colors: c,
                  palette: p,
                ),
              ),
            ),
            for (var row = 0; row < 3; row++) ...[
              pegAt(_left[row], leftPegX, rowY(row)),
              pegAt(_right[row], rightPegX, rowY(row)),
            ],
          ],
        );
      },
    );
  }
}

class _HeadstockPainter extends CustomPainter {
  final double headW;
  final double peg;
  final List<double> rows;
  final double leftPegX, rightPegX;
  final int? active;
  final Set<int> tuned;
  final AppColors colors;
  final TunerPalette palette;

  _HeadstockPainter({
    required this.headW,
    required this.peg,
    required this.rows,
    required this.leftPegX,
    required this.rightPegX,
    required this.active,
    required this.tuned,
    required this.colors,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final cx = size.width / 2;
    canvas.clipRect(Offset.zero & size);
    final top = max(1.0, rows.first - 46);
    final bottom = size.height;
    final neckW = headW * 0.52;

    // Silhouette: wide crown, tapering to the neck at the bottom.
    final body = Path()
      ..moveTo(cx - neckW / 2, bottom)
      ..cubicTo(
        cx - neckW / 2,
        bottom - 40,
        cx - headW / 2,
        rows.last + 30,
        cx - headW / 2,
        rows.last,
      )
      ..lineTo(cx - headW / 2, rows.first)
      ..cubicTo(
        cx - headW / 2,
        top + 10,
        cx - headW * 0.3,
        top,
        cx - headW * 0.12,
        top + 6,
      )
      ..quadraticBezierTo(cx, top + 16, cx + headW * 0.12, top + 6)
      ..cubicTo(
        cx + headW * 0.3,
        top,
        cx + headW / 2,
        top + 10,
        cx + headW / 2,
        rows.first,
      )
      ..lineTo(cx + headW / 2, rows.last)
      ..cubicTo(
        cx + headW / 2,
        rows.last + 30,
        cx + neckW / 2,
        bottom - 40,
        cx + neckW / 2,
        bottom,
      )
      ..close();
    canvas.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(Offset(cx, top), Offset(cx, bottom), [
          c.surfaceElevated,
          c.surfaceCard,
        ]),
    );
    canvas.drawPath(
      body,
      Paint()
        ..color = c.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Nut.
    final nutY = bottom - 16;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, nutY), width: neckW + 6, height: 6),
        const Radius.circular(3),
      ),
      Paint()..color = c.textMuted.withValues(alpha: 0.5),
    );

    // Posts, shafts out to the pegs, and strings down to the nut.
    final postX = headW * 0.27;
    const left = [2, 1, 0], right = [3, 4, 5];
    for (var row = 0; row < 3; row++) {
      for (final side in [-1, 1]) {
        final s = side < 0 ? left[row] : right[row];
        final post = Offset(cx + side * postX, rows[row]);
        final pegX = side < 0 ? leftPegX : rightPegX;
        final lit = s == active;
        final done = tuned.contains(s);
        final stringColor = lit
            ? palette.accent
            : done
            ? palette.good.withValues(alpha: 0.8)
            : c.iconSecondary.withValues(alpha: 0.55);

        // Shaft, stopping at the peg's edge.
        canvas.drawLine(
          post,
          Offset(pegX - side * peg / 2, rows[row]),
          Paint()
            ..color = c.border
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round,
        );

        // String: from the post to its slot on the nut (low E far left).
        final nutX = cx - neckW / 2 + 6 + (neckW - 12) * s / 5;
        final thickness = 2.6 - s * 0.32;
        if (lit) {
          canvas.drawLine(
            post,
            Offset(nutX, nutY),
            Paint()
              ..color = palette.accent.withValues(alpha: 0.45)
              ..strokeWidth = thickness + 5
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
          );
        }
        canvas.drawLine(
          post,
          Offset(nutX, nutY),
          Paint()
            ..color = stringColor
            ..strokeWidth = thickness
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawLine(
          Offset(nutX, nutY),
          Offset(nutX, bottom),
          Paint()
            ..color = stringColor
            ..strokeWidth = thickness,
        );

        // Post.
        canvas.drawCircle(post, 7, Paint()..color = c.scaffoldBg);
        canvas.drawCircle(
          post,
          7,
          Paint()
            ..color = lit ? palette.accent : c.textMuted
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_HeadstockPainter o) =>
      o.active != active ||
      o.tuned.length != tuned.length ||
      !o.tuned.containsAll(tuned) ||
      o.headW != headW ||
      o.colors != colors ||
      o.palette.accent != palette.accent ||
      o.leftPegX != leftPegX;
}

class _Peg extends StatelessWidget {
  final String label;
  final int stringNumber;
  final bool active;
  final bool tuned;
  final bool enabled;
  final VoidCallback onTap;

  const _Peg({
    required this.label,
    required this.stringNumber,
    required this.active,
    required this.tuned,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    final border = active
        ? p.accent
        : tuned
        ? p.good
        : c.border;
    final fill = active
        ? p.accent.withValues(alpha: p.dark ? 0.22 : 0.14)
        : tuned
        ? p.good.withValues(alpha: p.dark ? 0.14 : 0.1)
        : c.surfaceCard;
    return Semantics(
      button: true,
      selected: active,
      label: 'String $stringNumber, $label${tuned ? ', in tune' : ''}',
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        // Pops once when the string is tuned.
        key: ValueKey(tuned),
        tween: Tween(begin: tuned ? 1.18 : 1, end: 1),
        duration: const Duration(milliseconds: 420),
        curve: Curves.elasticOut,
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: fill,
                  border: Border.all(
                    color: border,
                    width: active || tuned ? 2 : 1.5,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: p.accent.withValues(alpha: 0.35),
                            blurRadius: 14,
                          ),
                        ]
                      : null,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: enabled ? onTap : null,
                    child: Center(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: active
                              ? c.textPrimary
                              : tuned
                              ? p.good
                              : c.textPrimary,
                          fontSize: label.length > 1 ? 16 : 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (tuned)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: p.good,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.scaffoldBg, width: 2),
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    size: 12,
                    color: c.scaffoldBg,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
