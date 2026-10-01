import 'dart:math';

import 'package:flutter/material.dart';

/// Semicircular level gauge for the decibel meter: a track arc, a tinted
/// progress arc (round caps), an optional peak-hold tick, the big live number
/// in the middle and the scale ends underneath.
class DecibelGauge extends StatelessWidget {
  /// Level the arc fills to, in dB. Null draws the empty track only.
  final double? value;

  /// Peak-hold level, drawn as a small tick on the arc. Null hides it.
  final double? peak;

  /// The large number in the centre (already formatted).
  final String number;

  /// Plain-language line under the number, e.g. "dB · conversational".
  final String caption;

  final double minDb;
  final double maxDb;
  final Color tint;
  final Color trackColor;
  final Color numberColor;
  final Color captionColor;
  final Color scaleColor;
  final Color peakColor;
  final String semanticLabel;

  const DecibelGauge({
    super.key,
    required this.value,
    required this.number,
    required this.caption,
    required this.tint,
    required this.trackColor,
    required this.numberColor,
    required this.captionColor,
    required this.scaleColor,
    required this.peakColor,
    required this.semanticLabel,
    this.peak,
    this.minDb = 30,
    this.maxDb = 120,
  });

  double _fraction(double db) =>
      ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0).toDouble();

  @override
  Widget build(BuildContext context) {
    const tabular = [FontFeature.tabularFigures()];
    return Semantics(
      label: semanticLabel,
      excludeSemantics: true,
      child: SizedBox(
        width: 300,
        height: 190,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: 300,
              height: 170,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: value == null ? 0 : _fraction(value!)),
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                builder: (context, f, _) => CustomPaint(
                  painter: _GaugePainter(
                    fraction: f,
                    peakFraction: peak == null ? null : _fraction(peak!),
                    tint: tint,
                    track: trackColor,
                    peakColor: peakColor,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 66,
              child: Column(
                children: [
                  Text(
                    number,
                    maxLines: 1,
                    style: TextStyle(
                      color: numberColor,
                      fontSize: 64,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -2,
                      height: 1,
                      fontFeatures: tabular,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: captionColor, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 14,
              right: 14,
              top: 172,
              child: Row(
                children: [
                  Text('${minDb.round()}',
                      style: TextStyle(
                          color: scaleColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          fontFeatures: tabular)),
                  const Spacer(),
                  Text('${maxDb.round()}',
                      style: TextStyle(
                          color: scaleColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          fontFeatures: tabular)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double fraction;
  final double? peakFraction;
  final Color tint;
  final Color track;
  final Color peakColor;

  _GaugePainter({
    required this.fraction,
    required this.peakFraction,
    required this.tint,
    required this.track,
    required this.peakColor,
  });

  static const _stroke = 18.0;
  static const _radius = 120.0;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, 160);
    final rect = Rect.fromCircle(center: centre, radius: _radius);

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, pi, pi, false, trackPaint);

    if (fraction > 0.002) {
      final fill = Paint()
        ..color = tint
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, pi, pi * fraction, false, fill);
    }

    final pf = peakFraction;
    if (pf != null && pf > fraction + 0.01) {
      final a = pi + pi * pf;
      final dir = Offset(cos(a), sin(a));
      final inner = centre + dir * (_radius - _stroke / 2 + 1);
      final outer = centre + dir * (_radius + _stroke / 2 - 1);
      canvas.drawLine(
        inner,
        outer,
        Paint()
          ..color = peakColor
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction ||
      old.peakFraction != peakFraction ||
      old.tint != tint ||
      old.track != track ||
      old.peakColor != peakColor;
}
