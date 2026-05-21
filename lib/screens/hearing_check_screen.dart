import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../theme/app_colors.dart';

// ── Test plan ────────────────────────────────────────────────────────────────
// 10 frequencies covering the full speech + age-detection range.

const _kFreqs = [250, 500, 1000, 2000, 4000, 6000, 8000, 10000, 12000, 16000];
const _kFreqLabels = [
  '250 Hz', '500 Hz', '1 kHz', '2 kHz',
  '4 kHz', '6 kHz', '8 kHz', '10 kHz', '12 kHz', '16 kHz',
];

// Short labels for the audiogram grid.
const _kFreqShortLabels = [
  '250', '500', '1k', '2k', '4k', '6k', '8k', '10k', '12k', '16k',
];

// ── Auditory-age lookup ───────────────────────────────────────────────────────
// Based on the highest frequency the user can hear.
// Approximates published presbycusis norms (ISO 7029). For fun only.
int _auditoryAge(int highestFreqHeard) {
  if (highestFreqHeard >= 16000) return 18;
  if (highestFreqHeard >= 12000) return 25;
  if (highestFreqHeard >= 10000) return 32;
  if (highestFreqHeard >= 8000)  return 42;
  if (highestFreqHeard >= 6000)  return 50;
  if (highestFreqHeard >= 4000)  return 58;
  if (highestFreqHeard >= 2000)  return 65;
  return 75;
}

// ── Phase enum ───────────────────────────────────────────────────────────────
enum _Phase { intro, testing, results }

// ── Screen ───────────────────────────────────────────────────────────────────
class HearingCheckScreen extends StatefulWidget {
  const HearingCheckScreen({super.key});

  @override
  State<HearingCheckScreen> createState() => _HearingCheckScreenState();
}

class _HearingCheckScreenState extends State<HearingCheckScreen> {
  _Phase _phase = _Phase.intro;
  int _step = 0;
  final Map<int, bool> _results = {};

  AudioSource? _toneSource;
  SoundHandle? _toneHandle;
  bool _loadingTone = false;

  // ── WAV generator ──────────────────────────────────────────────────────────

