import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../services/haptics.dart';
import '../theme/app_colors.dart';
import '../widgets/metronome_widgets.dart';

// ---------------------------------------------------------------------------
// WAV generator
// ---------------------------------------------------------------------------

Uint8List _buildSineWav({
  required int freqHz,
  int durationMs = 60,
  double amplitude = 0.5,
  double decayRate = 40.0,
  int sampleRate = 44100,
}) {
  final int numSamples = (sampleRate * durationMs / 1000).round();
  final int dataBytes = numSamples * 2; // 16-bit mono

  final ByteData header = ByteData(44);
  // RIFF chunk
  header.setUint8(0, 0x52); // R
  header.setUint8(1, 0x49); // I
  header.setUint8(2, 0x46); // F
  header.setUint8(3, 0x46); // F
  header.setUint32(4, 36 + dataBytes, Endian.little); // chunk size
  header.setUint8(8, 0x57); // W
  header.setUint8(9, 0x41); // A
  header.setUint8(10, 0x56); // V
  header.setUint8(11, 0x45); // E
  // fmt sub-chunk
  header.setUint8(12, 0x66); // f
  header.setUint8(13, 0x6D); // m
  header.setUint8(14, 0x74); // t
  header.setUint8(15, 0x20); // space
  header.setUint32(16, 16, Endian.little); // sub-chunk size
  header.setUint16(20, 1, Endian.little);  // PCM
  header.setUint16(22, 1, Endian.little);  // mono
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  header.setUint16(32, 2, Endian.little);  // block align
  header.setUint16(34, 16, Endian.little); // bits per sample
  // data sub-chunk
  header.setUint8(36, 0x64); // d
  header.setUint8(37, 0x61); // a
  header.setUint8(38, 0x74); // t
  header.setUint8(39, 0x61); // a
  header.setUint32(40, dataBytes, Endian.little);

  final Uint8List bytes = Uint8List(44 + dataBytes);
  bytes.setRange(0, 44, header.buffer.asUint8List());

  final ByteData samples = ByteData(dataBytes);
  for (int i = 0; i < numSamples; i++) {
    final double t = i / sampleRate;
    final double raw =
        sin(2 * pi * freqHz * t) * amplitude * exp(-decayRate * t) * 32767;
    final int sample = raw.round().clamp(-32768, 32767);
    samples.setInt16(i * 2, sample, Endian.little);
  }
  bytes.setRange(44, 44 + dataBytes, samples.buffer.asUint8List());
  return bytes;
}

// ---------------------------------------------------------------------------
// Tempo name helper
// ---------------------------------------------------------------------------

String _tempoName(int bpm) {
  if (bpm < 60) return 'Largo';
  if (bpm < 76) return 'Adagio';
  if (bpm < 108) return 'Andante';
  if (bpm < 120) return 'Moderato';
  if (bpm < 168) return 'Allegro';
  if (bpm < 200) return 'Presto';
  return 'Prestissimo';
}

// ---------------------------------------------------------------------------
// Screen widget
// ---------------------------------------------------------------------------

