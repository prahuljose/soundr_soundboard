import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Large waveform with a highlighted selection and two draggable trim handles.
///
/// [trimStart] / [trimEnd] are normalised (0..1) positions in the clip. The
/// whole strip is the hit area: a drag moves whichever handle is nearest to
/// where the finger went down, so the handles are easy to grab even though
/// they're drawn as thin bars.
class ClipTrimWaveform extends StatefulWidget {
  final List<double> levels;
  final double trimStart;
  final double trimEnd;

  /// Clip length in seconds — used for the handles' spoken values and step.
  final double totalDuration;
  final ValueChanged<double> onStartChanged;
  final ValueChanged<double> onEndChanged;
  final double height;

  /// Horizontal space either side of the waveform that still grabs a
  /// handle, so a handle at the very start/end is as easy to catch as one in
  /// the middle. The widget lays out [inset] wider than the waveform.
  final double inset;

  /// Smallest selection, as a fraction of the clip.
  static const minGap = 0.02;

  const ClipTrimWaveform({
    super.key,
    required this.levels,
    required this.trimStart,
    required this.trimEnd,
    required this.totalDuration,
    required this.onStartChanged,
    required this.onEndChanged,
    this.height = 128,
    this.inset = 18,
  });

  @override
  State<ClipTrimWaveform> createState() => _ClipTrimWaveformState();
}

class _ClipTrimWaveformState extends State<ClipTrimWaveform> {
  /// How far the handle bars reach above and below the waveform.
  static const _overhang = 6.0;

  String? _active;

  // ── Drag ────────────────────────────────────────────────────────────────

  void _setStart(double v) => widget.onStartChanged(
    v.clamp(0.0, widget.trimEnd - ClipTrimWaveform.minGap),
  );

  void _setEnd(double v) => widget.onEndChanged(
    v.clamp(widget.trimStart + ClipTrimWaveform.minGap, 1.0),
  );

  // ── Accessibility: step a handle by ~0.1 s (at least 1% of the clip) ────

  double get _step {
    final d = widget.totalDuration;
    if (d <= 0) return 0.05;
    return (0.1 / d).clamp(0.01, 0.1);
  }

  static String _clock(double seconds) {
    final tenths = (seconds.clamp(0, double.infinity) * 10).round();
    final m = tenths ~/ 600;
    final s = (tenths % 600) / 10;
    return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }

  String _spoken(double v) => _clock(v * widget.totalDuration);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final light = Theme.of(context).brightness == Brightness.light;
    final h = widget.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final inset = widget.inset;
        final w = constraints.maxWidth - inset * 2;
        final startX = widget.trimStart * w;
        final endX = widget.trimEnd * w;

        // A horizontal drag trims; a vertical one is left to the page's scroll
        // view (the two recognisers compete, whichever passes slop first
        // wins), so swiping over the waveform to scroll doesn't move a handle.
        // (dx - inset) / w is the finger's 0..1 position.
        void move(Offset local) {
          if (_active == null) return;
          final pos = ((local.dx - inset) / w).clamp(0.0, 1.0);
          _active == 'start' ? _setStart(pos) : _setEnd(pos);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragDown: (d) {
            final x = d.localPosition.dx - inset;
            _active = (x - startX).abs() <= (x - endX).abs() ? 'start' : 'end';
          },
          onHorizontalDragStart: (d) => move(d.localPosition),
          onHorizontalDragUpdate: (d) => move(d.localPosition),
          onHorizontalDragEnd: (_) => _active = null,
          onHorizontalDragCancel: () => _active = null,
          child: SizedBox(
            width: constraints.maxWidth,
            height: h + _overhang * 2,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  left: inset,
                  right: inset,
                  child: ExcludeSemantics(
                    child: CustomPaint(
                      painter: _TrimWavePainter(
                        levels: widget.levels,
                        trimStart: widget.trimStart,
                        trimEnd: widget.trimEnd,
                        accent: accent,
                        idle: c.textPrimary.withValues(
                          alpha: light ? 0.2 : 0.16,
                        ),
                        selection: accent.withValues(alpha: light ? 0.12 : 0.1),
                        overhang: _overhang,
                      ),
                    ),
                  ),
                ),
                // Invisible 44px semantic targets over each handle so screen
                // readers can nudge the trim points.
                _handleSemantics(
                  x: inset + startX,
                  label: 'Trim start',
                  value: widget.trimStart,
                  onIncrease: () => _setStart(widget.trimStart + _step),
                  onDecrease: () => _setStart(widget.trimStart - _step),
                ),
                _handleSemantics(
                  x: inset + endX,
                  label: 'Trim end',
                  value: widget.trimEnd,
                  onIncrease: () => _setEnd(widget.trimEnd + _step),
                  onDecrease: () => _setEnd(widget.trimEnd - _step),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _handleSemantics({
    required double x,
    required String label,
    required double value,
    required VoidCallback onIncrease,
    required VoidCallback onDecrease,
  }) {
    return Positioned(
      left: x - 22,
      top: 0,
      bottom: 0,
      width: 44,
      child: Semantics(
        slider: true,
        label: label,
        value: _spoken(value),
        increasedValue: _spoken((value + _step).clamp(0.0, 1.0)),
        decreasedValue: _spoken((value - _step).clamp(0.0, 1.0)),
        onIncrease: onIncrease,
        onDecrease: onDecrease,
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _TrimWavePainter extends CustomPainter {
  final List<double> levels;
  final double trimStart;
  final double trimEnd;
  final Color accent;
  final Color idle;
  final Color selection;
  final double overhang;

  _TrimWavePainter({
    required this.levels,
    required this.trimStart,
    required this.trimEnd,
    required this.accent,
    required this.idle,
    required this.selection,
    required this.overhang,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final top = overhang;
    final waveH = size.height - overhang * 2;
    final startX = trimStart * w;
    final endX = trimEnd * w;

    // ── Selected region ──────────────────────────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(startX, top, endX, top + waveH),
        const Radius.circular(10),
      ),
      Paint()..color = selection,
    );

    // ── Bars ─────────────────────────────────────────────────────────────
    if (levels.isNotEmpty) {
      final slot = w / levels.length;
      final barW = (slot * 0.6).clamp(1.5, 4.0);
      final paint = Paint();
      final midY = top + waveH / 2;
      final maxBar = waveH - 12;
      for (var i = 0; i < levels.length; i++) {
        final centre = (i + 0.5) * slot;
        final bh = 4 + maxBar * levels[i].clamp(0.0, 1.0);
        paint.color = centre >= startX && centre <= endX ? accent : idle;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(centre, midY),
              width: barW,
              height: bh,
            ),
            Radius.circular(barW / 2),
          ),
          paint,
        );
      }
    }

    // ── Handles ──────────────────────────────────────────────────────────
    final handle = Paint()..color = accent;
    for (final x in [startX, endX]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x - 2, 0, 4, size.height),
          const Radius.circular(2),
        ),
        handle,
      );
    }
  }

  @override
  bool shouldRepaint(_TrimWavePainter old) =>
      old.levels != levels ||
      old.trimStart != trimStart ||
      old.trimEnd != trimEnd ||
      old.accent != accent ||
      old.idle != idle ||
      old.selection != selection;
}
