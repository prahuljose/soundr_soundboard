import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../services/clip_repository.dart';
import '../theme/app_colors.dart';
import '../widgets/share_card.dart';

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

String _freqLabel(int hz) => hz >= 1000 ? '${hz ~/ 1000} kHz' : '$hz Hz';

// ── Phase / ear enums ────────────────────────────────────────────────────────
enum _Phase { intro, testing, results }

/// Which ear a tone plays in. [both] is the classic single-pass test.
enum _Ear {
  both(label: 'Both ears'),
  left(label: 'Left ear'),
  right(label: 'Right ear');

  const _Ear({required this.label});
  final String label;
}

// ── Screen ───────────────────────────────────────────────────────────────────
class HearingCheckScreen extends StatefulWidget {
  const HearingCheckScreen({super.key});

  @override
  State<HearingCheckScreen> createState() => _HearingCheckScreenState();
}

class _HearingCheckScreenState extends State<HearingCheckScreen> {
  _Phase _phase = _Phase.intro;
  int _step = 0;
  final Map<(_Ear, int), bool> _results = {};

  /// Opt-in: test the left and right ear one after the other.
  bool _separateEars = false;
  static const _kSeparateEars = 'hearing_separate_ears';

  List<_Ear> get _ears =>
      _separateEars ? const [_Ear.left, _Ear.right] : const [_Ear.both];

  /// Every (ear, frequency) pair in play order: all of the left ear first,
  /// then the right, so the listener only switches focus once.
  List<(_Ear, int)> get _plan => [
        for (final ear in _ears)
          for (final f in _kFreqs) (ear, f),
      ];

  @override
  void initState() {
    super.initState();
    _loadSeparateEars();
  }

  Future<void> _loadSeparateEars() async {
    try {
      final v = await ClipRepository.getBool(_kSeparateEars);
      if (mounted) setState(() => _separateEars = v);
    } catch (_) {/* keep the default (off) */}
  }

  void _setSeparateEars(bool v) {
    setState(() => _separateEars = v);
    ClipRepository.setBool(_kSeparateEars, v).catchError((_) {});
  }

  AudioSource? _toneSource;
  SoundHandle? _toneHandle;
  bool _loadingTone = false;

  // ── WAV generator ──────────────────────────────────────────────────────────