class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key, @visibleForTesting this.debugSoundReady = false});

  /// Tests only: treat the click sounds as loaded (the audio engine doesn't
  /// exist under `flutter test`), so the play button is enabled.
  final bool debugSoundReady;

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen> {
  static const int _minBpm = 40;
  static const int _maxBpm = 240;

  static const List<(int, String)> _signatures = [
    (2, '2/4'),
    (3, '3/4'),
    (4, '4/4'),
    (6, '6/8'),
  ];

  // BPM & signature
  int _bpm = 120;
  int _beatsPerBar = 4;

  // Playback state
  bool _running = false;
  bool _flash = false;
  int _currentBeat = 0;
  int _lastBeat = -1;

  // Timer
  Timer? _timer;

  // Audio
  AudioSource? _clickSrc;
  AudioSource? _accentSrc;
  late bool _soundReady = widget.debugSoundReady;

  // Tap tempo
  final List<DateTime> _taps = [];

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _initSounds();
  }

  Future<void> _initSounds() async {
    try {
      _clickSrc = await SoLoud.instance.loadMem(
        'metro_click',
        _buildSineWav(freqHz: 1000, amplitude: 0.45, decayRate: 45),
      );
      _accentSrc = await SoLoud.instance.loadMem(
        'metro_accent',
        _buildSineWav(freqHz: 1500, amplitude: 0.70, decayRate: 35),
      );
      if (mounted) setState(() => _soundReady = true);
    } catch (_) {
      // Sound init failed — UI stays disabled
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    try {
      if (_clickSrc != null) SoLoud.instance.disposeSource(_clickSrc!);
    } catch (_) {}
    try {
      if (_accentSrc != null) SoLoud.instance.disposeSource(_accentSrc!);
    } catch (_) {}
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Timer logic
  // ---------------------------------------------------------------------------

  Duration get _beatInterval =>
      Duration(microseconds: (60000000 / _bpm).round());

  void _tick() {
    final int beat = _currentBeat;
    final AudioSource? src = beat == 0 ? _accentSrc : _clickSrc;
    if (src != null) {
      try {
        SoLoud.instance.play(src);
      } catch (_) {}
    }
    if (beat == 0) Haptics.medium();
    setState(() {
      _lastBeat = beat;
      _flash = true;
      _currentBeat = (beat + 1) % _beatsPerBar;
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  void _start() {
    _currentBeat = 0;
    _tick();
    _timer = Timer.periodic(_beatInterval, (_) => _tick());
    setState(() => _running = true);
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    setState(() {
      _running = false;
      _flash = false;
      _currentBeat = 0;
      _lastBeat = -1;
    });
  }

  void _restartIfRunning() {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _currentBeat = 0;
    _tick();
    _timer = Timer.periodic(_beatInterval, (_) => _tick());
  }

  // ---------------------------------------------------------------------------
  // Tempo changes
  // ---------------------------------------------------------------------------

  /// −/+ buttons: one BPM per step. The metronome restarts on commit (tap, or
  /// release after press-and-hold) rather than on every repeated step.
  void _nudge(int delta) {
    final next = (_bpm + delta).clamp(_minBpm, _maxBpm);
    if (next == _bpm) return;
    Haptics.selection();
    setState(() => _bpm = next);
    _taps.clear();
  }

  /// Tap tempo: averages the last (up to) 4 intervals between taps. A pause of
  /// more than 2 s starts a fresh measurement.
  void _onTapTempo() {
    Haptics.light();
    final now = DateTime.now();
    if (_taps.isNotEmpty &&
        now.difference(_taps.last) > const Duration(seconds: 2)) {
      _taps.clear();
    }
    _taps.add(now);
    while (_taps.length > 5) {
      _taps.removeAt(0);
    }
    if (_taps.length < 2) return;
    final double avgMs =
        _taps.last.difference(_taps.first).inMicroseconds / 1000 / (_taps.length - 1);
    if (avgMs <= 0) return;
    final int newBpm = (60000 / avgMs).round().clamp(_minBpm, _maxBpm);
    setState(() => _bpm = newBpm);
    _restartIfRunning();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final tabular = [const FontFeature.tabularFigures()];
    final sliderTint = metronomeStroke(context, lightDarken: 0.2);

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Metronome',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 30),
                    MetronomeBeatDots(
                      beatsPerBar: _beatsPerBar,
                      currentBeat: _running ? _lastBeat : -1,
                      pulse: _flash,
                    ),
                    const SizedBox(height: 36),

                    // ── BPM ──────────────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        MetronomeStepButton(
                          icon: Icons.remove_rounded,
                          tooltip: 'Slower',
                          onStep: _bpm > _minBpm ? () => _nudge(-1) : null,
                          onCommit: _restartIfRunning,
                        ),
                        const SizedBox(width: 18),
                        SizedBox(
                          width: 170,
                          child: Semantics(
                            label: '$_bpm BPM, ${_tempoName(_bpm)}',
                            excludeSemantics: true,
                            child: Column(
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '$_bpm',
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 92,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -3,
                                      height: 1.0,
                                      fontFeatures: tabular,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'BPM · ${_tempoName(_bpm)}',
                                  style: TextStyle(
                                    color: c.textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        MetronomeStepButton(
                          icon: Icons.add_rounded,
                          tooltip: 'Faster',
                          onStep: _bpm < _maxBpm ? () => _nudge(1) : null,
                          onCommit: _restartIfRunning,
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),

                    // ── Tempo slider ─────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('$_minBpm',
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: tabular,
                                )),
                          ),
                          Text('$_maxBpm',
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                fontFeatures: tabular,
                              )),
                        ],
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: sliderTint,
                        inactiveTrackColor: light ? c.border : c.surfaceElevated,
                        thumbColor: sliderTint,
                        overlayColor: kMetronomeTint.withValues(alpha: 0.18),
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                      ),
                      child: Slider(
                        value: _bpm.toDouble(),
                        min: _minBpm.toDouble(),
                        max: _maxBpm.toDouble(),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        semanticFormatterCallback: (v) => '${v.round()} BPM',
                        onChanged: (v) {
                          setState(() {
                            _bpm = v.round();
                            _taps.clear();
                          });
                        },
                        onChangeEnd: (_) => _restartIfRunning(),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // ── Time signature ───────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                      child: Text(
                        'TIME SIGNATURE',
                        style: TextStyle(
                          color: c.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                    MetronomeSignaturePicker(
                      options: _signatures,
                      selected: _beatsPerBar,
                      onSelect: (beats) {
                        Haptics.selection();
                        setState(() {
                          _beatsPerBar = beats;
                          _currentBeat = 0;
                        });
                        _restartIfRunning();
                      },
                    ),
                    const SizedBox(height: 14),

                    // ── Tap tempo ────────────────────────────────────────
                    MetronomeTapPad(onTap: _onTapTempo),
                  ],
                ),
              ),
            ),

            // ── Play / stop ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
              child: MetronomePlayButton(
                running: _running,
                onPressed: _soundReady
                    ? () {
                        if (_running) {
                          _stop();
                        } else {
                          _start();
                        }
                      }
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
