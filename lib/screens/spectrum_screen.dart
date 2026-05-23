import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../theme/app_colors.dart';
import '../widgets/permission_denied_card.dart';

// ── Constants ────────────────────────────────────────────────────────────────
const _kSampleRate = 44100;
const _kFftSize = 2048; // must be power of 2
const _kNumBands = 24;
const _kMinFreq = 60.0;
const _kMaxFreq = 16000.0;

// ── FFT ──────────────────────────────────────────────────────────────────────
void _fftInPlace(List<double> re, List<double> im) {
  final n = re.length;
  // Bit-reversal permutation
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i];
      re[i] = re[j];
      re[j] = t;
      t = im[i];
      im[i] = im[j];
      im[j] = t;
    }
  }
  // Cooley-Tukey butterfly
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * pi / len;
    final wRe = cos(ang);
    final wIm = sin(ang);
    for (var i = 0; i < n; i += len) {
      double urRe = 1;
      double urIm = 0;
      for (var k = 0; k < len ~/ 2; k++) {
        final ai = i + k;
        final bi = i + k + len ~/ 2;
        final vRe = re[bi] * urRe - im[bi] * urIm;
        final vIm = re[bi] * urIm + im[bi] * urRe;
        re[bi] = re[ai] - vRe;
        im[bi] = im[ai] - vIm;
        re[ai] += vRe;
        im[ai] += vIm;
        final nr = urRe * wRe - urIm * wIm;
        urIm = urRe * wIm + urIm * wRe;
        urRe = nr;
      }
    }
  }
}

// ── Screen ───────────────────────────────────────────────────────────────────
class SpectrumScreen extends StatefulWidget {
  const SpectrumScreen({super.key});

  @override
  State<SpectrumScreen> createState() => _SpectrumScreenState();
}

class _SpectrumScreenState extends State<SpectrumScreen> {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _streamSub;
  bool _running = false;
  String? _error;
  PermissionStatus? _micDenied;

  final List<double> _sampleBuf = [];
  final List<double> _bands = List.filled(_kNumBands, 0.0);

  Timer? _repaintTimer;
  bool _dirty = false;

  @override
  void dispose() {
    _repaintTimer?.cancel();
    _streamSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ── Start / Stop ─────────────────────────────────────────────────────────
  Future<void> _start() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() {
        _micDenied = status;
        _error = null;
      });
      return;
    }
    setState(() => _micDenied = null);

    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _kSampleRate,
          numChannels: 1,
        ),
      );
      _sampleBuf.clear();
      for (var i = 0; i < _kNumBands; i++) {
        _bands[i] = 0.0;
      }

      _streamSub = stream.listen(
        _onAudio,
        onError: (Object e) {
          if (mounted) setState(() => _error = e.toString());
        },
      );

      // 30 fps repaint decoupled from audio callback rate
      _repaintTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
        if (!mounted) return;
        if (_dirty) {
          setState(() {});
          _dirty = false;
        }
      });

      setState(() {
        _running = true;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _stop() async {
    _repaintTimer?.cancel();
    _repaintTimer = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _streamSub?.cancel();
    _streamSub = null;
    setState(() => _running = false);
  }

  // ── Audio processing pipeline ─────────────────────────────────────────────
  void _onAudio(Uint8List chunk) {
    // 1. Parse 16-bit LE samples and normalise to [-1, 1]
    final numSamples = chunk.length ~/ 2;
    for (var i = 0; i < numSamples; i++) {
      final byteIdx = i * 2;
      var raw = chunk[byteIdx] | (chunk[byteIdx + 1] << 8);
      if (raw > 32767) raw -= 65536;
      _sampleBuf.add(raw / 32768.0);
    }

    // 2. Process all complete windows (50% overlap)
    const hopSize = _kFftSize ~/ 2;
    while (_sampleBuf.length >= _kFftSize) {
      _processWindow(_sampleBuf.sublist(0, _kFftSize));
      _sampleBuf.removeRange(0, hopSize);
    }
  }

  void _processWindow(List<double> samples) {
    final re = List<double>.from(samples);
    final im = List<double>.filled(_kFftSize, 0.0);

    // 3. Apply Hann window
    for (var i = 0; i < _kFftSize; i++) {
      re[i] *= 0.5 * (1.0 - cos(2.0 * pi * i / (_kFftSize - 1)));
    }

    // 4. FFT
    _fftInPlace(re, im);

    // 5. Magnitude spectrum (first half only)
    final halfSize = _kFftSize ~/ 2;
    final mag = List<double>.filled(halfSize, 0.0);
    for (var i = 0; i < halfSize; i++) {
      mag[i] = sqrt(re[i] * re[i] + im[i] * im[i]) / _kFftSize;
    }

    // 6. Map to log-spaced bands
    const binHz = _kSampleRate / _kFftSize;
    final freqRatio = _kMaxFreq / _kMinFreq;

    for (var b = 0; b < _kNumBands; b++) {
      final fLow = _kMinFreq * pow(freqRatio, b / _kNumBands);
      final fHigh = _kMinFreq * pow(freqRatio, (b + 1) / _kNumBands);

      final binLow = (fLow / binHz).floor().clamp(1, halfSize - 1);
      final binHigh = (fHigh / binHz).floor().clamp(1, halfSize - 1);

      var maxMag = 0.0;
      for (var bin = binLow; bin <= binHigh; bin++) {
        if (mag[bin] > maxMag) maxMag = mag[bin];
      }

      // Convert to display value: maps -90 dB → 0.0, 0 dB → 1.0
      final val =
          ((20.0 * log(maxMag + 1e-10) / ln10 + 90.0) / 90.0).clamp(0.0, 1.0);

      // 7. Smooth: fast attack, slower decay
      _bands[b] = max(val, _bands[b] * 0.82);
    }

    _dirty = true;
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text('Spectrum Analyser'),
        backgroundColor: c.scaffoldBg,
        elevation: 0,
      ),
      body: SafeArea(
        child: _micDenied != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: PermissionDeniedCard(
                    permission: Permission.microphone,
                    icon: Icons.equalizer_rounded,
                    permissionLabel: 'Microphone',
                    purpose:
                        'The spectrum analyser visualises sound from your microphone in real time. '
                        'Audio is processed locally — nothing is recorded or transmitted.',
                    onGranted: () {
                      if (mounted) setState(() => _micDenied = null);
                    },
                  ),
                ),
              )
            : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Spectrum card ────────────────────────────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: c.surfaceCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: c.border),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _SpectrumPainter(
                        bands: List<double>.from(_bands),
                        accent: accent,
                        muted: c.textMuted,
                        running: _running,
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // ── Error message ────────────────────────────────────────────
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),

            // ── Start / Stop button ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: SizedBox(
                height: 54,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _running ? c.surfaceCard : accent,
                    foregroundColor: _running ? c.textPrimary : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                      side: _running
                          ? BorderSide(color: c.border)
                          : BorderSide.none,
                    ),
                    elevation: 0,
                  ),
                  onPressed: _running ? _stop : _start,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _running
                            ? Icons.stop_rounded
                            : Icons.graphic_eq_rounded,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _running ? 'Stop' : 'Start analysing',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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

