import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../services/guitar_tuning.dart';
import '../services/tone_math.dart';
import '../theme/app_colors.dart';

/// Tone generator colours. The teal tint is used as-is in dark mode; in
/// light mode a deeper teal keeps text and borders above 4.5:1.
class TonePalette {
  /// Fills, glows and the scope trace.
  final Color tint;

  /// Text and icons in the tint colour (contrast-safe on the background).
  final Color tintText;

  /// Text / icons on a filled [tint] surface.
  final Color onTint;

  /// Selected backgrounds.
  final Color tintSoft;

  /// The caution line.
  final Color warn;
  final bool dark;

  const TonePalette._(
    this.tint,
    this.tintText,
    this.onTint,
    this.tintSoft,
    this.warn,
    this.dark,
  );

  static const _teal = Color(0xFF4FD1C5);
  static const _tealDeep = Color(0xFF0F766E); // 5.5:1 on white

  static TonePalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? TonePalette._(
            _teal,
            _teal,
            const Color(0xFF06221F),
            _teal.withValues(alpha: 0.16),
            const Color(0xFFFFB86B),
            true,
          )
        : TonePalette._(
            _tealDeep,
            _tealDeep,
            Colors.white,
            _teal.withValues(alpha: 0.16),
            const Color(0xFFB4610C),
            false,
          );
  }
}

// ── Tabs ────────────────────────────────────────────────────────────────────

