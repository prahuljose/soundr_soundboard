import 'dart:math';

import 'package:flutter/material.dart';

/// Headphones drawing for the Hearing Check: a band and two ear cups. The
/// cup(s) being tested are filled with [tint] and, when [waves] is on, get
/// sound-wave arcs on their outer side.
///
/// Drawn on a 220×120 design box (the cups span 200 of it; the outer 10 px
/// either side leave room for the arcs) and scaled to fit.
class HearingHeadphones extends StatelessWidget {
  final bool left;
  final bool right;
  final bool waves;
  final Color tint;

  /// Colour of the wave arcs (a darker shade of [tint] on light themes).
  final Color waveColor;

  /// Band and unlit-cup outline.
  final Color line;

  /// Unlit-cup fill.
  final Color cup;

  /// Optional 0..1 driver that makes the arcs pulse.
  final Animation<double>? pulse;
  final double width;

  const HearingHeadphones({
    super.key,
    required this.left,
    required this.right,
    required this.tint,
    required this.waveColor,
    required this.line,
    required this.cup,
    this.waves = true,
    this.pulse,
    this.width = 220,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: width * 120 / 220,
      child: CustomPaint(
        painter: _HeadphonesPainter(
          left: left,
          right: right,
          waves: waves,
          tint: tint,
          waveColor: waveColor,
          line: line,
          cup: cup,
          pulse: pulse,
        ),
      ),
    );
  }
}

class _HeadphonesPainter extends CustomPainter {
  final bool left;
  final bool right;
  final bool waves;
  final Color tint;
  final Color waveColor;
  final Color line;
  final Color cup;
  final Animation<double>? pulse;

  _HeadphonesPainter({
    required this.left,
    required this.right,
    required this.waves,
    required this.tint,
    required this.waveColor,
    required this.line,
    required this.cup,
    this.pulse,
  }) : super(repaint: pulse);

  @override
  void paint(Canvas canvas, Size size) {
    final s = min(size.width / 220, size.height / 120);
    canvas.save();
    canvas.translate((size.width - 220 * s) / 2, (size.height - 120 * s) / 2);
    canvas.scale(s);
    canvas.translate(10, 0);

    // Band.
    final band = Path()
      ..moveTo(40, 88)
      ..lineTo(40, 62)
      ..arcToPoint(const Offset(160, 62), radius: const Radius.circular(60))
      ..lineTo(160, 88);
    canvas.drawPath(
      band,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    // Cups.
    _cup(canvas, const Rect.fromLTWH(22, 64, 34, 50), left);
    _cup(canvas, const Rect.fromLTWH(144, 64, 34, 50), right);

    // Sound waves on the lit side(s).
    if (waves) {
      final p = pulse?.value;
      // Inner arc leads, outer arc follows half a beat later.
      final inner = p == null ? 0.7 : 0.45 + 0.45 * p;
      final outer = p == null ? 0.35 : 0.15 + 0.35 * (1 - p);
      if (right) _waves(canvas, mirror: false, inner: inner, outer: outer);
      if (left) _waves(canvas, mirror: true, inner: inner, outer: outer);
    }
    canvas.restore();
  }

  void _cup(Canvas canvas, Rect r, bool lit) {
    final rr = RRect.fromRectAndRadius(r, const Radius.circular(14));
    if (lit) {
      canvas.drawRRect(rr, Paint()..color = tint);
    } else {
      canvas.drawRRect(rr, Paint()..color = cup);
      canvas.drawRRect(
        rr,
        Paint()
          ..color = line
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
    }
  }

  void _waves(Canvas canvas,
      {required bool mirror, required double inner, required double outer}) {
    double x(double v) => mirror ? 200 - v : v;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final small = Path()
      ..moveTo(x(186), 76)
      ..arcToPoint(Offset(x(186), 102),
          radius: const Radius.circular(16), clockwise: !mirror);
    final big = Path()
      ..moveTo(x(194), 68)
      ..arcToPoint(Offset(x(194), 110),
          radius: const Radius.circular(28), clockwise: !mirror);
    canvas.drawPath(small, paint..color = waveColor.withValues(alpha: inner));
    canvas.drawPath(big, paint..color = waveColor.withValues(alpha: outer));
  }

  @override
  bool shouldRepaint(_HeadphonesPainter old) =>
      old.left != left ||
      old.right != right ||
      old.waves != waves ||
      old.tint != tint ||
      old.waveColor != waveColor ||
      old.line != line ||
      old.cup != cup ||
      old.pulse != pulse;
}
