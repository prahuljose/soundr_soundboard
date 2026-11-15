import 'dart:async';
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../services/metronome_presets.dart';
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
                      scale: i == currentBeat
                          ? (pulse ? 1.22 : 1.0) * (i == 0 ? 1.12 : 1.0)
                          : 1.0,
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
                                    color: kMetronomeTint.withValues(
                                      alpha: light ? 0.7 : 0.55,
                                    ),
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
// Segmented controls
// ---------------------------------------------------------------------------

/// Small caps heading above a group of controls.
class MetronomeSectionLabel extends StatelessWidget {
  const MetronomeSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          color: c.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

/// A row of equal segments; the selected one is filled with the tint.
class MetronomeSegmented<T> extends StatelessWidget {
  const MetronomeSegmented({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onSelect,
    required this.semanticLabel,
    required this.builder,
    this.background,
  });

  /// What the control chooses, for screen readers.
  final String label;
  final List<T> options;
  final T selected;
  final ValueChanged<T> onSelect;
  final String Function(T option) semanticLabel;

  /// Builds a segment's content in [color] (ink when selected).
  final Widget Function(
    BuildContext context,
    T option,
    bool selected,
    Color color,
  )
  builder;

  /// Track colour; defaults to the card surface.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      label: label,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: background ?? c.surfaceCard,
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

