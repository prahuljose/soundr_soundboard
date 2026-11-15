import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../services/bpm_detector.dart';
import '../services/haptics.dart';
import '../services/metronome_presets.dart';
import '../theme/app_colors.dart';
import 'metronome_widgets.dart';
import 'permission_denied_card.dart';

const _kRate = 44100;

/// Opens the BPM finder. Resolves to the tempo the user chose to use
/// (already clamped to the metronome's range), or null if dismissed.
///
/// [clock] is a monotonic time source for tap timing; [debugAudio] feeds
/// 16-bit PCM at 44.1 kHz instead of the microphone (and skips the
/// permission request). Both are for tests.
Future<int?> showBpmFinderSheet(
  BuildContext context, {
  Duration Function()? clock,
  Stream<Uint8List>? debugAudio,
}) {
  final c = Theme.of(context).extension<AppColors>()!;
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: c.surfaceCard,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => BpmFinderSheet(clock: clock, debugAudio: debugAudio),
  );
}

enum _Mode { tap, listen }

enum _Listen { idle, starting, listening, result, failed, denied, error }

/// Finds a tempo two ways: tapping along on a pad, or letting the phone
/// listen to music / clapping for a few seconds.
class BpmFinderSheet extends StatefulWidget {
  const BpmFinderSheet({super.key, this.clock, this.debugAudio});

  final Duration Function()? clock;

  @visibleForTesting
  final Stream<Uint8List>? debugAudio;

  /// How much audio a listen takes at most.
  static const listenMs = 8000;

  /// A clear, stable beat can finish the listen from here.
  static const earlyMs = 6000;

  @override
  State<BpmFinderSheet> createState() => _BpmFinderSheetState();
}