/// Two-option segmented control with a sliding thumb.
class ToneTabs extends StatelessWidget {
  final int index;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  const ToneTabs({
    super.key,
    required this.index,
    required this.labels,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    final n = labels.length;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
            child: FractionallySizedBox(
              widthFactor: 1 / n,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.tintSoft,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: p.tint.withValues(alpha: 0.55)),
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => onChanged(i),
                      child: Center(
                        child: Text(
                          labels[i],
                          style: TextStyle(
                            color: i == index ? p.tintText : c.textSecondary,
                            fontSize: 14.5,
                            fontWeight: i == index
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Waveform icon & selector ────────────────────────────────────────────────

class WaveIcon extends StatelessWidget {
  final ToneWave wave;
  final Color color;
  final double width;
  final double height;

  const WaveIcon({
    super.key,
    required this.wave,
    required this.color,
    this.width = 28,
    this.height = 16,
  });

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(width, height),
    painter: _WaveIconPainter(wave, color),
  );
}

class _WaveIconPainter extends CustomPainter {
  final ToneWave wave;
  final Color color;
  _WaveIconPainter(this.wave, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final h = size.height / 2 - 1.5;
    final mid = size.height / 2;
    final path = Path();
    // One and a half cycles.
    const n = 48;
    for (var i = 0; i <= n; i++) {
      final x = size.width * i / n;
      final phase = i / n * 1.5;
      var y = mid - waveSample(wave, phase) * h;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        // Square & saw: draw the jumps as straight verticals.
        final prev = waveSample(wave, (i - 1) / n * 1.5);
        final cur = waveSample(wave, phase);
        if ((cur - prev).abs() > 1) {
          path.lineTo(x, mid - prev * h);
        }
        y = mid - cur * h;
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WaveIconPainter old) =>
      old.wave != wave || old.color != color;
}

/// Sine / Square / Triangle / Saw, each with its little icon.
class WaveformSelector extends StatelessWidget {
  final ToneWave value;
  final ValueChanged<ToneWave> onChanged;
  final bool compact;

  const WaveformSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    return Container(
      height: compact ? 52 : 60,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          for (final w in ToneWave.values)
            Expanded(
              child: Semantics(
                button: true,
                selected: w == value,
                label: '${w.label} wave',
                excludeSemantics: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Material(
                    color: w == value ? p.tintSoft : Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(
                        color: w == value
                            ? p.tint.withValues(alpha: 0.55)
                            : Colors.transparent,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => onChanged(w),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          WaveIcon(
                            wave: w,
                            color: w == value ? p.tintText : c.iconSecondary,
                            width: 26,
                            height: compact ? 12 : 14,
                          ),
                          SizedBox(height: compact ? 3 : 5),
                          Text(
                            w.label,
                            maxLines: 1,
                            style: TextStyle(
                              color: w == value
                                  ? c.textPrimary
                                  : c.textSecondary,
                              fontSize: 12.5,
                              fontWeight: w == value
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Oscilloscope ────────────────────────────────────────────────────────────

/// Three cycles of the current waveform, whatever the frequency, so the
/// shape stays readable. The trace drifts while playing (faster for higher
/// tones) and sits still, dimmed, when stopped.
class Oscilloscope extends StatefulWidget {
  final ToneWave wave;
  final double hz;
  final double volume;
  final bool playing;

  /// Shown small in the top-left corner (e.g. "Sweeping").
  final String? badge;

  const Oscilloscope({
    super.key,
    required this.wave,
    required this.hz,
    required this.volume,
    required this.playing,
    this.badge,
  });

  @override
  State<Oscilloscope> createState() => _OscilloscopeState();
}

class _OscilloscopeState extends State<Oscilloscope>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _phase = 0;
  double _level = 0; // 0 stopped .. 1 playing, eased

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    _level = widget.playing ? 1 : 0;
    if (widget.playing) _ticker.start();
  }

  @override
  void didUpdateWidget(Oscilloscope old) {
    super.didUpdateWidget(old);
    if (widget.playing != old.playing && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration now) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : (now - _last).inMicroseconds / 1e6;
    _last = now;
    final target = widget.playing ? 1.0 : 0.0;
    var level = _level + (target - _level) * (1 - exp(-dt * 10));
    if ((level - target).abs() < 0.01) level = target;
    setState(() {
      _level = level;
      if (widget.playing) {
        // 0.3 cycles/s at 20 Hz up to ~1.2 at 20 kHz.
        _phase = (_phase + dt * (0.3 + 0.9 * hzToSlider(widget.hz))) % 1;
      }
    });
    if (!widget.playing && level == target) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    return ExcludeSemantics(
      child: Container(
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _ScopePainter(
                  wave: widget.wave,
                  phase: _phase,
                  level: _level,
                  volume: widget.volume,
                  colors: c,
                  palette: p,
                ),
              ),
            ),
            if (widget.badge != null)
              Positioned(
                left: 12,
                top: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: p.tintSoft,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.badge!,
                    style: TextStyle(
                      color: p.tintText,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
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

class _ScopePainter extends CustomPainter {
  final ToneWave wave;
  final double phase;
  final double level;
  final double volume;
  final AppColors colors;
  final TonePalette palette;

  _ScopePainter({
    required this.wave,
    required this.phase,
    required this.level,
    required this.volume,
    required this.colors,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final mid = h / 2;

    // Graticule.
    final grid = Paint()
      ..color = colors.borderSubtle
      ..strokeWidth = 1;
    for (var i = 1; i < 6; i++) {
      final x = w * i / 6;
      canvas.drawLine(Offset(x, 8), Offset(x, h - 8), grid);
    }
    for (final f in [0.25, 0.75]) {
      canvas.drawLine(Offset(0, h * f), Offset(w, h * f), grid);
    }
    canvas.drawLine(
      Offset(0, mid),
      Offset(w, mid),
      Paint()
        ..color = colors.border
        ..strokeWidth = 1,
    );

    // Trace. Amplitude follows the volume (never flat, so the shape shows).
    final amp = (h / 2 - 14) * (0.3 + 0.7 * volume.clamp(0.0, 1.0));
    const cycles = 3.0;
    final path = Path();
    final steps = max(60, (w / 1.5).round());
    double? prev;
    for (var i = 0; i <= steps; i++) {
      final x = w * i / steps;
      final ph = i / steps * cycles - phase * cycles;
      final v = waveSample(wave, ph);
      if (i == 0) {
        path.moveTo(x, mid - v * amp);
      } else {
        if (prev != null && (v - prev).abs() > 1) {
          path.lineTo(x, mid - prev * amp); // vertical edge
        }
        path.lineTo(x, mid - v * amp);
      }
      prev = v;
    }
    final traceColor = Color.lerp(colors.iconSecondary, palette.tint, level)!;
    if (level > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..color = palette.tint.withValues(
            alpha: (palette.dark ? 0.35 : 0.22) * level,
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeJoin = StrokeJoin.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = traceColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ScopePainter old) =>
      old.wave != wave ||
      old.phase != phase ||
      old.level != level ||
      old.volume != volume ||
      old.colors != colors ||
      old.palette.dark != palette.dark;
}

// ── Frequency dial ──────────────────────────────────────────────────────────

/// A horizontal log-scale ruler from 20 Hz to 20 kHz. Drag or fling it
/// under the fixed centre marker to change the frequency.
class FrequencyDial extends StatefulWidget {
  final double hz;

  /// Called with the raw (unrounded) frequency while dragging or flinging.
  final ValueChanged<double> onChanged;

  /// Accessibility increase / decrease.
  final ValueChanged<bool> onNudge;

  final double height;

  const FrequencyDial({
    super.key,
    required this.hz,
    required this.onChanged,
    required this.onNudge,
    this.height = 64,
  });

  @override
  State<FrequencyDial> createState() => _FrequencyDialState();
}

class _FrequencyDialState extends State<FrequencyDial>
    with SingleTickerProviderStateMixin {
  /// Pixels per decade (×10). The whole range is three decades.
  static const _ppd = 150.0;
  static final _maxPos = _posOf(kMaxHz);

  static double _posOf(double hz) => log(clampHz(hz) / kMinHz) / ln10 * _ppd;
  static double _hzOf(double pos) =>
      clampHz(kMinHz * pow(10, pos.clamp(0.0, _maxPos) / _ppd).toDouble());

  late final AnimationController _fling;

  @override
  void initState() {
    super.initState();
    _fling = AnimationController.unbounded(vsync: this)..addListener(_onFling);
  }

  /// Ruler position while the finger (or a fling) is driving it; null
  /// means follow [FrequencyDial.hz].
  double? _pos;

  double get _shownPos => _pos ?? _posOf(widget.hz);

  void _onFling() {
    final p = _fling.value.clamp(0.0, _maxPos);
    setState(() => _pos = p);
    widget.onChanged(_hzOf(p));
    if (p == 0 || p == _maxPos) {
      _fling.stop();
      _pos = null;
    }
  }

  @override
  void didUpdateWidget(FrequencyDial old) {
    super.didUpdateWidget(old);
    // Something else changed the frequency (preset, typing): let go.
    if (_pos != null && !_fling.isAnimating && !_dragging) _pos = null;
  }

  bool _dragging = false;

  @override
  void dispose() {
    _fling.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    return Semantics(
      slider: true,
      label: 'Frequency',
      value: formatHz(widget.hz),
      increasedValue: formatHz(nudgeHz(widget.hz, up: true)),
      decreasedValue: formatHz(nudgeHz(widget.hz, up: false)),
      onIncrease: () => widget.onNudge(true),
      onDecrease: () => widget.onNudge(false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          _fling.stop();
          _dragging = true;
          _pos = _posOf(widget.hz);
        },
        onHorizontalDragUpdate: (d) {
          final next = (_shownPos - d.delta.dx).clamp(0.0, _maxPos);
          setState(() => _pos = next);
          widget.onChanged(_hzOf(next));
        },
        onHorizontalDragEnd: (d) {
          _dragging = false;
          final v = -d.velocity.pixelsPerSecond.dx;
          if (v.abs() < 80) {
            setState(() => _pos = null);
            return;
          }
          _fling.value = _shownPos;
          _fling.animateWith(FrictionSimulation(0.02, _shownPos, v)).then((_) {
            if (mounted) setState(() => _pos = null);
          });
        },
        onHorizontalDragCancel: () {
          _dragging = false;
          setState(() => _pos = null);
        },
        child: Container(
          height: widget.height,
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => const LinearGradient(
              colors: [
                Color(0x00000000),
                Color(0xFF000000),
                Color(0xFF000000),
                Color(0x00000000),
              ],
              stops: [0, 0.16, 0.84, 1],
            ).createShader(r),
            child: CustomPaint(
              size: Size.infinite,
              painter: _DialPainter(
                pos: _shownPos,
                ppd: _ppd,
                colors: c,
                palette: p,
                textStyle: DefaultTextStyle.of(context).style,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  final double pos;
  final double ppd;
  final AppColors colors;
  final TonePalette palette;
  final TextStyle textStyle;

  _DialPainter({
    required this.pos,
    required this.ppd,
    required this.colors,
    required this.palette,
    required this.textStyle,
  });

  static String _label(int hz) => hz >= 1000 ? '${hz ~/ 1000}k' : '$hz';

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final h = size.height;
    final tickBase = h - 8.0;
    final minor = Paint()
      ..color = colors.textMuted
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final major = Paint()
      ..color = colors.textSecondary
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    double xOf(double hz) => cx + log(hz / kMinHz) / ln10 * ppd - pos;

    // Ends of the range: a faint band beyond them.
    final endPaint = Paint()..color = colors.borderSubtle;
    final x0 = xOf(kMinHz), x1 = xOf(kMaxHz);
    if (x0 > 0) canvas.drawRect(Rect.fromLTRB(0, 0, x0, h), endPaint);
    if (x1 < size.width) {
      canvas.drawRect(Rect.fromLTRB(x1, 0, size.width, h), endPaint);
    }

    for (var decade = 10; decade <= 10000; decade *= 10) {
      for (var m = 1; m <= 9; m++) {
        final f = decade * m;
        if (f < kMinHz || f > kMaxHz) continue;
        final x = xOf(f.toDouble());
        if (x < -20 || x > size.width + 20) continue;
        final isMajor = m == 1;
        final labelled = m == 1 || m == 2 || m == 5;
        final len = isMajor ? 22.0 : (labelled ? 16.0 : 10.0);
        canvas.drawLine(
          Offset(x, tickBase),
          Offset(x, tickBase - len),
          isMajor || labelled ? major : minor,
        );
        if (labelled) {
          final tp = TextPainter(
            text: TextSpan(
              text: _label(f),
              style: textStyle.copyWith(
                // Fade a label as it passes under the centre marker.
                color: (isMajor ? colors.textPrimary : colors.textSecondary)
                    .withValues(
                      alpha: ((x - cx).abs() / 26).clamp(0.15, 1.0).toDouble(),
                    ),
                fontSize: isMajor ? 12.5 : 11,
                fontWeight: isMajor ? FontWeight.w700 : FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(x - tp.width / 2, tickBase - 26 - tp.height));
        }
      }
    }
    // Half-way ticks between 1-2 … give the ruler some texture.
    for (var decade = 10; decade <= 10000; decade *= 10) {
      for (var m = 1; m < 10; m++) {
        final f = decade * (m + 0.5);
        if (f < kMinHz || f > kMaxHz) continue;
        final x = xOf(f);
        if (x < -4 || x > size.width + 4) continue;
        canvas.drawLine(Offset(x, tickBase), Offset(x, tickBase - 5), minor);
      }
    }

    // Centre marker.
    final marker = Paint()
      ..color = palette.tint
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, 10), Offset(cx, h - 4), marker);
    final tri = Path()
      ..moveTo(cx - 7, 0)
      ..lineTo(cx + 7, 0)
      ..lineTo(cx, 8)
      ..close();
    canvas.drawPath(tri, Paint()..color = palette.tint);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.pos != pos ||
      old.colors != colors ||
      old.palette.dark != palette.dark;
}

// ── Hold-to-repeat button ───────────────────────────────────────────────────

/// A round −/+ button: one step per tap; holding repeats, speeding up.
/// [onStep] gets how many repeats have happened so far (0 for the tap).
class RepeatButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final ValueChanged<int> onStep;
  final bool enabled;
  final double size;

  const RepeatButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onStep,
    this.enabled = true,
    this.size = 48,
  });

  @override
  State<RepeatButton> createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<RepeatButton> {
  Timer? _timer;
  int _count = 0;
  bool _down = false;

  void _start() {
    if (!widget.enabled) return;
    _count = 0;
    setState(() => _down = true);
    widget.onStep(0);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 400), _repeat);
  }

  void _repeat() {
    if (!mounted || !widget.enabled) return _end();
    _count++;
    widget.onStep(_count);
    _timer = Timer(Duration(milliseconds: _count < 8 ? 110 : 55), _repeat);
  }

  void _end() {
    _timer?.cancel();
    _timer = null;
    if (mounted && _down) setState(() => _down = false);
  }

  @override
  void didUpdateWidget(RepeatButton old) {
    super.didUpdateWidget(old);
    if (!widget.enabled) _end();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    // Raw pointer events rather than a tap recognizer: a held finger must
    // keep repeating, and a tap recognizer gives up when a long press wins.
    return Tooltip(
      message: widget.tooltip,
      triggerMode: TooltipTriggerMode.manual,
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        label: widget.tooltip,
        onTap: widget.enabled ? () => widget.onStep(0) : null,
        excludeSemantics: true,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => _start(),
          onPointerUp: (_) => _end(),
          onPointerCancel: (_) => _end(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _down ? p.tintSoft : c.surfaceCard,
              border: Border.all(
                color: _down ? p.tint.withValues(alpha: 0.6) : c.border,
              ),
            ),
            child: Icon(
              widget.icon,
              size: 22,
              color: widget.enabled ? c.textPrimary : c.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ── Volume ──────────────────────────────────────────────────────────────────

class ToneVolumeRow extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;

  const ToneVolumeRow({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    final pct = (value * 100).round();
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Icon(
            value == 0
                ? Icons.volume_off_rounded
                : value < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            size: 22,
            color: c.iconSecondary,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: p.tint,
                inactiveTrackColor: c.surfaceElevated,
                thumbColor: p.tint,
                overlayColor: p.tint.withValues(alpha: 0.14),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                trackShape: const RoundedRectSliderTrackShape(),
              ),
              child: Slider(
                value: value,
                onChanged: onChanged,
                semanticFormatterCallback: (v) =>
                    'Volume ${(v * 100).round()}%',
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '$pct%',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pitch pipe ──────────────────────────────────────────────────────────────

/// Twelve note holes around a round pitch pipe, C at the top going
/// clockwise, with the current note and its frequency in the middle.
class PitchPipeWheel extends StatelessWidget {
  /// Pitch class (0 = C) of the note last chosen.
  final int selected;
  final bool playing;
  final int octave;
  final double a4;
  final ValueChanged<int> onNote;
  final VoidCallback onCentre;

  const PitchPipeWheel({
    super.key,
    required this.selected,
    required this.playing,
    required this.octave,
    required this.a4,
    required this.onNote,
    required this.onCentre,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final size = min(box.maxWidth, box.maxHeight);
        final btn = (size * 0.165).clamp(44.0, 64.0);
        final ring = size / 2 - btn / 2 - 6;
        final centreD = (ring - btn / 2) * 2 - 14;
        final midi = pipeMidi(selected, octave);
        final hz = midiToHz(midi, a4: a4);

        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              children: [
                // The pipe's body.
                Positioned.fill(
                  child: CustomPaint(
                    painter: _PipeBodyPainter(
                      colors: c,
                      palette: p,
                      ring: ring,
                      hole: btn,
                    ),
                  ),
                ),
                // Centre: the note, tap to stop / replay.
                Center(
                  child: Semantics(
                    button: true,
                    liveRegion: true,
                    label: playing
                        ? 'Playing ${noteName(midi)}${noteOctave(midi)}, '
                              '${hz.toStringAsFixed(1)} Hz. Tap to stop'
                        : '${noteName(midi)}${noteOctave(midi)}. Tap to play',
                    excludeSemantics: true,
                    child: _PipeCentre(
                      diameter: max(60.0, centreD),
                      midi: midi,
                      hz: hz,
                      playing: playing,
                      onTap: onCentre,
                    ),
                  ),
                ),
                for (var pc = 0; pc < 12; pc++)
                  _hole(context, pc, size, btn, ring, c, p),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _hole(
    BuildContext context,
    int pc,
    double size,
    double btn,
    double ring,
    AppColors c,
    TonePalette p,
  ) {
    final a = -pi / 2 + pc * pi / 6;
    final cx = size / 2 + cos(a) * ring;
    final cy = size / 2 + sin(a) * ring;
    final on = playing && pc == selected;
    final chosen = pc == selected;
    final sharp = noteName(pc).length > 1;
    final midi = pipeMidi(pc, octave);
    return Positioned(
      left: cx - btn / 2,
      top: cy - btn / 2,
      width: btn,
      height: btn,
      child: Semantics(
        button: true,
        selected: on,
        label:
            '${noteName(pc)}${sharp ? ' or ${noteName(pc, flats: true)}' : ''}'
            '$octave, ${midiToHz(midi, a4: a4).toStringAsFixed(1)} Hz',
        excludeSemantics: true,
        child: GestureDetector(
          onTap: () => onNote(pc),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: on
                  ? p.tint
                  : sharp
                  ? c.surfaceElevated
                  : c.scaffoldBg,
              border: Border.all(
                color: on
                    ? p.tint
                    : chosen
                    ? p.tint.withValues(alpha: 0.8)
                    : c.border,
                width: chosen ? 2 : 1,
              ),
              boxShadow: on
                  ? [
                      BoxShadow(
                        color: p.tint.withValues(alpha: p.dark ? 0.55 : 0.45),
                        blurRadius: 18,
                        spreadRadius: 2,
                      ),
                    ]
                  : const [],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  noteName(pc),
                  style: TextStyle(
                    color: on ? p.onTint : c.textPrimary,
                    fontSize: btn * (sharp ? 0.28 : 0.34),
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                  ),
                ),
                if (sharp)
                  Text(
                    noteName(pc, flats: true),
                    style: TextStyle(
                      color: on
                          ? p.onTint.withValues(alpha: 0.8)
                          : c.textSecondary,
                      fontSize: btn * 0.2,
                      fontWeight: FontWeight.w600,
                      height: 1.05,
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

class _PipeCentre extends StatelessWidget {
  final double diameter;
  final int midi;
  final double hz;
  final bool playing;
  final VoidCallback onTap;

  const _PipeCentre({
    required this.diameter,
    required this.midi,
    required this.hz,
    required this.playing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    final big = diameter * 0.3;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: playing ? p.tintSoft : c.surfaceCard,
          border: Border.all(
            color: playing ? p.tint.withValues(alpha: 0.7) : c.border,
            width: playing ? 2 : 1,
          ),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      noteName(midi),
                      style: TextStyle(
                        color: playing ? p.tintText : c.textPrimary,
                        fontSize: big,
                        fontWeight: FontWeight.w800,
                        height: 1,
                        letterSpacing: -1,
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.only(left: 2, bottom: big * 0.08),
                      child: Text(
                        '${noteOctave(midi)}',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: big * 0.4,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${hz.toStringAsFixed(1)} Hz',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: max(12.0, big * 0.3),
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      size: 16,
                      color: playing ? p.tintText : c.iconSecondary,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      playing ? 'Tap to stop' : 'Tap to play',
                      style: TextStyle(
                        color: playing ? p.tintText : c.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PipeBodyPainter extends CustomPainter {
  final AppColors colors;
  final TonePalette palette;
  final double ring;
  final double hole;

  _PipeBodyPainter({
    required this.colors,
    required this.palette,
    required this.ring,
    required this.hole,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final outer = ring + hole / 2 + 4;
    canvas.drawCircle(centre, outer, Paint()..color = colors.surfaceCard);
    canvas.drawCircle(
      centre,
      outer,
      Paint()
        ..color = colors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    // The groove the holes sit in.
    canvas.drawCircle(
      centre,
      ring,
      Paint()
        ..color = colors.borderSubtle
        ..style = PaintingStyle.stroke
        ..strokeWidth = hole * 0.55,
    );
  }

  @override
  bool shouldRepaint(_PipeBodyPainter old) =>
      old.ring != ring ||
      old.hole != hole ||
      old.colors != colors ||
      old.palette.dark != palette.dark;
}

/// "Octave  −  4  +"
class OctaveStepper extends StatelessWidget {
  final int octave;
  final ValueChanged<int> onChanged;

  const OctaveStepper({
    super.key,
    required this.octave,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Octave',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            tooltip: 'Lower octave',
            onPressed: octave > kMinOctave ? () => onChanged(octave - 1) : null,
            icon: const Icon(Icons.remove_rounded),
            color: c.textPrimary,
            disabledColor: c.textMuted,
          ),
          SizedBox(
            width: 22,
            child: Text(
              '$octave',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            tooltip: 'Higher octave',
            onPressed: octave < kMaxOctave ? () => onChanged(octave + 1) : null,
            icon: const Icon(Icons.add_rounded),
            color: c.textPrimary,
            disabledColor: c.textMuted,
          ),
        ],
      ),
    );
  }
}