  Widget _segment(BuildContext context, AppColors c, T option) {
    final isSelected = option == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      label: semanticLabel(option),
      excludeSemantics: true,
      child: Material(
        color: isSelected ? kMetronomeTint : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isSelected ? null : () => onSelect(option),
          child: SizedBox(
            height: 44,
            child: Center(
              child: builder(
                context,
                option,
                isSelected,
                isSelected ? kMetronomeInk : c.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Text for a [MetronomeSegmented] segment.
Widget metronomeSegmentText(String text, bool selected, Color color) => Text(
  text,
  style: TextStyle(
    color: color,
    fontSize: 15,
    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
    fontFeatures: const [FontFeature.tabularFigures()],
  ),
);

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
    return MetronomeSegmented<int>(
      label: 'Time signature',
      options: [for (final o in options) o.$1],
      selected: selected,
      onSelect: onSelect,
      semanticLabel: (beats) =>
          '${options.firstWhere((o) => o.$1 == beats).$2} time',
      builder: (context, beats, isSelected, color) => metronomeSegmentText(
        options.firstWhere((o) => o.$1 == beats).$2,
        isSelected,
        color,
      ),
    );
  }
}

/// Picks how each beat is split: drawn as one, two, three or four notes.
class MetronomeSubdivisionPicker extends StatelessWidget {
  const MetronomeSubdivisionPicker({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  final MetronomeSubdivision selected;
  final ValueChanged<MetronomeSubdivision> onSelect;

  @override
  Widget build(BuildContext context) {
    return MetronomeSegmented<MetronomeSubdivision>(
      label: 'Subdivision',
      options: MetronomeSubdivision.values,
      selected: selected,
      onSelect: onSelect,
      semanticLabel: (s) => s.label,
      builder: (context, s, isSelected, color) => Tooltip(
        message: s.label,
        child: CustomPaint(
          size: const Size(34, 24),
          painter: _NotesPainter(notes: s.clicksPerBeat, color: color),
        ),
      ),
    );
  }
}

/// One to four note heads with stems, beamed together when there are
/// several (two beams for four). Drawn because the app font has no music
/// glyphs.
class _NotesPainter extends CustomPainter {
  const _NotesPainter({required this.notes, required this.color});

  final int notes;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const headW = 6.6, headH = 4.8, gap = 8.0, stem = 14.0;
    final fill = Paint()..color = color;
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final width = headW + gap * (notes - 1);
    final left = (size.width - width) / 2;
    final headY = size.height - headH / 2 - 1.5;
    final top = headY - stem;

    for (var i = 0; i < notes; i++) {
      final cx = left + headW / 2 + gap * i;
      canvas.save();
      canvas.translate(cx, headY);
      canvas.rotate(-0.38);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: headW, height: headH),
        fill,
      );
      canvas.restore();
      final sx = cx + headW / 2 - 0.9;
      canvas.drawLine(Offset(sx, headY - 1), Offset(sx, top), line);
    }
    if (notes > 1) {
      final x0 = left + headW - 1.6,
          x1 = left + headW - 0.2 + gap * (notes - 1);
      canvas.drawRect(Rect.fromLTRB(x0, top - 0.6, x1, top + 2.2), fill);
      if (notes == 4) {
        canvas.drawRect(Rect.fromLTRB(x0, top + 4.2, x1, top + 6.6), fill);
      }
    }
  }

  @override
  bool shouldRepaint(_NotesPainter old) =>
      old.notes != notes || old.color != color;
}

// ---------------------------------------------------------------------------
// Saved tempos
// ---------------------------------------------------------------------------

/// A horizontally scrolling row: a "Save" chip, then one chip per saved
/// tempo. Tap a chip to load it; long-press for rename / delete.
class MetronomePresetRow extends StatelessWidget {
  const MetronomePresetRow({
    super.key,
    required this.presets,
    required this.current,
    required this.onSave,
    required this.onLoad,
    required this.onMenu,
  });

  final List<MetronomePreset> presets;

  /// The setup on screen now; matching chips are highlighted.
  final MetronomeSetup current;
  final VoidCallback onSave;
  final ValueChanged<int> onLoad;
  final ValueChanged<int> onMenu;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final stroke = metronomeStroke(context);
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: presets.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return _chip(
              context,
              semantics: 'Save this tempo',
              fill: kMetronomeTint.withValues(alpha: light ? 0.2 : 0.1),
              border: stroke.withValues(alpha: light ? 0.75 : 0.5),
              onTap: onSave,
              children: [
                Icon(Icons.add_rounded, size: 18, color: c.textPrimary),
                const SizedBox(width: 4),
                Text(
                  presets.isEmpty ? 'Save this tempo' : 'Save',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );
          }
          final p = presets[i - 1];
          final active = p.setup == current;
          // A named chip shows its tempo; an unnamed one is already titled
          // by tempo, so it shows the time signature instead.
          final detail = p.name.isEmpty
              ? metronomeSignatureLabel(p.setup.beatsPerBar)
              : '${p.setup.bpm}';
          return _chip(
            context,
            semantics:
                '${p.title}, ${p.setup.summary}${active ? ', loaded' : ''}',
            hint: 'Long press to rename or delete',
            fill: active
                ? kMetronomeTint.withValues(alpha: light ? 0.3 : 0.16)
                : c.surfaceCard,
            border: active ? stroke : c.border,
            onTap: () => onLoad(i - 1),
            onLongPress: () => onMenu(i - 1),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  p.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                detail,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _chip(
    BuildContext context, {
    required String semantics,
    String? hint,
    required Color fill,
    required Color border,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    required List<Widget> children,
  }) {
    return Center(
      child: Semantics(
        button: true,
        label: semantics,
        hint: hint,
        excludeSemantics: true,
        child: Material(
          color: fill,
          shape: StadiumBorder(side: BorderSide(color: border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                height: 40,
                child: Row(mainAxisSize: MainAxisSize.min, children: children),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Find BPM pad
// ---------------------------------------------------------------------------

/// The dashed pad that opens the BPM finder (tap along, or listen).
class MetronomeFindBpmPad extends StatelessWidget {
  const MetronomeFindBpmPad({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final stroke = metronomeStroke(
      context,
    ).withValues(alpha: light ? 0.75 : 0.5);
    final radius = BorderRadius.circular(18);
    return Semantics(
      button: true,
      label: 'Find BPM. Tap along or let the phone listen',
      excludeSemantics: true,
      child: CustomPaint(
        foregroundPainter: _DashedRRectPainter(
          color: stroke,
          radius: 18,
          strokeWidth: 1.5,
        ),
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
              height: 60,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.graphic_eq_rounded,
                      size: 22,
                      color: c.textPrimary,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Find BPM',
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            'Tap along or let the phone listen',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
      Rect.fromLTWH(
        inset,
        inset,
        size.width - strokeWidth,
        size.height - strokeWidth,
      ),
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
        dashed.addPath(
          m.extractPath(d, (d + _dash).clamp(0, m.length)),
          Offset.zero,
        );
        d += _dash + _gap;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth;
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
          color: enabled
              ? kMetronomeTint
              : kMetronomeTint.withValues(alpha: 0.38),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Center(
              child: Icon(
                running ? Icons.stop_rounded : Icons.play_arrow_rounded,
                size: running ? 34 : 40,
                color: enabled
                    ? kMetronomeInk
                    : kMetronomeInk.withValues(alpha: 0.5),
                semanticLabel: label,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