class _BpmFinderSheetState extends State<BpmFinderSheet>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  _Mode _mode = _Mode.tap;

  // ── Tap ──
  final _tap = TapTempo();
  final _stopwatch = Stopwatch()..start();
  late final _tapPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    value: 1,
  );
  Timer? _tapTimeout;

  // ── Listen ──
  AudioRecorder? _recorder; // created on first real use
  late final Stream<Uint8List>? _debugAudio = widget.debugAudio?.asBroadcastStream();
  StreamSubscription<Uint8List>? _sub;
  late final _detector = BpmDetector(sampleRate: _kRate, onOnset: _onOnset);
  late final _beatPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1,
  );
  _Listen _listen = _Listen.idle;
  double _progress = 0;
  double _level = 0;
  double? _liveBpm; // tentative, while listening
  double? _resultBpm;
  double _confidence = 0;
  int _lastUiMs = 0;
  int _lastEstimateMs = 0;
  final List<double> _recent = [];

  Duration _now() => widget.clock?.call() ?? _stopwatch.elapsed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tapTimeout?.cancel();
    _sub?.cancel();
    try {
      _recorder?.dispose();
    } catch (_) {}
    _tapPulse.dispose();
    _beatPulse.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the mic in the background.
    if (state == AppLifecycleState.paused &&
        (_listen == _Listen.listening || _listen == _Listen.starting)) {
      _stopMic();
      if (mounted) setState(() => _listen = _Listen.idle);
    }
  }

  // ── Mode ────────────────────────────────────────────────────────────────

  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    Haptics.selection();
    setState(() => _mode = mode);
    if (mode == _Mode.listen) {
      if (_listen == _Listen.idle) _startListening();
    } else if (_listen == _Listen.listening || _listen == _Listen.starting) {
      _stopMic();
      setState(() => _listen = _Listen.idle);
    }
  }

  // ── Tap ─────────────────────────────────────────────────────────────────

  void _onTap() {
    Haptics.light();
    _tap.tap(_now());
    _tapPulse.forward(from: 0);
    // After a pause the next tap starts over; say so once it has lapsed.
    _tapTimeout?.cancel();
    _tapTimeout = Timer(_tap.timeout, () {
      if (mounted) setState(() {});
    });
    setState(() {});
  }

  bool get _tapLapsed =>
      _tap.count > 0 && !(_tapTimeout?.isActive ?? false);

  String get _tapHint {
    if (_tap.count == 0) return 'Tap the pad in time with the music';
    if (_tap.count == 1) return 'Keep tapping…';
    final taps = '${_tap.count} taps';
    if (_tapLapsed) return 'Tap again to start over · $taps';
    return _tap.isSteady ? 'Steady · $taps' : 'Keep tapping… · $taps';
  }

  // ── Listen ──────────────────────────────────────────────────────────────

  Future<void> _startListening() async {
    if (_listen == _Listen.starting || _listen == _Listen.listening) return;
    setState(() {
      _listen = _Listen.starting;
      _progress = 0;
      _level = 0;
      _liveBpm = null;
      _resultBpm = null;
    });
    final Stream<Uint8List> stream;
    try {
      final debug = _debugAudio;
      if (debug != null) {
        stream = debug;
      } else {
        final status = await Permission.microphone.request();
        if (!mounted) return;
        if (!status.isGranted) {
          setState(() => _listen = _Listen.denied);
          return;
        }
        stream = await (_recorder ??= AudioRecorder()).startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: _kRate,
            numChannels: 1,
            // Voice processing would flatten the beats we're listening for.
            autoGain: false,
            echoCancel: false,
            noiseSuppress: false,
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _listen = _Listen.error);
      return;
    }
    if (!mounted || _mode != _Mode.listen || _listen != _Listen.starting) {
      // Closed or switched away while the mic was opening.
      try {
        await _recorder?.stop();
      } catch (_) {}
      return;
    }
    _detector.reset();
    _lastUiMs = 0;
    _lastEstimateMs = 0;
    _recent.clear();
    _sub = stream.listen(
      _onPcm,
      onError: (Object _) {
        _stopMic();
        if (mounted) setState(() => _listen = _Listen.error);
      },
    );
    setState(() => _listen = _Listen.listening);
  }

  void _stopMic() {
    _sub?.cancel();
    _sub = null;
    _recorder?.stop().then((_) {}, onError: (Object _) {});
  }

  void _onOnset(double strength) {
    if (mounted && _listen == _Listen.listening) _beatPulse.forward(from: 0);
  }

  void _onPcm(Uint8List bytes) {
    if (_listen != _Listen.listening) return;
    _detector.addPcm16(bytes);
    final ms = _detector.audioMs;

    var finished = ms >= BpmFinderSheet.listenMs;
    if (ms - _lastEstimateMs >= 500 || finished) {
      _lastEstimateMs = ms;
      final e = _detector.estimate();
      if (e != null && e.isReliable) {
        _liveBpm = e.bpm;
        _confidence = e.confidence;
        _recent.add(e.bpm);
      } else {
        _liveBpm = null;
        _recent.clear();
      }
      // A clear beat that has held still for the last three looks is done.
      if (ms >= BpmFinderSheet.earlyMs &&
          e != null &&
          e.confidence >= 0.5 &&
          _recent.length >= 3 &&
          _recent
              .skip(_recent.length - 3)
              .every((b) => (b - e.bpm).abs() <= 1)) {
        finished = true;
      }
    }

    if (finished) {
      _stopMic();
      final bpm = _liveBpm;
      setState(() {
        _progress = 1;
        _level = 0;
        _resultBpm = bpm;
        _listen = bpm == null ? _Listen.failed : _Listen.result;
      });
      if (bpm != null) Haptics.medium();
      return;
    }
    if (ms - _lastUiMs >= 60) {
      _lastUiMs = ms;
      setState(() {
        _progress = (ms / BpmFinderSheet.listenMs).clamp(0.0, 1.0);
        // Perceptual-ish level: −50 dBFS → 0, −10 dBFS → 1.
        final db = 20 * log(max(_detector.level, 1e-6)) / ln10;
        _level = ((db + 50) / 40).clamp(0.0, 1.0);
      });
    }
  }

  void _scale(double factor) {
    final bpm = _resultBpm;
    if (bpm == null) return;
    Haptics.selection();
    setState(() => _resultBpm = bpm * factor);
  }

  // ── Result ──────────────────────────────────────────────────────────────

  /// The tempo "Use" would set, or null if there's nothing to use yet.
  int? get _usableBpm {
    final double? bpm = switch (_mode) {
      _Mode.tap => _tap.bpm,
      _Mode.listen => _listen == _Listen.result ? _resultBpm : null,
    };
    if (bpm == null || !bpm.isFinite) return null;
    return bpm.round().clamp(kMetronomeMinBpm, kMetronomeMaxBpm);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final use = _usableBpm;
    final mq = MediaQuery.of(context);

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height - mq.padding.top - 12),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.handleBar,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Find BPM',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              MetronomeSegmented<_Mode>(
                label: 'How to find the tempo',
                options: _Mode.values,
                selected: _mode,
                onSelect: _setMode,
                background: c.scaffoldBg,
                semanticLabel: (m) => m == _Mode.tap ? 'Tap' : 'Listen',
                builder: (context, m, selected, color) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      m == _Mode.tap ? Icons.touch_app_rounded : Icons.mic_rounded,
                      size: 18,
                      color: color,
                    ),
                    const SizedBox(width: 6),
                    metronomeSegmentText(m == _Mode.tap ? 'Tap' : 'Listen', selected, color),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 296),
                child: _mode == _Mode.tap ? _tapBody(c) : _listenBody(c, font),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: use == null
                    ? null
                    : () {
                        Haptics.medium();
                        Navigator.of(context).pop(use);
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: kMetronomeTint,
                  foregroundColor: kMetronomeInk,
                  disabledBackgroundColor: kMetronomeTint.withValues(alpha: 0.3),
                  disabledForegroundColor: c.textSecondary,
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  textStyle: TextStyle(
                    fontFamily: font,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                child: Text(use == null ? 'Use this tempo' : 'Use $use BPM'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Tap body ────────────────────────────────────────────────────────────

  Widget _tapBody(AppColors c) {
    final bpm = _tap.bpm;
    final light = Theme.of(context).brightness == Brightness.light;
    final stroke = metronomeStroke(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _BigBpm(text: bpm == null ? '––' : '${bpm.round()}', dim: bpm == null),
        const SizedBox(height: 4),
        Text(
          _tapHint,
          style: TextStyle(
            color: _tap.isSteady && !_tapLapsed ? c.textPrimary : c.textSecondary,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 18),
        Semantics(
          button: true,
          label: 'Tap pad. Tap in time with the music',
          onTap: _onTap,
          excludeSemantics: true,
          child: Listener(
            // Pointer-down, not tap-up: the beat is when the finger lands.
            onPointerDown: (_) => _onTap(),
            behavior: HitTestBehavior.opaque,
            child: AnimatedBuilder(
              animation: _tapPulse,
              builder: (context, _) {
                final t = Curves.easeOut.transform(_tapPulse.value);
                return SizedBox(
                  key: const ValueKey('bpm-tap-pad'),
                  width: 176,
                  height: 176,
                  child: CustomPaint(
                    painter: _PulsePainter(
                      pulse: t,
                      fill: kMetronomeTint.withValues(
                        alpha: (light ? 0.22 : 0.10) + (light ? 0.5 : 0.45) * (1 - t),
                      ),
                      stroke: stroke,
                      ring: stroke,
                    ),
                    child: Center(
                      child: Text(
                        'TAP',
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.4,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  // ── Listen body ─────────────────────────────────────────────────────────

  Widget _listenBody(AppColors c, String? font) {
    if (_listen == _Listen.denied) {
      return Center(
        child: PermissionDeniedCard(
          permission: Permission.microphone,
          icon: Icons.mic_rounded,
          permissionLabel: 'Microphone',
          purpose:
              'Soundr listens for the beat in music or clapping to work out its tempo.',
          onGranted: () {
            setState(() => _listen = _Listen.idle);
            _startListening();
          },
        ),
      );
    }

    final light = Theme.of(context).brightness == Brightness.light;
    final stroke = metronomeStroke(context);
    final listening = _listen == _Listen.listening || _listen == _Listen.starting;
    final shown = _listen == _Listen.result ? _resultBpm : (listening ? _liveBpm : null);

    final (String title, String detail) = switch (_listen) {
      _Listen.idle => ('Ready to listen', 'Play music or clap near the phone'),
      _Listen.starting ||
      _Listen.listening => ('Listening…', 'Keep the music or clapping going'),
      _Listen.result => (_confidenceLabel, 'Sounds off? Try half or double'),
      _Listen.failed => (
        'Couldn’t find a steady beat',
        'Move closer to the music, or tap along instead',
      ),
      _Listen.error => ('Couldn’t open the microphone', 'Tap along instead, or try again'),
      _Listen.denied => ('', ''),
    };

    final Widget centre;
    if (shown != null) {
      centre = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${shown.round()}',
            key: const ValueKey('bpm-listen-value'),
            style: TextStyle(
              color: listening ? c.textSecondary : c.textPrimary,
              fontSize: 52,
              fontWeight: FontWeight.w600,
              letterSpacing: -1.5,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'BPM',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      );
    } else {
      centre = Icon(
        _listen == _Listen.failed || _listen == _Listen.error
            ? Icons.mic_off_rounded
            : Icons.mic_rounded,
        size: 40,
        color: listening ? c.textPrimary : c.textSecondary,
      );
    }

    final result = _resultBpm;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          label: shown != null
              ? '${shown.round()} BPM${listening ? ', still listening' : ''}'
              : title,
          excludeSemantics: true,
          child: AnimatedBuilder(
            animation: _beatPulse,
            builder: (context, child) {
              final t = Curves.easeOut.transform(_beatPulse.value);
              return SizedBox(
                width: 176,
                height: 176,
                child: CustomPaint(
                  painter: _PulsePainter(
                    pulse: listening ? t : 1,
                    progress: listening ? _progress : null,
                    level: listening ? _level : 0,
                    fill: kMetronomeTint.withValues(
                      alpha: (light ? 0.22 : 0.10) +
                          (listening ? (light ? 0.5 : 0.45) * (1 - t) : 0),
                    ),
                    stroke: _listen == _Listen.result ? stroke : c.border,
                    ring: stroke,
                    track: c.border,
                  ),
                  child: Center(child: child),
                ),
              );
            },
            child: centre,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_listen == _Listen.result) ...[
              _ConfidenceBars(level: _confidenceLevel),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_listen == _Listen.result && result != null) ...[
                _pill(
                  c,
                  font,
                  label: '½×',
                  tooltip: 'Half tempo',
                  onTap: result / 2 >= kMetronomeMinBpm ? () => _scale(0.5) : null,
                ),
                const SizedBox(width: 8),
              ],
              if (!listening)
                Flexible(
                  child: _pill(
                    c,
                    font,
                    icon: _listen == _Listen.idle
                        ? Icons.mic_rounded
                        : Icons.refresh_rounded,
                    label: _listen == _Listen.idle ? 'Start listening' : 'Listen again',
                    onTap: _startListening,
                  ),
                ),
              if (_listen == _Listen.result && result != null) ...[
                const SizedBox(width: 8),
                _pill(
                  c,
                  font,
                  label: '2×',
                  tooltip: 'Double tempo',
                  onTap: result * 2 <= kMetronomeMaxBpm ? () => _scale(2) : null,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  int get _confidenceLevel => _confidence >= 0.5
      ? 3
      : _confidence >= 0.34
          ? 2
          : 1;

  String get _confidenceLabel => switch (_confidenceLevel) {
    3 => 'Clear beat',
    2 => 'Fairly sure',
    _ => 'Rough guess',
  };

  Widget _pill(
    AppColors c,
    String? font, {
    required String label,
    IconData? icon,
    String? tooltip,
    required VoidCallback? onTap,
  }) {
    final style = OutlinedButton.styleFrom(
      foregroundColor: c.textPrimary,
      disabledForegroundColor: c.textMuted,
      backgroundColor: c.scaffoldBg,
      side: BorderSide(color: c.border),
      minimumSize: const Size(60, 44),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: const StadiumBorder(),
      textStyle: TextStyle(
        fontFamily: font,
        fontSize: 15,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final button = icon == null
        ? OutlinedButton(onPressed: onTap, style: style, child: Text(label))
        : OutlinedButton.icon(
            onPressed: onTap,
            style: style,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// The large tempo figure with its "BPM" caption.
class _BigBpm extends StatelessWidget {
  const _BigBpm({required this.text, required this.dim});

  final String text;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      label: dim ? 'No tempo yet' : '$text BPM',
      excludeSemantics: true,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            text,
            key: const ValueKey('bpm-tap-value'),
            style: TextStyle(
              color: dim ? c.textMuted : c.textPrimary,
              fontSize: 60,
              fontWeight: FontWeight.w600,
              letterSpacing: -2,
              height: 1.05,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'BPM',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Three bars, [level] of them lit.
class _ConfidenceBars extends StatelessWidget {
  const _ConfidenceBars({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final on = metronomeStroke(context);
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 4,
              height: 7.0 + 4 * i,
              margin: EdgeInsets.only(left: i == 0 ? 0 : 3),
              decoration: BoxDecoration(
                color: i < level ? on : c.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

/// A disc that flashes and throws off a ring on each beat ([pulse] runs
/// 0 → 1 after one). While listening it also shows the input [level] as a
/// swelling inner disc and the [progress] as an arc around the rim.
class _PulsePainter extends CustomPainter {
  const _PulsePainter({
    required this.pulse,
    required this.fill,
    required this.stroke,
    required this.ring,
    this.track,
    this.progress,
    this.level = 0,
  });

  final double pulse;
  final Color fill, stroke, ring;
  final Color? track;
  final double? progress;
  final double level;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final outer = size.shortestSide / 2;
    final r = outer - 14; // room for the ring to travel

    // The ring thrown off by a beat.
    if (pulse < 1) {
      canvas.drawCircle(
        centre,
        r + 12 * pulse,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = ring.withValues(alpha: 0.6 * (1 - pulse)),
      );
    }

    final disc = r * (1 - 0.035 * (1 - pulse));
    canvas.drawCircle(centre, disc, Paint()..color = fill);
    if (level > 0) {
      canvas.drawCircle(
        centre,
        disc * (0.45 + 0.5 * level),
        Paint()..color = ring.withValues(alpha: 0.14),
      );
    }

    final p = progress;
    if (p == null) {
      canvas.drawCircle(
        centre,
        disc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = stroke,
      );
    } else {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(centre, r, arc..color = track ?? stroke);
      canvas.drawArc(
        Rect.fromCircle(center: centre, radius: r),
        -pi / 2,
        2 * pi * p.clamp(0.0, 1.0),
        false,
        arc..color = ring,
      );
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) =>
      old.pulse != pulse ||
      old.fill != fill ||
      old.stroke != stroke ||
      old.ring != ring ||
      old.track != track ||
      old.progress != progress ||
      old.level != level;
}