  /// Stereo so a tone can be sent to one ear only: the other channel is
  /// written as silence (more reliable than panning a mono voice).
  Uint8List _buildSustainedToneWav(int freqHz, _Ear ear) {
    const sampleRate = 44100;
    const numSamples = sampleRate * 2; // 2-second clip
    const fadeLen = 2205; // ~50 ms fade in / out
    const amplitude = 0.55;
    const channels = 2;
    const blockAlign = channels * 2;
    final leftOn = ear != _Ear.right;
    final rightOn = ear != _Ear.left;

    final buffer = ByteData(44 + numSamples * blockAlign);

    void writeStr(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    buffer.setUint32(4, 36 + numSamples * blockAlign, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, channels, Endian.little); // stereo
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * blockAlign, Endian.little); // byte rate
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    buffer.setUint32(40, numSamples * blockAlign, Endian.little);

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
      final offset = 44 + i * blockAlign;
      buffer.setInt16(offset, leftOn ? sample : 0, Endian.little);
      buffer.setInt16(offset + 2, rightOn ? sample : 0, Endian.little);
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

  Future<void> _playTone(int freqHz, _Ear ear) async {
    await _stopTone();
    if (!mounted) return;
    setState(() => _loadingTone = true);
    try {
      _toneSource = await SoLoud.instance.loadMem(
          'tone_${ear.name}_$freqHz', _buildSustainedToneWav(freqHz, ear));
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
    _results.clear();
    setState(() { _step = 0; _phase = _Phase.testing; });
    final (ear, freq) = _plan.first;
    _playTone(freq, ear);
  }

  Future<void> _answer(bool canHear) async {
    final plan = _plan;
    _results[plan[_step]] = canHear;
    await _stopTone();
    if (!mounted) return;
    if (_step < plan.length - 1) {
      setState(() => _step++);
      final (ear, freq) = plan[_step];
      await _playTone(freq, ear);
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

  /// Highest frequency heard in [ear], or in any tested ear when null.
  int _highestFreqHeard([_Ear? ear]) {
    int highest = 0;
    for (final MapEntry(key: (e, freq), :value) in _results.entries) {
      if ((ear == null || e == ear) && value && freq > highest) highest = freq;
    }
    return highest;
  }

  int? _ageFor([_Ear? ear]) {
    final highest = _highestFreqHeard(ear);
    return highest > 0 ? _auditoryAge(highest) : null;
  }

  /// Extra line when the two ears differ by two or more test steps.
  String? get _asymmetryNote {
    if (!_separateEars) return null;
    final l = _kFreqs.indexOf(_highestFreqHeard(_Ear.left));
    final r = _kFreqs.indexOf(_highestFreqHeard(_Ear.right));
    if ((l - r).abs() < 2) return null;
    final weaker = l < r ? 'left' : 'right';
    return 'Your $weaker ear picked up noticeably fewer high tones. '
        'Earbud fit and background noise can cause this — if it keeps '
        'happening, it may be worth checking with a hearing professional.';
  }

  String get _summaryText {
    // Summarise the better ear (or the single combined pass).
    final ear = _ears.reduce((a, b) =>
        _heardCount(a) >= _heardCount(b) ? a : b);
    final heard = _heardCount(ear);
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

  int _heardCount(_Ear ear) =>
      _kFreqs.where((f) => _results[(ear, f)] == true).length;

  void _shareResult() {
    final age = _ageFor();
    if (age == null) return;
    final highest = _highestFreqHeard();
    final left = _ageFor(_Ear.left);
    final right = _ageFor(_Ear.right);
    showShareCardSheet(
      context,
      fileName: 'soundr-hearing-check',
      shareText: 'My hearing age is ~$age according to Soundr’s Hearing '
          'Check 👂 What’s yours?',
      card: ShareCard(
        eyebrow: 'Hearing Check',
        emoji: '👂',
        value: '~$age',
        unit: 'my hearing age',
        stats: [
          if (_separateEars) ...[
            'Left ${left == null ? '—' : '~$left'}',
            'Right ${right == null ? '—' : '~$right'}',
          ],
          'Up to ${_freqLabel(highest)}',
        ],
        tagline: 'What’s your\nhearing age?',
      ),
    );
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
                'Takes about ${_separateEars ? 'two minutes' : 'a minute'}. '
                'At the end you get your estimated auditory age.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 20),
              _EarToggle(
                value: _separateEars,
                onChanged: _setSeparateEars,
                accent: accent,
                colors: c,
              ),
              const SizedBox(height: 16),
              _DisclaimerBox(
                text: _separateEars
                    ? 'Headphones required — each tone plays in one ear only. '
                        'This is NOT a medical test — for curiosity only.'
                    : 'Use headphones for best results. '
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
    final plan = _plan;
    final total = plan.length;
    final progress = _step / total;
    final (ear, freq) = plan[_step];

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
              _separateEars ? ear.label : 'Frequency test',
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
              if (_separateEars) ...[
                _EarBadge(ear: ear, accent: accent),
                const SizedBox(height: 18),
              ],
              Text(
                _kFreqLabels[_kFreqs.indexOf(freq)],
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
    final highest = _highestFreqHeard();
    final estAge = _ageFor();
    final note = _asymmetryNote;

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
                    'Highest frequency heard: ${_freqLabel(highest)}',
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                  ),
                  if (_separateEars) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        for (final ear in _ears)
                          Expanded(
                            child: _EarAgeTile(
                              ear: ear,
                              age: _ageFor(ear),
                              highest: _highestFreqHeard(ear),
                              colors: c,
                            ),
                          ),
                      ],
                    ),
                  ],
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
                for (final ear in _ears) ...[
                  if (_separateEars)
                    Padding(
                      padding: EdgeInsets.only(
                          left: 4, bottom: 8, top: ear == _Ear.right ? 14 : 0),
                      child: Text(
                        ear.label,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: List.generate(_kFreqs.length, (i) {
                      final heard = _results[(ear, _kFreqs[i])] ?? false;
                      return _AudiogramColumn(
                        label: _kFreqShortLabels[i],
                        heard: heard,
                        accent: accent,
                        colors: c,
                      );
                    }),
                  ),
                ],
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
                if (note != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    note,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 14,
                      height: 1.55,
                    ),
                  ),
                ],
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

          if (estAge != null) ...[
            FilledButton.icon(
              onPressed: _shareResult,
              icon: const Icon(Icons.ios_share_rounded, size: 20),
              label: const Text(
                'Share result',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
            ),
            const SizedBox(height: 12),
          ],

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

// ── Separate-ears toggle (intro) ──────────────────────────────────────────────

class _EarToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color accent;
  final AppColors colors;

  const _EarToggle({
    required this.value,
    required this.onChanged,
    required this.accent,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onChanged(!value),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: BoxDecoration(
            color: value
                ? accent.withValues(alpha: 0.10)
                : colors.surfaceElevated.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: value ? accent.withValues(alpha: 0.45) : colors.border),
          ),
          child: Row(
            children: [
              Icon(Icons.headphones_rounded,
                  size: 20, color: value ? accent : colors.iconSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Test each ear separately',
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Left ear first, then right',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: accent,
                activeTrackColor: accent.withValues(alpha: 0.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Which-ear badge (testing) ─────────────────────────────────────────────────

class _EarBadge extends StatelessWidget {
  final _Ear ear;
  final Color accent;

  const _EarBadge({required this.ear, required this.accent});

  @override
  Widget build(BuildContext context) {
    final isLeft = ear == _Ear.left;
    return Semantics(
      label: 'Listening with your ${ear.label.toLowerCase()}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accent.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLeft) ...[
                Icon(Icons.arrow_back_rounded, size: 16, color: accent),
                const SizedBox(width: 6),
              ],
              Text(
                ear.label.toUpperCase(),
                style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                ),
              ),
              if (!isLeft) ...[
                const SizedBox(width: 6),
                Icon(Icons.arrow_forward_rounded, size: 16, color: accent),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Per-ear age tile (results) ────────────────────────────────────────────────

class _EarAgeTile extends StatelessWidget {
  final _Ear ear;
  final int? age;
  final int highest;
  final AppColors colors;

  const _EarAgeTile({
    required this.ear,
    required this.age,
    required this.highest,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          ear.label.toUpperCase(),
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          age == null ? '—' : '~$age',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 28,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          highest > 0 ? 'up to ${_freqLabel(highest)}' : 'no tones heard',
          style: TextStyle(color: colors.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}