  Uint8List _buildSustainedToneWav(int freqHz) {
    const sampleRate = 44100;
    const numSamples = sampleRate * 2; // 2-second clip
    const fadeLen = 2205; // ~50 ms fade in / out
    const amplitude = 0.55;

    final buffer = ByteData(44 + numSamples * 2);

    void writeStr(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    buffer.setUint32(4, 36 + numSamples * 2, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, 1, Endian.little); // mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    buffer.setUint32(40, numSamples * 2, Endian.little);

    for (var i = 0; i < numSamples; i++) {
      double env;
      if (i < fadeLen) {
        env = i / fadeLen;
      } else if (i >= numSamples - fadeLen) {
        env = (numSamples - 1 - i) / fadeLen;
      } else {
        env = 1.0;
      }
      final sample =
          (sin(2 * pi * freqHz * i / sampleRate) * amplitude * env * 32767)
              .round()
              .clamp(-32768, 32767);
      buffer.setInt16(44 + i * 2, sample, Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  // ── Tone management ────────────────────────────────────────────────────────

  Future<void> _stopTone() async {
    if (_toneHandle != null) {
      try { SoLoud.instance.stop(_toneHandle!); } catch (_) {}
      _toneHandle = null;
    }
    if (_toneSource != null) {
      try { SoLoud.instance.disposeSource(_toneSource!); } catch (_) {}
      _toneSource = null;
    }
  }

  Future<void> _playTone(int freqHz) async {
    await _stopTone();
    if (!mounted) return;
    setState(() => _loadingTone = true);
    try {
      _toneSource =
          await SoLoud.instance.loadMem('tone_$freqHz', _buildSustainedToneWav(freqHz));
      _toneHandle = await SoLoud.instance.play(
        _toneSource!,
        looping: true,
        volume: 0.8,
      );
    } catch (_) {}
    if (mounted) setState(() => _loadingTone = false);
  }

  // ── Navigation logic ───────────────────────────────────────────────────────

  void _startTest() {
    setState(() { _step = 0; _phase = _Phase.testing; });
    _playTone(_kFreqs[0]);
  }

  Future<void> _answer(bool canHear) async {
    _results[_kFreqs[_step]] = canHear;
    await _stopTone();
    if (!mounted) return;
    if (_step < _kFreqs.length - 1) {
      setState(() => _step++);
      await _playTone(_kFreqs[_step]);
    } else {
      setState(() => _phase = _Phase.results);
    }
  }

  void _restart() {
    setState(() { _results.clear(); _step = 0; _phase = _Phase.intro; });
  }

  @override
  void dispose() {
    _stopTone();
    super.dispose();
  }

  // ── Derived results ────────────────────────────────────────────────────────

  int get _highestFreqHeard {
    int highest = 0;
    for (final freq in _kFreqs) {
      if (_results[freq] == true && freq > highest) highest = freq;
    }
    return highest;
  }

  String get _summaryText {
    final heard = _results.values.where((v) => v).length;
    final total = _kFreqs.length;
    if (heard == total) {
      return 'Excellent — you heard all $total tested frequencies. '
          'Your hearing covers the full tested range.';
    }
    if (heard >= 8) {
      return 'Good. You missed ${total - heard} high-frequency tone(s). '
          'Some high-frequency loss is normal as we age.';
    }
    if (heard >= 6) {
      return 'You heard $heard / $total frequencies. '
          'Moderate high-frequency loss detected — common with age or noise exposure.';
    }
    return 'You heard $heard / $total frequencies. '
        'This suggests notable hearing loss. Consider a proper audiologist evaluation.';
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  Widget _buildIntro(AppColors c, Color accent) {
    return Center(
      child: SingleChildScrollView(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hearing_rounded, size: 72, color: accent),
              const SizedBox(height: 20),
              Text(
                'Hearing Check',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Plays tones at 10 frequencies — 250 Hz up to 16 kHz. '
                'For each, tap whether you can hear it. '
                'Takes about a minute. At the end you get your estimated auditory age.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 20),
              _DisclaimerBox(
                text: 'Use headphones for best results. '
                    'This is NOT a medical test — for curiosity only.',
                colors: c,
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _startTest,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text(
                    'Start Check',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTesting(AppColors c, Color accent) {
    final total = _kFreqs.length;
    final progress = _step / total;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Progress row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${_step + 1} / $total',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              'Frequency test',
              style: TextStyle(color: c.textMuted, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 5,
            backgroundColor: accent.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation(accent),
          ),
        ),
        const SizedBox(height: 40),

        // Frequency card
        Container(
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
          decoration: BoxDecoration(
            color: c.surfaceCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.border),
          ),
          child: Column(
            children: [
              Text(
                _kFreqLabels[_step],
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 48,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_loadingTone)
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(c.textMuted),
                      ),
                    )
                  else
                    Icon(Icons.volume_up_rounded, size: 16, color: c.textMuted),
                  const SizedBox(width: 8),
                  Text(
                    'Playing tone…',
                    style: TextStyle(color: c.textMuted, fontSize: 14),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),

        // Answer buttons
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _loadingTone ? null : () => _answer(true),
                icon: const Icon(Icons.check_rounded, size: 20),
                label: const Text(
                  'I can hear it',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: accent.withValues(alpha: 0.30),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _loadingTone ? null : () => _answer(false),
                icon: const Icon(Icons.close_rounded, size: 20),
                label: const Text(
                  "Can't hear it",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: BorderSide(
                    color: _loadingTone
                        ? Colors.redAccent.withValues(alpha: 0.25)
                        : Colors.redAccent.withValues(alpha: 0.60),
                  ),
                  backgroundColor: Colors.redAccent.withValues(alpha: 0.06),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            'Listen carefully — some high frequencies are very subtle.',
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildResults(AppColors c, Color accent) {
    final highest = _highestFreqHeard;
    final estAge = highest > 0 ? _auditoryAge(highest) : null;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Results',
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Retest to try again.',
            style: TextStyle(color: c.textMuted, fontSize: 14),
          ),
          const SizedBox(height: 24),

          // Auditory age card
          if (estAge != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: accent.withValues(alpha: 0.30)),
              ),
              child: Column(
                children: [
                  Text(
                    'Your Auditory Age',
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '~$estAge',
                    style: TextStyle(
                      color: accent,
                      fontSize: 72,
                      fontWeight: FontWeight.w200,
                      height: 1.0,
                      letterSpacing: -2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Highest frequency heard: ${highest >= 1000 ? '${highest ~/ 1000} kHz' : '$highest Hz'}',
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Mini audiogram
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 14),
                  child: Text(
                    'FREQUENCY RANGE',
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(_kFreqs.length, (i) {
                    final freq = _kFreqs[i];
                    final heard = _results[freq] ?? false;
                    return _AudiogramColumn(
                      label: _kFreqShortLabels[i],
                      heard: heard,
                      accent: accent,
                      colors: c,
                    );
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Summary card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.analytics_rounded, size: 18, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      'Summary',
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  _summaryText,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 14,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          _DisclaimerBox(
            text: 'For curiosity only — not a medical assessment. '
                'Auditory age is an approximation based on published presbycusis norms.',
            colors: c,
          ),
          const SizedBox(height: 24),

          OutlinedButton.icon(
            onPressed: _restart,
            icon: const Icon(Icons.refresh_rounded, size: 20),
            label: const Text(
              'Retest',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: accent,
              side: BorderSide(color: accent.withValues(alpha: 0.60)),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.scaffoldBg,
        foregroundColor: c.textPrimary,
        elevation: 0,
        title: Text(
          'Hearing Check',
          style: TextStyle(
            color: c.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: switch (_phase) {
            _Phase.intro   => _buildIntro(c, accent),
            _Phase.testing => _buildTesting(c, accent),
            _Phase.results => _buildResults(c, accent),
          },
        ),
      ),
    );
  }
}

// ── Disclaimer box ────────────────────────────────────────────────────────────
// Uses Text widgets so the app's font family is always applied correctly.

class _DisclaimerBox extends StatelessWidget {
  final String text;
  final AppColors colors;

  const _DisclaimerBox({required this.text, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('⚠️', style: TextStyle(fontSize: 15)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Audiogram column ──────────────────────────────────────────────────────────

class _AudiogramColumn extends StatelessWidget {
  final String label;
  final bool heard;
  final Color accent;
  final AppColors colors;

  const _AudiogramColumn({
    required this.label,
    required this.heard,
    required this.accent,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final circleColor =
        heard ? accent : Colors.redAccent.withValues(alpha: 0.80);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: circleColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: circleColor.withValues(alpha: 0.30),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Icon(
            heard ? Icons.check_rounded : Icons.close_rounded,
            color: Colors.white,
            size: 16,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