// ── Spectrum painter ─────────────────────────────────────────────────────────

/// Frequency labels drawn below the bars.
/// Each entry: (approximate center frequency in Hz, display string).
const _kFreqLabels = <(double, String)>[
  (100.0, '100'),
  (250.0, '250'),
  (500.0, '500'),
  (1000.0, '1k'),
  (2000.0, '2k'),
  (4000.0, '4k'),
  (8000.0, '8k'),
  (16000.0, '16k'),
];

class _SpectrumPainter extends CustomPainter {
  final List<double> bands;
  final Color accent;
  final Color muted;
  final bool running;

  _SpectrumPainter({
    required this.bands,
    required this.accent,
    required this.muted,
    required this.running,
  });

  // Vertical space reserved for frequency labels at the bottom
  static const _labelAreaHeight = 22.0;
  static const _barGap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final barAreaHeight = size.height - _labelAreaHeight;
    final bandWidth = size.width / _kNumBands;
    final barWidth = bandWidth - _barGap;

    // ── Grid lines at 25 %, 50 %, 75 % ────────────────────────────────────
    final gridPaint = Paint()
      ..color = muted.withValues(alpha: 0.18)
      ..strokeWidth = 0.6;
    for (final frac in [0.25, 0.50, 0.75]) {
      final y = barAreaHeight - frac * barAreaHeight;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // ── Bars ───────────────────────────────────────────────────────────────
    const midColor = Color(0xFFFFB020);
    const highColor = Color(0xFFE53935);

    for (var b = 0; b < _kNumBands; b++) {
      final v = bands[b]; // 0..1
      if (v <= 0.001) continue;

      final barH = v * barAreaHeight;
      final left = b * bandWidth + _barGap / 2;
      final top = barAreaHeight - barH;
      final rect = Rect.fromLTWH(left, top, barWidth, barH);

      // Colour: lerp accent → midColor → highColor based on band value
      final Color barColor;
      if (v < 0.5) {
        barColor = Color.lerp(accent, midColor, v / 0.5)!;
      } else {
        barColor = Color.lerp(midColor, highColor, (v - 0.5) / 0.5)!;
      }

      // Vertical gradient: brighter at the top of each bar
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          barColor,
          barColor.withValues(alpha: 0.65),
        ],
      );

      final paint = Paint()
        ..shader = gradient.createShader(rect)
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        paint,
      );
    }

    // ── Frequency labels ────────────────────────────────────────────────────
    // Each band b has center at log scale: freq_b = _kMinFreq * (ratio)^((b+0.5)/_kNumBands)
    final freqRatio = _kMaxFreq / _kMinFreq;

    // "60 Hz" at the far left edge
    _drawLabel(canvas, '60', 0, barAreaHeight, size.width, alignLeft: true);
    // "16k" at the far right edge
    _drawLabel(canvas, '16k', size.width, barAreaHeight, size.width,
        alignRight: true);

    for (final (targetFreq, label) in _kFreqLabels) {
      // Find which band x-position corresponds to targetFreq
      // bandX = (log(freq/_kMinFreq) / log(ratio)) * _kNumBands * bandWidth
      final frac =
          log(targetFreq / _kMinFreq) / log(freqRatio); // 0..1 along bands
      final x = frac * size.width;
      if (x < 12 || x > size.width - 12) continue; // skip if too close to edge
      _drawLabel(canvas, label, x, barAreaHeight, size.width);
    }
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    double centerX,
    double topY,
    double maxWidth, {
    bool alignLeft = false,
    bool alignRight = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: muted.withValues(alpha: 0.9),
          fontSize: 9,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 40);

    double dx;
    if (alignLeft) {
      dx = 4;
    } else if (alignRight) {
      dx = maxWidth - tp.width - 4;
    } else {
      dx = centerX - tp.width / 2;
    }
    dx = dx.clamp(0, maxWidth - tp.width);
    tp.paint(canvas, Offset(dx, topY + 5));
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => true;
}
