import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../services/clip_repository.dart';
import '../services/haptics.dart';
import '../theme/app_colors.dart';
import '../widgets/hearing_headphones.dart';
import '../widgets/share_card.dart';

/// The Hearing Check's tool tint. Text drawn in it on a light background is
/// darkened; anything sitting on a tint fill uses [_kInk].
const _kTint = Color(0xFFC9B8FF);
final _kInk = Color.lerp(_kTint, Colors.black, 0.78)!;

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

class _HearingCheckScreenState extends State<HearingCheckScreen>
    with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.intro;

  /// Drives the "Playing a tone…" dot and the headphone sound waves.
  /// Created in initState, not lazily: a lazy controller first touched in
  /// dispose() would look up TickerMode too late.
  late final AnimationController _pulse;
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
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
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

  /// Bumped whenever the tone is stopped, so a tone still loading when the
  /// test moves on (or is closed) is discarded instead of starting late.
  int _toneGen = 0;

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
    _toneGen++;
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
    final gen = _toneGen;
    setState(() => _loadingTone = true);
    try {
      final source = await SoLoud.instance.loadMem(
          'tone_${ear.name}_$freqHz', _buildSustainedToneWav(freqHz, ear));
      if (gen != _toneGen) {
        // Stopped (answered, closed or left) while loading.
        try { SoLoud.instance.disposeSource(source); } catch (_) {}
        return;
      }
      _toneSource = source;
      final handle = await SoLoud.instance.play(
        source,
        looping: true,
        volume: 0.8,
      );
      if (gen != _toneGen) {
        try { SoLoud.instance.stop(handle); } catch (_) {}
        try { SoLoud.instance.disposeSource(source); } catch (_) {}
        return;
      }
      _toneHandle = handle;
    } catch (_) {
    } finally {
      if (mounted && gen == _toneGen) setState(() => _loadingTone = false);
    }
  }

  // ── Navigation logic ───────────────────────────────────────────────────────

  void _startTest() {
    Haptics.light();
    _results.clear();
    setState(() { _step = 0; _phase = _Phase.testing; });
    if (!_reduceMotion) _pulse.repeat(reverse: true);
    final (ear, freq) = _plan.first;
    _playTone(freq, ear);
  }

  Future<void> _answer(bool canHear) async {
    Haptics.selection();
    final plan = _plan;
    _results[plan[_step]] = canHear;
    await _stopTone();
    if (!mounted) return;
    if (_step < plan.length - 1) {
      setState(() => _step++);
      final (ear, freq) = plan[_step];
      await _playTone(freq, ear);
    } else {
      _pulse.stop();
      setState(() => _phase = _Phase.results);
    }
  }

  /// App-bar close: abandon the run, silence the tone, back to the intro.
  void _stopTest() {
    Haptics.light();
    _stopTone();
    _pulse.stop();
    setState(() {
      _results.clear();
      _step = 0;
      _loadingTone = false;
      _phase = _Phase.intro;
    });
  }

  void _restart() {
    setState(() { _results.clear(); _step = 0; _phase = _Phase.intro; });
  }

  bool get _reduceMotion =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  @override
  void dispose() {
    _stopTone();
    _pulse.dispose();
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

  static const _tabular = [FontFeature.tabularFigures()];

  /// [_kTint] as a foreground (text, icons, arcs): darkened on light themes.
  Color get _tintFg => Theme.of(context).brightness == Brightness.light
      ? Color.lerp(_kTint, Colors.black, 0.45)!
      : _kTint;

  HearingHeadphones _headphones(AppColors c,
          {required bool left, required bool right, Animation<double>? pulse, double width = 220}) =>
      HearingHeadphones(
        left: left,
        right: right,
        tint: _kTint,
        waveColor: _tintFg,
        line: c.iconSecondary.withValues(alpha: c.iconSecondary.a * 0.5),
        cup: c.surfaceElevated,
        pulse: pulse,
        width: width,
      );

  /// Pins [children]'s trailing Spacer-separated actions to the bottom on
  /// tall screens and scrolls everything on short ones.
  Widget _fill(List<Widget> children) => CustomScrollView(
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ],
      );

  Widget _buildIntro(AppColors c) {
    return _fill([
      _Card(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
        child: Column(
          children: [
            ExcludeSemantics(
              child: _headphones(c, left: true, right: true, width: 168),
            ),
            const SizedBox(height: 18),
            Text(
              'How well do you hear?',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Plays tones at 10 frequencies — 250\u00A0Hz up to 16\u00A0kHz. '
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
          ],
        ),
      ),
      const _Label('OPTIONS'),
      _EarToggle(
        value: _separateEars,
        onChanged: _setSeparateEars,
        tintFg: _tintFg,
        colors: c,
      ),
      const SizedBox(height: 12),
      _DisclaimerBox(
        icon: Icons.headphones_rounded,
        text: _separateEars
            ? 'Headphones required — each tone plays in one ear only. '
                'This is NOT a medical test — for curiosity only.'
            : 'Use headphones for best results. '
                'This is NOT a medical test — for curiosity only.',
        colors: c,
      ),
      const SizedBox(height: 24),
      const Spacer(),
      _BigButton(
        label: 'Start Check',
        height: 56,
        radius: 18,
        filled: true,
        onPressed: _startTest,
        colors: c,
      ),
    ]);
  }

  Widget _buildTesting(AppColors c) {
    final plan = _plan;
    final (ear, freq) = plan[_step];
    final i = _kFreqs.indexOf(freq);
    final number = freq >= 1000 ? '${freq ~/ 1000}' : '$freq';
    final unit = freq >= 1000 ? 'kHz' : 'Hz';
    final pulse = _reduceMotion ? null : _pulse;

    return _fill([
      _SegmentedProgress(
        total: plan.length,
        current: _step,
        done: _kTint,
        now: c.textPrimary,
        upcoming: c.border,
      ),
      const SizedBox(height: 40),
      Semantics(
        label: 'Testing your ${ear.label.toLowerCase()}',
        child: ExcludeSemantics(
          child: Column(
            children: [
              _headphones(
                c,
                left: ear != _Ear.right,
                right: ear != _Ear.left,
                pulse: _loadingTone ? null : pulse,
              ),
              const SizedBox(height: 14),
              Text(
                ear.label.toUpperCase(),
                style: TextStyle(
                  color: _tintFg,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 30),
      Semantics(
        liveRegion: true,
        label: _kFreqLabels[i],
        child: ExcludeSemantics(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: number),
              TextSpan(
                text: ' $unit',
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0,
                ),
              ),
            ]),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 72,
              fontWeight: FontWeight.w600,
              letterSpacing: -3,
              height: 1.0,
              fontFeatures: _tabular,
            ),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Center(
        child: _ToneIndicator(
          loading: _loadingTone,
          pulse: pulse,
          tint: _kTint,
          colors: c,
        ),
      ),
      const SizedBox(height: 28),
      const Spacer(),
      _BigButton(
        label: 'I can hear it',
        filled: true,
        onPressed: _loadingTone ? null : () => _answer(true),
        colors: c,
      ),
      const SizedBox(height: 10),
      _BigButton(
        label: 'I can’t hear it',
        filled: false,
        onPressed: _loadingTone ? null : () => _answer(false),
        colors: c,
      ),
      const SizedBox(height: 16),
      Text(
        'For curiosity only — not a medical test',
        textAlign: TextAlign.center,
        style: TextStyle(color: c.textSecondary, fontSize: 12),
      ),
    ]);
  }

  Widget _buildResults(AppColors c) {
    final highest = _highestFreqHeard();
    final estAge = _ageFor();
    final note = _asymmetryNote;

    return _fill([
      // Auditory age card
      if (estAge != null)
        _Card(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          child: Column(
            children: [
              Text(
                'YOUR AUDITORY AGE',
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '~$estAge',
                style: TextStyle(
                  color: _tintFg,
                  fontSize: 72,
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  letterSpacing: -3,
                  fontFeatures: _tabular,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Highest frequency heard: ${_freqLabel(highest)}',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 14),
              ),
              if (_separateEars) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    for (final ear in _ears) ...[
                      if (ear == _Ear.right) const SizedBox(width: 10),
                      Expanded(
                        child: _EarAgeTile(
                          ear: ear,
                          age: _ageFor(ear),
                          highest: _highestFreqHeard(ear),
                          colors: c,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        )
      else
        _Card(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Icon(Icons.hearing_disabled_rounded, size: 40, color: c.iconSecondary),
              const SizedBox(height: 10),
              Text(
                'No tones heard',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),

      // Mini audiogram(s)
      const _Label('FREQUENCY RANGE'),
      _Card(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final ear in _ears) ...[
              if (_separateEars)
                Padding(
                  padding: EdgeInsets.only(
                      left: 4, bottom: 10, top: ear == _Ear.right ? 18 : 0),
                  child: Row(
                    children: [
                      Text(
                        ear.label,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          '${_heardCount(ear)} / ${_kFreqs.length} heard',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 12,
                            fontFeatures: _tabular,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(_kFreqs.length, (i) {
                  final heard = _results[(ear, _kFreqs[i])] ?? false;
                  return _AudiogramColumn(
                    label: _kFreqShortLabels[i],
                    semanticsLabel:
                        '${_kFreqLabels[i]}: ${heard ? 'heard' : 'not heard'}',
                    heard: heard,
                    colors: c,
                  );
                }),
              ),
            ],
          ],
        ),
      ),

      // Summary
      const _Label('SUMMARY'),
      _Card(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _summaryText,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 15,
                height: 1.5,
              ),
            ),
            if (note != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: _kTint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _kTint.withValues(alpha: 0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(Icons.compare_arrows_rounded,
                          size: 18, color: _tintFg),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        note,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 12),
      _DisclaimerBox(
        icon: Icons.info_outline_rounded,
        text: 'For curiosity only — not a medical assessment. '
            'Auditory age is an approximation based on published presbycusis norms.',
        colors: c,
      ),
      const SizedBox(height: 24),
      const Spacer(),
      if (estAge != null) ...[
        _BigButton(
          label: 'Share result',
          icon: Icons.ios_share_rounded,
          height: 56,
          radius: 18,
          filled: true,
          onPressed: _shareResult,
          colors: c,
        ),
        const SizedBox(height: 10),
      ],
      _BigButton(
        label: 'Retest',
        icon: Icons.refresh_rounded,
        height: 56,
        radius: 18,
        filled: false,
        onPressed: _restart,
        colors: c,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final testing = _phase == _Phase.testing;
    final total = _plan.length;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.scaffoldBg,
        foregroundColor: c.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          _phase == _Phase.results ? 'Your results' : 'Hearing Check',
          style: TextStyle(
            color: c.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        actions: testing
            ? [
                Center(
                  child: Semantics(
                    label: 'Step ${_step + 1} of $total',
                    child: ExcludeSemantics(
                      child: Text(
                        '${_step + 1} / $total',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontFeatures: _tabular,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: IconButton(
                    tooltip: 'Stop test',
                    onPressed: _stopTest,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    style: IconButton.styleFrom(
                      fixedSize: const Size(44, 44),
                      minimumSize: const Size(44, 44),
                      backgroundColor: c.surfaceCard,
                      foregroundColor: c.textPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: c.border),
                      ),
                    ),
                  ),
                ),
              ]
            : null,
      ),
      body: SafeArea(
        top: false,
        child: switch (_phase) {
          _Phase.intro   => _buildIntro(c),
          _Phase.testing => _buildTesting(c),
          _Phase.results => _buildResults(c),
        },
      ),
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 22, 2, 8),
      child: Text(text,
          style: TextStyle(
            color: c.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
          )),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Card({required this.child, required this.padding});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }
}

/// Full-width answer / action button: tint fill with dark ink, or outlined.
class _BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool filled;
  final VoidCallback? onPressed;
  final double height;
  final double radius;
  final AppColors colors;

  const _BigButton({
    required this.label,
    required this.filled,
    required this.onPressed,
    required this.colors,
    this.icon,
    this.height = 64,
    this.radius = 20,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
    final text = Text(
      label,
      style: TextStyle(
        fontSize: height >= 64 ? 17 : 16,
        fontWeight: filled ? FontWeight.w800 : FontWeight.w700,
      ),
    );
    final child = icon == null
        ? text
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [Icon(icon, size: 20), const SizedBox(width: 8), text],
          );
    return SizedBox(
      height: height,
      child: filled
          ? FilledButton(
              onPressed: onPressed,
              style: FilledButton.styleFrom(
                backgroundColor: _kTint,
                foregroundColor: _kInk,
                disabledBackgroundColor: _kTint.withValues(alpha: 0.35),
                disabledForegroundColor: _kInk.withValues(alpha: 0.55),
                shape: shape,
              ),
              child: child,
            )
          : OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                backgroundColor: c.surfaceCard,
                foregroundColor: c.textPrimary,
                disabledForegroundColor: c.textPrimary.withValues(alpha: 0.38),
                side: BorderSide(color: c.border),
                shape: shape,
              ),
              child: child,
            ),
    );
  }
}

/// One segment per step: done = tint, current = [now], upcoming = [upcoming].
class _SegmentedProgress extends StatelessWidget {
  final int total;
  final int current;
  final Color done;
  final Color now;
  final Color upcoming;

  const _SegmentedProgress({
    required this.total,
    required this.current,
    required this.done,
    required this.now,
    required this.upcoming,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Test progress',
      value: '${current + 1} of $total',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: 3),
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 6,
                  decoration: BoxDecoration(
                    color: i < current
                        ? done
                        : i == current
                            ? now
                            : upcoming,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Playing a tone…" with a pulsing dot, or a spinner while it loads.
class _ToneIndicator extends StatelessWidget {
  final bool loading;
  final Animation<double>? pulse;
  final Color tint;
  final AppColors colors;

  const _ToneIndicator({
    required this.loading,
    required this.pulse,
    required this.tint,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final label = Text(
      loading ? 'Preparing tone…' : 'Playing a tone…',
      style: TextStyle(color: colors.textSecondary, fontSize: 14),
    );
    final Widget dot;
    if (loading) {
      dot = SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(colors.textSecondary),
        ),
      );
    } else {
      Widget dotAt(double p) => Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: tint,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: tint.withValues(alpha: 0.26 - 0.14 * p),
                  spreadRadius: 3 + 4 * p,
                ),
              ],
            ),
          );
      final pulse = this.pulse;
      dot = pulse == null
          ? dotAt(0.5)
          : AnimatedBuilder(
              animation: pulse,
              builder: (_, _) => dotAt(pulse.value),
            );
    }
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 24, height: 24, child: Center(child: dot)),
          const SizedBox(width: 6),
          label,
        ],
      ),
    );
  }
}

// ── Disclaimer box ────────────────────────────────────────────────────────────
// Uses Text widgets so the app's font family is always applied correctly.

class _DisclaimerBox extends StatelessWidget {
  final String text;
  final IconData icon;
  final AppColors colors;

  const _DisclaimerBox({
    required this.text,
    required this.icon,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    const amber = Color(0xFFFFB86B);
    final amberFg = light ? Color.lerp(amber, Colors.black, 0.45)! : amber;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: light ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: amber.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 18, color: amberFg),
          ),
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
  final String semanticsLabel;
  final bool heard;
  final AppColors colors;

  const _AudiogramColumn({
    required this.label,
    required this.semanticsLabel,
    required this.heard,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: heard ? _kTint : colors.surfaceElevated,
                shape: BoxShape.circle,
                border: heard ? null : Border.all(color: colors.border),
              ),
              child: Icon(
                heard ? Icons.check_rounded : Icons.close_rounded,
                color: heard ? _kInk : colors.textSecondary,
                size: 15,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Separate-ears toggle (intro) ──────────────────────────────────────────────

class _EarToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final Color tintFg;
  final AppColors colors;

  const _EarToggle({
    required this.value,
    required this.onChanged,
    required this.tintFg,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return MergeSemantics(
      child: Material(
        color: value ? _kTint.withValues(alpha: 0.12) : c.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
              color: value ? _kTint.withValues(alpha: 0.5) : c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            Haptics.selection();
            onChanged(!value);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
              child: Row(
                children: [
                  Icon(Icons.headphones_rounded,
                      size: 20, color: value ? tintFg : c.iconSecondary),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Test each ear separately',
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Left ear first, then right',
                          style: TextStyle(color: c.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: value,
                    onChanged: (v) {
                      Haptics.selection();
                      onChanged(v);
                    },
                    activeThumbColor: _kInk,
                    activeTrackColor: _kTint,
                  ),
                ],
              ),
            ),
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
    final c = colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: c.surfaceElevated.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        children: [
          Text(
            ear.label.toUpperCase(),
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            age == null ? '—' : '~$age',
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w700,
              height: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            highest > 0 ? 'up to ${_freqLabel(highest)}' : 'no tones heard',
            style: TextStyle(color: c.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
