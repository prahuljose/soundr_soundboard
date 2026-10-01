import 'dart:async';
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The metronome's tool tint.
const Color kMetronomeTint = Color(0xFFFFD66B);

/// Dark ink for content drawn on a [kMetronomeTint] fill.
final Color kMetronomeInk = Color.lerp(kMetronomeTint, Colors.black, 0.78)!;

/// The tint shade to use for lines and strokes on the current background:
/// the pale yellow needs darkening to stay visible on a light ground.
Color metronomeStroke(BuildContext context, {double lightDarken = 0.3}) =>
    Theme.of(context).brightness == Brightness.light
        ? Color.lerp(kMetronomeTint, Colors.black, lightDarken)!
        : kMetronomeTint;

// ---------------------------------------------------------------------------
// Beat dots
// ---------------------------------------------------------------------------

/// One dot per beat of the bar. The beat that last sounded is lit in the tint
/// with a glow; the downbeat (which plays the accent click) is ringed when
/// idle and lit larger.
class MetronomeBeatDots extends StatelessWidget {
  const MetronomeBeatDots({
    super.key,
    required this.beatsPerBar,
    required this.currentBeat,
    required this.pulse,
  });

  final int beatsPerBar;

  /// The beat that last sounded, or -1 when stopped.
  final int currentBeat;

  /// True for a moment right after each tick — briefly enlarges the lit dot.
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final ring = metronomeStroke(context).withValues(alpha: light ? 0.7 : 0.55);
    final label = currentBeat < 0
        ? '$beatsPerBar beats per bar'
        : 'Beat ${currentBeat + 1} of $beatsPerBar';

    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < beatsPerBar; i++)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : 14),
                // Fixed outer box so the row never reflows on a beat.
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: Center(
                    child: AnimatedScale(
                      scale: i == currentBeat ? (pulse ? 1.22 : 1.0) * (i == 0 ? 1.12 : 1.0) : 1.0,
                      duration: const Duration(milliseconds: 90),
                      curve: Curves.easeOut,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 90),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == currentBeat ? kMetronomeTint : c.border,
                          border: i == 0 && i != currentBeat
                              ? Border.all(color: ring, width: 1.5)
                              : null,
                          boxShadow: i == currentBeat
                              ? [
                                  BoxShadow(
                                    color: kMetronomeTint.withValues(alpha: light ? 0.7 : 0.55),
                                    blurRadius: i == 0 ? 26 : 22,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// −/+ step button with press-and-hold repeat
// ---------------------------------------------------------------------------

/// A 60px round button. A tap calls [onStep] once and then [onCommit]; holding
/// it repeats [onStep] (speeding up the longer it is held) and calls
/// [onCommit] once on release. A null [onStep] disables it.
class MetronomeStepButton extends StatefulWidget {
  const MetronomeStepButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onStep,
    required this.onCommit,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onStep;
  final VoidCallback onCommit;

  @override
  State<MetronomeStepButton> createState() => _MetronomeStepButtonState();
}

class _MetronomeStepButtonState extends State<MetronomeStepButton> {
  Timer? _repeat;
  int _repeats = 0;

  void _startRepeat() {
    _repeats = 0;
    _scheduleNext();
  }

  void _scheduleNext() {
    final delay = _repeats < 6
        ? 140
        : _repeats < 20
            ? 80
            : 45;
    _repeat = Timer(Duration(milliseconds: delay), () {
      final step = widget.onStep;
      if (!mounted || step == null) {
        _endRepeat();
        return;
      }
      step();
      _repeats++;
      _scheduleNext();
    });
  }

  void _endRepeat() {
    if (_repeat == null) return;
    _repeat?.cancel();
    _repeat = null;
    widget.onCommit();
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final enabled = widget.onStep != null;
    return Tooltip(
      message: widget.tooltip,
      child: Listener(
        onPointerUp: (_) => _endRepeat(),
        onPointerCancel: (_) => _endRepeat(),
        child: Material(
          color: c.surfaceCard,
          shape: CircleBorder(side: BorderSide(color: c.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled
                ? () {
                    widget.onStep!();
                    widget.onCommit();
                  }
                : null,
            onLongPress: enabled
                ? () {
                    widget.onStep!();
                    _startRepeat();
                  }
                : null,
            child: SizedBox(
              width: 60,
              height: 60,
              child: Icon(
                widget.icon,
                size: 24,
                color: enabled ? c.textPrimary : c.textMuted,
                semanticLabel: widget.tooltip,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Time signature segmented control
// ---------------------------------------------------------------------------

class MetronomeSignaturePicker extends StatelessWidget {
  const MetronomeSignaturePicker({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  /// (beats per bar, label) pairs.
  final List<(int, String)> options;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      label: 'Time signature',
      container: true,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(child: _segment(context, c, options[i])),
            ],
          ],
        ),
      ),
    );
  }

  Widget _segment(BuildContext context, AppColors c, (int, String) option) {
    final (beats, label) = option;
    final isSelected = beats == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      label: '$label time',
      excludeSemantics: true,
      child: Material(
        color: isSelected ? kMetronomeTint : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isSelected ? null : () => onSelect(beats),
          child: SizedBox(
            height: 44,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? kMetronomeInk : c.textSecondary,
                  fontSize: 15,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tap tempo pad
// ---------------------------------------------------------------------------

class MetronomeTapPad extends StatelessWidget {
  const MetronomeTapPad({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final stroke = metronomeStroke(context).withValues(alpha: light ? 0.75 : 0.5);
    final radius = BorderRadius.circular(18);
    return Semantics(
      button: true,
      label: 'Tap tempo. Tap along to set the BPM',
      excludeSemantics: true,
      child: CustomPaint(
        foregroundPainter: _DashedRRectPainter(color: stroke, radius: 18, strokeWidth: 1.5),
        child: Material(
          color: kMetronomeTint.withValues(alpha: light ? 0.14 : 0.06),
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            splashColor: kMetronomeTint.withValues(alpha: 0.22),
            highlightColor: kMetronomeTint.withValues(alpha: 0.10),
            child: SizedBox(
              width: double.infinity,
              height: 64,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Tap tempo',
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 2),
                  Text('Tap along to set the BPM',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
  });

  final Color color;
  final double radius;
  final double strokeWidth;

  static const _dash = 6.0;
  static const _gap = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(inset, inset, size.width - strokeWidth, size.height - strokeWidth),
      Radius.circular(radius - inset),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    final dashed = Path();
    for (final PathMetric m in (Path()..addRRect(rrect)).computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        dashed.addPath(m.extractPath(d, (d + _dash).clamp(0, m.length)), Offset.zero);
        d += _dash + _gap;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color || old.radius != radius || old.strokeWidth != strokeWidth;
}

// ---------------------------------------------------------------------------
// Play / stop
// ---------------------------------------------------------------------------

class MetronomePlayButton extends StatelessWidget {
  const MetronomePlayButton({
    super.key,
    required this.running,
    required this.onPressed,
  });

  final bool running;

  /// Null while the click sounds are still loading (or failed to load).
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final label = running ? 'Stop metronome' : 'Start metronome';
    return Tooltip(
      message: label,
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: kMetronomeTint.withValues(alpha: 0.25),
                    blurRadius: 34,
                    offset: const Offset(0, 12),
                  ),
                ]
              : null,
        ),
        child: Material(
          color: enabled ? kMetronomeTint : kMetronomeTint.withValues(alpha: 0.38),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Center(
              child: Icon(
                running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: running ? 34 : 40,
                color: enabled ? kMetronomeInk : kMetronomeInk.withValues(alpha: 0.5),
                semanticLabel: label,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
