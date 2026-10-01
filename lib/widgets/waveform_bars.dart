import 'package:flutter/material.dart';

/// Rounded vertical bars for a waveform. Bars left of [progress] (0..1) are
/// drawn in [activeColor], the rest in [idleColor].
class WaveformBars extends StatelessWidget {
  final List<double> levels;
  final double progress;
  final Color activeColor;
  final Color idleColor;
  final double height;

  const WaveformBars({
    super.key,
    required this.levels,
    required this.activeColor,
    required this.idleColor,
    this.progress = 0,
    this.height = 48,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BarsPainter(levels, progress, activeColor, idleColor),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> levels;
  final double progress;
  final Color active;
  final Color idle;

  _BarsPainter(this.levels, this.progress, this.active, this.idle);

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final slot = size.width / levels.length;
    final barW = (slot * 0.6).clamp(1.5, 4.0);
    final paint = Paint();
    for (var i = 0; i < levels.length; i++) {
      final h = (size.height * levels[i].clamp(0.08, 1.0)).toDouble();
      final x = i * slot + (slot - barW) / 2;
      paint.color = (i + 0.5) / levels.length <= progress ? active : idle;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - h) / 2, barW, h),
          Radius.circular(barW / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.progress != progress ||
      old.levels != levels ||
      old.active != active ||
      old.idle != idle;
}
