import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../theme/app_colors.dart';

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
  if (bpm < 67) return 'Larghetto';
  if (bpm < 76) return 'Adagio';
  if (bpm < 108) return 'Andante';
  if (bpm < 120) return 'Moderato';
  if (bpm < 156) return 'Allegro';
  if (bpm < 168) return 'Vivace';
  if (bpm < 200) return 'Presto';
  return 'Prestissimo';
}

// ---------------------------------------------------------------------------
// Screen widget
// ---------------------------------------------------------------------------

class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({super.key});

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen> {
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
  bool _soundReady = false;

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
    if (beat == 0) HapticFeedback.mediumImpact();
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
  // Tap tempo
  // ---------------------------------------------------------------------------

  void _onTapTempo() {
    final now = DateTime.now();
    _taps.add(now);
    // Keep last 8
    if (_taps.length > 8) _taps.removeAt(0);
    if (_taps.length >= 2) {
      int totalMs = 0;
      for (int i = 1; i < _taps.length; i++) {
        totalMs += _taps[i].difference(_taps[i - 1]).inMilliseconds;
      }
      final double avgMs = totalMs / (_taps.length - 1);
      final int newBpm = (60000 / avgMs).round().clamp(40, 240);
      setState(() => _bpm = newBpm);
      _restartIfRunning();
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.scaffoldBg,
        elevation: 0,
        title: Text(
          'Metronome',
          style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w600),
        ),
        iconTheme: IconThemeData(color: c.textPrimary),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 16),
                      _BeatDotsRow(
                        beatsPerBar: _beatsPerBar,
                        running: _running,
                        flash: _flash,
                        lastBeat: _lastBeat,
                        accent: accent,
                        borderSubtle: c.borderSubtle,
                      ),
                      const SizedBox(height: 28),
                      _BpmCard(
                        bpm: _bpm,
                        accent: accent,
                        surfaceCard: c.surfaceCard,
                        textPrimary: c.textPrimary,
                        textSecondary: c.textSecondary,
                        onDecrement: () {
                          if (_bpm > 40) {
                            setState(() => _bpm--);
                            _taps.clear();
                            _restartIfRunning();
                          }
                        },
                        onIncrement: () {
                          if (_bpm < 240) {
                            setState(() => _bpm++);
                            _taps.clear();
                            _restartIfRunning();
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: accent,
                          inactiveTrackColor: c.border,
                          thumbColor: accent,
                          overlayColor: accent.withValues(alpha: 0.15),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          value: _bpm.toDouble(),
                          min: 40,
                          max: 240,
                          onChanged: (v) {
                            setState(() {
                              _bpm = v.round();
                              _taps.clear();
                            });
                          },
                          onChangeEnd: (_) => _restartIfRunning(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      _TimeSignatureRow(
                        selected: _beatsPerBar,
                        accent: accent,
                        surfaceCard: c.surfaceCard,
                        textPrimary: c.textPrimary,
                        textSecondary: c.textSecondary,
                        border: c.border,
                        onSelect: (beats) {
                          setState(() {
                            _beatsPerBar = beats;
                            _currentBeat = 0;
                          });
                          _restartIfRunning();
                        },
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
            _BottomControls(
              running: _running,
              soundReady: _soundReady,
              accent: accent,
              surfaceCard: c.surfaceCard,
              textPrimary: c.textPrimary,
              border: c.border,
              onTapTempo: _onTapTempo,
              onStartStop: () {
                if (_running) {
                  _stop();
                } else {
                  _start();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Beat dots row
// ---------------------------------------------------------------------------

class _BeatDotsRow extends StatelessWidget {
  const _BeatDotsRow({
    required this.beatsPerBar,
    required this.running,
    required this.flash,
    required this.lastBeat,
    required this.accent,
    required this.borderSubtle,
  });

  final int beatsPerBar;
  final bool running;
  final bool flash;
  final int lastBeat;
  final Color accent;
  final Color borderSubtle;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(beatsPerBar, (i) {
        final bool active = running && flash && lastBeat == i;
        final Color color = active
            ? (i == 0 ? accent : accent.withValues(alpha: 0.8))
            : borderSubtle;
        // Fixed outer size prevents the Row from reflowing on each beat.
        // Only the inner circle scales via AnimatedContainer.
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SizedBox(
            width: 22,
            height: 22,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                width: active ? 22.0 : 13.0,
                height: active ? 22.0 : 13.0,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// BPM card
// ---------------------------------------------------------------------------

class _BpmCard extends StatelessWidget {
  const _BpmCard({
    required this.bpm,
    required this.accent,
    required this.surfaceCard,
    required this.textPrimary,
    required this.textSecondary,
    required this.onDecrement,
    required this.onIncrement,
  });

  final int bpm;
  final Color accent;
  final Color surfaceCard;
  final Color textPrimary;
  final Color textSecondary;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: surfaceCard,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                onPressed: onDecrement,
                icon: const Icon(Icons.remove_rounded),
                iconSize: 28,
                color: textPrimary,
                splashRadius: 24,
              ),
              const SizedBox(width: 16),
              Column(
                children: [
                  Text(
                    '$bpm',
                    style: TextStyle(
                      fontSize: 80,
                      fontWeight: FontWeight.w200,
                      color: textPrimary,
                      height: 1.0,
                    ),
                  ),
                  Text(
                    'BPM',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: textSecondary,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              IconButton(
                onPressed: onIncrement,
                icon: const Icon(Icons.add_rounded),
                iconSize: 28,
                color: textPrimary,
                splashRadius: 24,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _tempoName(bpm),
            style: TextStyle(
              fontSize: 15,
              fontStyle: FontStyle.italic,
              color: textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Time-signature pills
// ---------------------------------------------------------------------------

class _TimeSignatureRow extends StatelessWidget {
  const _TimeSignatureRow({
    required this.selected,
    required this.accent,
    required this.surfaceCard,
    required this.textPrimary,
    required this.textSecondary,
    required this.border,
    required this.onSelect,
  });

  final int selected;
  final Color accent;
  final Color surfaceCard;
  final Color textPrimary;
  final Color textSecondary;
  final Color border;
  final ValueChanged<int> onSelect;

  static const List<(int, String)> _sigs = [
    (2, '2/4'),
    (3, '3/4'),
    (4, '4/4'),
    (6, '6/8'),
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: _sigs.map((sig) {
        final (beats, label) = sig;
        final bool isSelected = selected == beats;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: GestureDetector(
            onTap: () => onSelect(beats),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? accent.withValues(alpha: 0.18)
                    : surfaceCard,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isSelected ? accent : border,
                  width: isSelected ? 1.5 : 1.0,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected ? accent : textSecondary,
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom controls
// ---------------------------------------------------------------------------

class _BottomControls extends StatelessWidget {
  const _BottomControls({
    required this.running,
    required this.soundReady,
    required this.accent,
    required this.surfaceCard,
    required this.textPrimary,
    required this.border,
    required this.onTapTempo,
    required this.onStartStop,
  });

  final bool running;
  final bool soundReady;
  final Color accent;
  final Color surfaceCard;
  final Color textPrimary;
  final Color border;
  final VoidCallback onTapTempo;
  final VoidCallback onStartStop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tap tempo
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton(
              onPressed: onTapTempo,
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: border),
                foregroundColor: textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                'TAP TEMPO',
                style: TextStyle(
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Start / Stop
          SizedBox(
            width: double.infinity,
            height: 56,
            child: running
                ? OutlinedButton(
                    onPressed: soundReady ? onStartStop : null,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: surfaceCard,
                      side: BorderSide(color: border),
                      foregroundColor: textPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      disabledForegroundColor:
                          textPrimary.withValues(alpha: 0.38),
                    ),
                    child: const Text(
                      'STOP',
                      style: TextStyle(
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  )
                : ElevatedButton(
                    onPressed: soundReady ? onStartStop : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      disabledBackgroundColor:
                          accent.withValues(alpha: 0.38),
                      elevation: 0,
                    ),
                    child: const Text(
                      'START',
                      style: TextStyle(
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
