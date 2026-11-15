import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/guitar_tuning.dart';
import '../theme/app_colors.dart';

/// Tuner colours, tuned for contrast in light and dark mode.
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
  // Created in initState, not lazily: a gauge that never moved would
  // otherwise first ask for its ticker in dispose().
  late final Ticker _ticker;
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
    _ticker = createTicker(_tick);
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

/// Where one string's peg sits.
class _PegSpot {
  final int string;

  /// -1 = left of the head, 1 = right.
  final int side;
  final double y;

  /// Drawn string width: thicker for lower notes.
  final double thickness;

  const _PegSpot(this.string, this.side, this.y, this.thickness);
}

/// The top of the instrument seen from the front, held upright with the nut
/// at the bottom — the way you see it when you look down the neck to tune.
/// Tapping a peg picks that string.
///
/// Peg ↔ string mapping, the same rule for every instrument: the strings
/// cross the nut left to right in playing order (highest-numbered string on
/// the left, string 1 on the right). The left pegs take the first half of
/// the strings, nearest the nut first; the right pegs take the rest, running
/// back down towards the nut:
///
/// * guitar, 3 + 3 — left, bottom→top: 6 5 4 (E A D); right, top→bottom:
///   3 2 1 (G B E).
/// * ukulele, 2 + 2 — left: 4 (G) below 3 (C); right: 2 (E) above 1 (A).
/// * bass, 2 + 2 — left: E below A; right: D above G. Five-string, 3 + 2 —
///   left: B E A; right: D above G.
/// * violin family, pegbox and scroll — left: G below D; right: A above E,
///   staggered as real pegs are (from the scroll down: A, D, E, G).
class TunerHeadstock extends StatelessWidget {
  final GuitarTuning tuning;
  final HeadShape shape;

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
    this.shape = HeadShape.guitar,
    this.enabled = true,
  });

  /// Smallest tap target for a peg, whatever size it's drawn.
  static const _minTap = 48.0;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    final n = tuning.strings.length;
    final nLeft = (n + 1) ~/ 2;
    final nRight = n - nLeft;
    final rows = nLeft;
    final scroll = shape == HeadShape.scroll;
    return LayoutBuilder(
      builder: (context, box) {
        final h = box.maxHeight.isFinite ? box.maxHeight : 250.0;
        final w = box.maxWidth;
        // Room above the top pegs for the crown (or the scroll), and below
        // the bottom ones for the nut.
        // Both shrink on short screens so the pegs keep a 44 px+ tap target.
        final tight = h < 230;
        final neck = tight ? 30.0 : 40.0;
        final crown = scroll
            ? (h - neck - 150).clamp(52.0, 92.0)
            : (tight ? 16.0 : 30.0);
        var rowArea = max(h - crown - neck, 90.0);
        // Two rows of pegs don't need a head as tall as three.
        if (rows < 3) rowArea = min(rowArea, rows * 84.0);
        final rowTop = max(h - neck - rowArea, crown);
        final rowH = rowArea / rows;
        // Keep a gap between pegs on short screens.
        final peg = min(
          (rows < 3 ? rowH * 0.66 : rowArea / 3.5).clamp(40.0, 56.0),
          rowH - 6,
        );
        final headW = switch (shape) {
          HeadShape.guitar => min(w * 0.42, 170.0),
          HeadShape.ukulele => min(w * 0.38, 150.0),
          HeadShape.bass => min(w * 0.44, 180.0),
          HeadShape.scroll => min(w * 0.3, 112.0),
        };
        final cx = w / 2;
        final maxInset = scroll ? 22.0 : 34.0;
        final pegInset = min(
          (w - headW) / 2 - peg - 6,
          maxInset,
        ).clamp(4.0, maxInset);
        final leftPegX = cx - headW / 2 - pegInset - peg / 2;
        final rightPegX = cx + headW / 2 + pegInset + peg / 2;

        double rowY(double row) => rowTop + rowH * (row + 0.5);
        // The shorter side is centred against the longer; scroll pegs are
        // staggered a quarter row each way.
        final rightShift = (nLeft - nRight) / 2;
        final stagger = scroll ? 0.25 : 0.0;
        final spots = [
          for (var s = 0; s < n; s++)
            _PegSpot(
              s,
              s < nLeft ? -1 : 1,
              s < nLeft
                  ? rowY(nLeft - 1 - s + stagger)
                  : rowY(s - nLeft + rightShift - stagger),
              (3.6 - (tuning.strings[s] - 28) / 36 * 2.6).clamp(1.0, 3.9),
            ),
        ];

        final tapW = max(peg, _minTap);
        final tapH = max(peg, min(_minTap, rowH));
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _HeadstockPainter(
                  shape: shape,
                  tuning: tuning,
                  headW: headW,
                  peg: peg,
                  spots: spots,
                  leftPegX: leftPegX,
                  rightPegX: rightPegX,
                  active: active,
                  tuned: tuned,
                  colors: c,
                  palette: p,
                ),
              ),
            ),
            for (final spot in spots)
              Positioned(
                left: (spot.side < 0 ? leftPegX : rightPegX) - tapW / 2,
                top: spot.y - tapH / 2,
                width: tapW,
                height: tapH,
                child: _Peg(
                  size: peg,
                  label: tuning.label(spot.string),
                  stringNumber: tuning.stringNumber(spot.string),
                  active: active == spot.string,
                  tuned: tuned.contains(spot.string),
                  enabled: enabled,
                  onTap: () => onPeg(spot.string),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _HeadstockPainter extends CustomPainter {
  final HeadShape shape;
  final GuitarTuning tuning;
  final double headW;
  final double peg;
  final List<_PegSpot> spots;
  final double leftPegX, rightPegX;
  final int? active;
  final Set<int> tuned;
  final AppColors colors;
  final TunerPalette palette;

  _HeadstockPainter({
    required this.shape,
    required this.tuning,
    required this.headW,
    required this.peg,
    required this.spots,
    required this.leftPegX,
    required this.rightPegX,
    required this.active,
    required this.tuned,
    required this.colors,
    required this.palette,
  });

  double get _firstY => spots.map((s) => s.y).reduce(min);
  double get _lastY => spots.map((s) => s.y).reduce(max);

  @override
  void paint(Canvas canvas, Size size) {
    final c = colors;
    final cx = size.width / 2;
    canvas.clipRect(Offset.zero & size);
    final scroll = shape == HeadShape.scroll;
    final firstY = _firstY, lastY = _lastY;
    final bottom = size.height;
    final neckW = headW * (scroll ? 0.66 : 0.52);
    final nutY = bottom - 16;

    final double top;
    final Path body;
    if (scroll) {
      // Pegbox narrowing to a throat, with the scroll's circle on top.
      final boxTop = firstY - peg / 2 - 2;
      final room = max(boxTop - 2, 20.0);
      final r = min(room / 1.7, headW * 0.34);
      final centre = Offset(cx, boxTop - r * 0.7);
      top = centre.dy - r;
      final topW = headW * 0.56, throatW = min(headW * 0.3, r * 1.3);
      final box = Path()
        ..moveTo(cx - neckW / 2, bottom)
        ..lineTo(cx - topW / 2, boxTop + 10)
        ..quadraticBezierTo(cx - topW / 2, boxTop, cx - throatW / 2, boxTop - 8)
        ..lineTo(cx - throatW / 2, centre.dy)
        ..lineTo(cx + throatW / 2, centre.dy)
        ..lineTo(cx + throatW / 2, boxTop - 8)
        ..quadraticBezierTo(cx + topW / 2, boxTop, cx + topW / 2, boxTop + 10)
        ..lineTo(cx + neckW / 2, bottom)
        ..close();
      body = Path.combine(
        PathOperation.union,
        box,
        Path()..addOval(Rect.fromCircle(center: centre, radius: r)),
      );
      _fillBody(canvas, body, cx, top, bottom);

      // The scroll's spiral, winding in to its eye.
      final spiral = Path();
      const turns = 1.6, steps = 48;
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final a = pi / 2 + t * turns * 2 * pi;
        final rr = r * (0.74 - 0.56 * t);
        final pt = centre + Offset(cos(a), sin(a)) * rr;
        i == 0 ? spiral.moveTo(pt.dx, pt.dy) : spiral.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(
        spiral,
        Paint()
          ..color = c.textMuted.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );

      // The open slot the strings wind in.
      final slot = RRect.fromRectAndRadius(
        Rect.fromLTRB(
          cx - headW * 0.17,
          firstY - 15,
          cx + headW * 0.17,
          lastY + 15,
        ),
        const Radius.circular(9),
      );
      canvas.drawRRect(slot, Paint()..color = c.scaffoldBg);
      canvas.drawRRect(
        slot,
        Paint()
          ..color = c.border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    } else {
      top = max(1.0, firstY - 46);
      body = Path()
        ..moveTo(cx - neckW / 2, bottom)
        ..cubicTo(
          cx - neckW / 2,
          bottom - 40,
          cx - headW / 2,
          lastY + 30,
          cx - headW / 2,
          lastY,
        )
        ..lineTo(cx - headW / 2, firstY);
      switch (shape) {
        case HeadShape.ukulele:
          // One smooth arch.
          body
            ..cubicTo(cx - headW / 2, top + 16, cx - headW * 0.3, top, cx, top)
            ..cubicTo(
              cx + headW * 0.3,
              top,
              cx + headW / 2,
              top + 16,
              cx + headW / 2,
              firstY,
            );
        case HeadShape.bass:
          // Flat top, square shoulders.
          body
            ..cubicTo(
              cx - headW / 2,
              top + 8,
              cx - headW / 2 + 8,
              top,
              cx - headW / 2 + 28,
              top,
            )
            ..lineTo(cx + headW / 2 - 28, top)
            ..cubicTo(
              cx + headW / 2 - 8,
              top,
              cx + headW / 2,
              top + 8,
              cx + headW / 2,
              firstY,
            );
        case HeadShape.guitar || HeadShape.scroll:
          // Two shoulders with a dip between.
          body
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
              firstY,
            );
      }
      body
        ..lineTo(cx + headW / 2, lastY)
        ..cubicTo(
          cx + headW / 2,
          lastY + 30,
          cx + neckW / 2,
          bottom - 40,
          cx + neckW / 2,
          bottom,
        )
        ..close();
      _fillBody(canvas, body, cx, top, bottom);
    }

    // Nut.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, nutY), width: neckW + 6, height: 6),
        const Radius.circular(3),
      ),
      Paint()..color = c.textMuted.withValues(alpha: 0.5),
    );

    // Posts, shafts out to the pegs, and strings down to the nut.
    final n = spots.length;
    final postX = headW * 0.27;
    final postR = shape == HeadShape.bass ? 9.0 : 7.0;
    for (final spot in spots) {
      final s = spot.string;
      final side = spot.side;
      final pegX = side < 0 ? leftPegX : rightPegX;
      final lit = s == active;
      final done = tuned.contains(s);
      final stringColor = lit
          ? palette.accent
          : done
          ? palette.good.withValues(alpha: 0.8)
          : c.iconSecondary.withValues(alpha: 0.55);
      // The string's slot on the nut: highest-numbered string far left.
      final nutX = cx - neckW / 2 + 6 + (neckW - 12) * s / (n - 1);
      // Where the string starts: its post, or (on a scroll) its turn round
      // the peg shaft inside the slot.
      final post = scroll
          ? Offset(cx + (nutX - cx) * 0.45, spot.y)
          : Offset(cx + side * postX, spot.y);

      // Shaft, from the peg's edge. A scroll's pegs run right through the
      // pegbox.
      canvas.drawLine(
        scroll ? Offset(cx - side * headW * 0.24, spot.y) : post,
        Offset(pegX - side * peg / 2, spot.y),
        Paint()
          ..color = c.border
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );

      final thickness = spot.thickness;
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

      if (scroll) {
        // A few turns of string round the shaft.
        canvas.drawLine(
          post - const Offset(0, 4),
          post + const Offset(0, 4),
          Paint()
            ..color = lit ? palette.accent : c.textMuted
            ..strokeWidth = 5
            ..strokeCap = StrokeCap.round,
        );
      } else {
        canvas.drawCircle(post, postR, Paint()..color = c.scaffoldBg);
        canvas.drawCircle(
          post,
          postR,
          Paint()
            ..color = lit ? palette.accent : c.textMuted
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
    }
  }

  void _fillBody(
    Canvas canvas,
    Path body,
    double cx,
    double top,
    double bottom,
  ) {
    canvas.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(Offset(cx, top), Offset(cx, bottom), [
          colors.surfaceElevated,
          colors.surfaceCard,
        ]),
    );
    canvas.drawPath(
      body,
      Paint()
        ..color = colors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_HeadstockPainter o) =>
      o.active != active ||
      o.tuned.length != tuned.length ||
      !o.tuned.containsAll(tuned) ||
      o.shape != shape ||
      o.tuning != tuning ||
      o.headW != headW ||
      o.peg != peg ||
      o._firstY != _firstY ||
      o._lastY != _lastY ||
      o.colors != colors ||
      o.palette.accent != palette.accent ||
      o.leftPegX != leftPegX;
}

class _Peg extends StatelessWidget {
  /// Diameter of the drawn peg; the tap target is the whole widget.
  final double size;
  final String label;
  final int stringNumber;
  final bool active;
  final bool tuned;
  final bool enabled;
  final VoidCallback onTap;

  const _Peg({
    required this.size,
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
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Center(
          child: SizedBox(
            width: size,
            height: size,
            child: _circle(c, p, border, fill),
          ),
        ),
      ),
    );
  }

  Widget _circle(AppColors c, TunerPalette p, Color border, Color fill) {
    return TweenAnimationBuilder<double>(
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
                child: Icon(Icons.check_rounded, size: 12, color: c.scaffoldBg),
              ),
            ),
        ],
      ),
    );
  }
}
