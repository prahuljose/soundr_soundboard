import 'dart:math';

import 'package:flutter/material.dart';

/// Bar chart of the most recent levels: one bar per second (newest on the
/// right), a dashed reference line, and an optional alert-threshold line.
/// Bars above [referenceDb] are drawn in the full tint, the rest faded.
class DecibelHistoryChart extends StatelessWidget {
  /// Level samples, oldest first, each [binMs] long.
  final List<double> bins;
  final int binMs;

  /// How many seconds (bars) the chart spans.
  final int seconds;

  final double referenceDb;
  final double? thresholdDb;
  final double minDb;
  final double maxDb;
  final Color tint;
  final Color emptyColor;
  final Color thresholdColor;
  final double height;

  /// Opacity of bars at or under the reference line.
  final double fadedAlpha;

  const DecibelHistoryChart({
    super.key,
    required this.bins,
    required this.tint,
    required this.emptyColor,
    required this.thresholdColor,
    this.binMs = 500,
    this.seconds = 30,
    this.referenceDb = 85,
    this.thresholdDb,
    this.minDb = 30,
    this.maxDb = 100,
    this.height = 90,
    this.fadedAlpha = 0.4,
  });

  /// Folds the raw bins into one level per second (energy average), keeping
  /// only the last [seconds]. Newest last.
  static List<double> perSecond(List<double> bins, int binMs, int seconds) {
    final per = max(1, 1000 ~/ binMs);
    final take = min(bins.length, seconds * per);
    final tail = bins.sublist(bins.length - take);
    final out = <double>[];
    // Group from the newest end so the right-most bar is always "now".
    for (var end = tail.length; end > 0; end -= per) {
      final start = max(0, end - per);
      var energy = 0.0;
      for (var i = start; i < end; i++) {
        energy += pow(10, tail[i] / 10).toDouble();
      }
      final mean = energy / (end - start);
      out.add(mean <= 0 ? 0 : 10 * log(mean) / ln10);
    }
    return out.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final values = perSecond(bins, binMs, seconds);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BarsPainter(
          values: values,
          slots: seconds,
          referenceDb: referenceDb,
          thresholdDb: thresholdDb,
          minDb: minDb,
          maxDb: maxDb,
          tint: tint,
          emptyColor: emptyColor,
          thresholdColor: thresholdColor,
          fadedAlpha: fadedAlpha,
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> values;
  final int slots;
  final double referenceDb;
  final double? thresholdDb;
  final double minDb;
  final double maxDb;
  final Color tint;
  final Color emptyColor;
  final Color thresholdColor;
  final double fadedAlpha;

  _BarsPainter({
    required this.values,
    required this.slots,
    required this.referenceDb,
    required this.thresholdDb,
    required this.minDb,
    required this.maxDb,
    required this.tint,
    required this.emptyColor,
    required this.thresholdColor,
    required this.fadedAlpha,
  });

  double _y(double db, Size size) {
    final f = ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
    return size.height - f * size.height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 3.0;
    final barW = (size.width - gap * (slots - 1)) / slots;
    final first = slots - values.length;

    for (var slot = 0; slot < slots; slot++) {
      final x = slot * (barW + gap);
      final i = slot - first;
      if (i < 0) {
        // Not measured yet: a short stub so the frame of the chart reads.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, size.height - 3, barW, 3),
            const Radius.circular(1.5),
          ),
          Paint()..color = emptyColor,
        );
        continue;
      }
      final db = values[i];
      final top = min(_y(db, size), size.height - 4);
      final over = db > referenceDb;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, top, barW, size.height - top),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
          bottomLeft: const Radius.circular(1),
          bottomRight: const Radius.circular(1),
        ),
        Paint()..color = over ? tint : tint.withValues(alpha: fadedAlpha),
      );
    }

    // Dashed reference line.
    final ry = _y(referenceDb, size);
    final dash = Paint()
      ..color = tint.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(
          Offset(x, ry), Offset(min(x + 4, size.width), ry), dash);
    }

    // The user's alert threshold, when it differs from the reference line.
    final t = thresholdDb;
    if (t != null && (t - referenceDb).abs() >= 1) {
      final ty = _y(t, size);
      canvas.drawLine(
        Offset(0, ty),
        Offset(size.width, ty),
        Paint()
          ..color = thresholdColor.withValues(alpha: 0.7)
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.values.length != values.length ||
      !_same(old.values, values) ||
      old.thresholdDb != thresholdDb ||
      old.tint != tint ||
      old.fadedAlpha != fadedAlpha ||
      old.emptyColor != emptyColor;

  static bool _same(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
