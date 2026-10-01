import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

import '../services/clip_repository.dart';
import '../services/haptics.dart';
import '../theme/app_colors.dart';
import '../widgets/permission_denied_card.dart';
import '../widgets/share_card.dart' show soundrPlayStoreUrl;

// ── Constants ────────────────────────────────────────────────────────────────
const _kSampleRate = 44100;
const _kFftSize = 2048; // must be power of 2
const _kNumBands = 40;
const _kMinFreq = 60.0;
const _kMaxFreq = 16000.0;

/// Spectrum tool tint (Midnight Studio palette).
const _kTint = Color(0xFFFF8FA3);

/// Bars above this level are drawn in full tint, the rest faded.
const _kHotLevel = 0.5;

/// Peak markers sit still this long before they start to fall…
const _kPeakHoldMs = 900;

/// …and then fall at this rate (fraction of full scale per second).
const _kPeakDecayPerSec = 0.35;

/// The loudest bin must reach this level for a frequency to be shown.
const _kMinReadoutDb = -72.0;

const _kHoldPeaksPref = 'spectrum_hold_peaks';

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

// ── Musical note ─────────────────────────────────────────────────────────────
const _kNoteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B', //
];

/// Nearest equal-tempered note (A4 = 440 Hz), e.g. "A4"; null below ~30 Hz.
String? noteForFrequency(double? hz) {
  if (hz == null || hz < 30) return null;
  final midi = (69 + 12 * log(hz / 440) / ln2).round();
  return '${_kNoteNames[midi % 12]}${midi ~/ 12 - 1}';
}

// ── Screen ───────────────────────────────────────────────────────────────────
class SpectrumScreen extends StatefulWidget {
  /// Seeds a live-looking display without touching the microphone, so the
  /// layout can be rendered in tests.
  @visibleForTesting
  final List<double>? previewBands;
  @visibleForTesting
  final List<double>? previewPeaks;
  @visibleForTesting
  final double? previewHz;

  const SpectrumScreen({
    super.key,
    this.previewBands,
    this.previewPeaks,
    this.previewHz,
  });

  @override
  State<SpectrumScreen> createState() => _SpectrumScreenState();
}

class _SpectrumScreenState extends State<SpectrumScreen> {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _streamSub;
  bool _running = false;
  bool _frozen = false;
  bool _holdPeaks = true;
  bool _sharing = false;
  String? _error;
  PermissionStatus? _micDenied;

  final List<double> _sampleBuf = [];
  final List<double> _bands = List.filled(_kNumBands, 0.0);
  final List<double> _peaks = List.filled(_kNumBands, 0.0);
  final List<int> _peakAt = List.filled(_kNumBands, 0);
  final _clock = Stopwatch()..start();
  int _lastWindowMs = 0;

  /// Latest loudest frequency (null when quiet) and the throttled value the
  /// readout shows, so the number is readable rather than a blur.
  double? _loudestHz;
  double? _shownHz;
  int _tick = 0;

  final _chartKey = GlobalKey();

  Timer? _repaintTimer;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final pb = widget.previewBands;
    if (pb != null) {
      for (var i = 0; i < _kNumBands && i < pb.length; i++) {
        _bands[i] = pb[i];
        _peaks[i] = widget.previewPeaks?[i] ?? pb[i];
      }
      _shownHz = _loudestHz = widget.previewHz;
      _running = true;
    }
    _loadHoldPeaks();
  }

  Future<void> _loadHoldPeaks() async {
    try {
      final v = await ClipRepository.getBool(_kHoldPeaksPref, defaultValue: true);
      if (mounted && v != _holdPeaks) setState(() => _holdPeaks = v);
    } catch (_) {/* default stays on */}
  }

  @override
  void dispose() {
    _repaintTimer?.cancel();
    _streamSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ── Start / Stop ─────────────────────────────────────────────────────────
  Future<void> _start() async {
    Haptics.light();
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
        _peaks[i] = 0.0;
      }
      _loudestHz = _shownHz = null;
      _lastWindowMs = _clock.elapsedMilliseconds;

      _streamSub = stream.listen(
        _onAudio,
        onError: (Object e) {
          if (mounted) setState(() => _error = e.toString());
        },
      );

      // 30 fps repaint decoupled from audio callback rate
      _repaintTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
        if (!mounted || _frozen) return;
        // The Hz readout refreshes ~6× a second; the bars every frame.
        if (++_tick % 5 == 0 && _shownHz != _loudestHz) {
          _shownHz = _loudestHz;
          _dirty = true;
        }
        if (_dirty) {
          setState(() {});
          _dirty = false;
        }
      });

      setState(() {
        _running = true;
        _frozen = false;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  Future<void> _stop() async {
    Haptics.light();
    _repaintTimer?.cancel();
    _repaintTimer = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _streamSub?.cancel();
    _streamSub = null;
    if (!mounted) return;
    setState(() {
      _running = false;
      _frozen = false;
    });
  }

  /// Freeze holds the display still. The mic keeps streaming (so Resume is
  /// instant) but incoming audio is dropped instead of buffered.
  void _toggleFreeze() {
    Haptics.selection();
    setState(() {
      _frozen = !_frozen;
      if (!_frozen) {
        _sampleBuf.clear();
        _lastWindowMs = _clock.elapsedMilliseconds;
      }
    });
  }

  void _setHoldPeaks(bool v) {
    Haptics.selection();
    setState(() => _holdPeaks = v);
    ClipRepository.setBool(_kHoldPeaksPref, v).catchError((_) {});
  }

  // ── Audio processing pipeline ─────────────────────────────────────────────
  void _onAudio(Uint8List chunk) {
    if (_frozen) return;
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

  static double _toDb(double mag) => 20.0 * log(mag + 1e-10) / ln10;

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
    const halfSize = _kFftSize ~/ 2;
    final mag = List<double>.filled(halfSize, 0.0);
    for (var i = 0; i < halfSize; i++) {
      mag[i] = sqrt(re[i] * re[i] + im[i] * im[i]) / _kFftSize;
    }

    // 6. Loudest frequency — strongest bin (skipping DC leakage), refined by
    //    parabolic interpolation on the dB values of its neighbours.
    const binHz = _kSampleRate / _kFftSize;
    final topBin = min(halfSize - 2, (_kMaxFreq / binHz).ceil());
    var best = 2;
    for (var k = 3; k <= topBin; k++) {
      if (mag[k] > mag[best]) best = k;
    }
    final bestDb = _toDb(mag[best]);
    if (bestDb < _kMinReadoutDb) {
      _loudestHz = null;
    } else {
      final a = _toDb(mag[best - 1]);
      final c = _toDb(mag[best + 1]);
      final denom = a - 2 * bestDb + c;
      final p = denom == 0 ? 0.0 : (0.5 * (a - c) / denom).clamp(-0.5, 0.5);
      final hz = (best + p) * binHz;
      _loudestHz = hz < 30 ? null : hz;
    }

    // 7. Map to log-spaced bands
    const freqRatio = _kMaxFreq / _kMinFreq;
    final now = _clock.elapsedMilliseconds;
    final dt = ((now - _lastWindowMs) / 1000.0).clamp(0.0, 0.1);
    _lastWindowMs = now;

    for (var b = 0; b < _kNumBands; b++) {
      final fLow = _kMinFreq * pow(freqRatio, b / _kNumBands);
      final fHigh = _kMinFreq * pow(freqRatio, (b + 1) / _kNumBands);

      final binLow = (fLow / binHz).ceil().clamp(1, halfSize - 1);
      final binHigh = (fHigh / binHz).floor().clamp(1, halfSize - 1);

      var maxMag = 0.0;
      if (binHigh >= binLow) {
        for (var bin = binLow; bin <= binHigh; bin++) {
          if (mag[bin] > maxMag) maxMag = mag[bin];
        }
      } else {
        // Band narrower than one bin (low end): interpolate at its centre so
        // neighbouring bands don't show identical, stair-stepped bars.
        final centre = sqrt(fLow * fHigh) / binHz;
        final k = centre.floor().clamp(0, halfSize - 2);
        final frac = (centre - k).clamp(0.0, 1.0);
        maxMag = mag[k] + (mag[k + 1] - mag[k]) * frac;
      }

      // Convert to display value: maps -90 dB → 0.0, 0 dB → 1.0
      final val = ((_toDb(maxMag) + 90.0) / 90.0).clamp(0.0, 1.0);

      // 8. Smooth: fast attack, slower decay
      _bands[b] = max(val, _bands[b] * 0.82);

      // 9. Peak markers: jump up instantly, hold, then fall slowly.
      if (_bands[b] >= _peaks[b]) {
        _peaks[b] = _bands[b];
        _peakAt[b] = now;
      } else if (now - _peakAt[b] > _kPeakHoldMs) {
        _peaks[b] = max(_bands[b], _peaks[b] - _kPeakDecayPerSec * dt);
      }
    }

    _dirty = true;
  }

  // ── Share snapshot ───────────────────────────────────────────────────────
  bool get _hasData => _bands.any((v) => v > 0.001);

  Future<void> _shareSnapshot() async {
    Haptics.light();
    setState(() => _sharing = true);
    try {
      final boundary =
          _chartKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final dir = Directory('${(await getTemporaryDirectory()).path}/share');
      await dir.create(recursive: true);
      final file = File('${dir.path}/soundr_spectrum.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      final hz = _shownHz;
      final note = noteForFrequency(hz);
      final detail = hz == null
          ? ''
          : ' — loudest ${hz.round()} Hz${note == null ? '' : ' ($note)'}';
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'image/png')],
        text: 'Spectrum snapshot from Soundr$detail\n$soundrPlayStoreUrl',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t create the image — try again')),
        );
      }
    }
    if (mounted) setState(() => _sharing = false);
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final tintText = light ? Color.lerp(_kTint, Colors.black, 0.45)! : _kTint;
    final tabular = [const FontFeature.tabularFigures()];

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Spectrum',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
        backgroundColor: c.scaffoldBg,
        elevation: 0,
        actions: [
          _StatusPill(running: _running, frozen: _frozen),
          if (_running)
            IconButton(
              tooltip: 'Stop analysing',
              onPressed: _stop,
              icon: Icon(Icons.stop_circle_outlined, color: c.textPrimary),
            ),
          SizedBox(width: _running ? 4 : 16),
        ],
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
                  // ── Loudest frequency readout ──────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('LOUDEST FREQUENCY',
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.4,
                            )),
                        _Readout(
                          hz: _shownHz,
                          tabular: tabular,
                          tintText: tintText,
                        ),
                      ],
                    ),
                  ),

                  // ── Spectrum card (captured by "Share snapshot") ───────
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: RepaintBoundary(
                        key: _chartKey,
                        // Fills the card's rounded corners in the PNG.
                        child: ColoredBox(
                          color: c.scaffoldBg,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
                            decoration: BoxDecoration(
                              color: c.surfaceCard,
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(color: c.border),
                            ),
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: ExcludeSemantics(
                                    child: CustomPaint(
                                      painter: _SpectrumPainter(
                                        bands: List<double>.from(_bands),
                                        peaks: _holdPeaks
                                            ? List<double>.from(_peaks)
                                            : null,
                                        // A deeper rose on white keeps the
                                        // loud bars distinct from the faded.
                                        tint: light
                                            ? Color.lerp(_kTint, Colors.black, 0.18)!
                                            : _kTint,
                                        fadedAlpha: light ? 0.42 : 0.45,
                                        peakColor: c.textPrimary,
                                        grid: c.borderSubtle,
                                        labelStyle: TextStyle(
                                          fontFamily: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.fontFamily,
                                          color: c.textSecondary,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                          fontFeatures: tabular,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (!_running && !_hasData)
                                  Center(
                                    child: Container(
                                      // Masks the grid line behind the hint.
                                      margin: const EdgeInsets.only(bottom: 24),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 6),
                                      color: c.surfaceCard,
                                      child: Text(
                                        'Tap Start to see the frequencies\naround you, live',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: c.textSecondary,
                                          fontSize: 14,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ── Hold peaks ─────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: _HoldPeaksRow(
                      value: _holdPeaks,
                      onChanged: _setHoldPeaks,
                    ),
                  ),

                  // ── Error message ──────────────────────────────────────
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  // ── Bottom actions ─────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _running
                              ? _BigButton(
                                  icon: _frozen
                                      ? Icons.play_arrow_rounded
                                      : Icons.pause_rounded,
                                  label: _frozen ? 'Resume' : 'Freeze',
                                  onTap: _toggleFreeze,
                                )
                              : _BigButton(
                                  icon: Icons.graphic_eq_rounded,
                                  label: 'Start analysing',
                                  filled: true,
                                  onTap: _start,
                                ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _BigButton(
                            icon: Icons.ios_share_rounded,
                            label: 'Share snapshot',
                            busy: _sharing,
                            onTap: _hasData && !_sharing ? _shareSnapshot : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

/// "LIVE" (tint dot) / "FROZEN" / "OFF" status pill for the app bar.
class _StatusPill extends StatelessWidget {
  final bool running;
  final bool frozen;
  const _StatusPill({required this.running, required this.frozen});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final live = running && !frozen;
    final label = !running ? 'OFF' : (frozen ? 'FROZEN' : 'LIVE');
    final fg = live
        ? (light ? Color.lerp(_kTint, Colors.black, 0.45)! : const Color(0xFFFFC2CD))
        : c.textSecondary;
    return Semantics(
      label: 'Analyser ${label.toLowerCase()}',
      excludeSemantics: true,
      child: Center(
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: live
                ? _kTint.withValues(alpha: light ? 0.18 : 0.14)
                : c.surfaceElevated.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: live
                      ? _kTint
                      : frozen
                          ? c.textSecondary
                          : c.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}

/// Big Hz value plus the nearest musical note.
class _Readout extends StatelessWidget {
  final double? hz;
  final List<FontFeature> tabular;
  final Color tintText;
  const _Readout({required this.hz, required this.tabular, required this.tintText});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final note = noteForFrequency(hz);
    return Semantics(
      label: hz == null
          ? 'Loudest frequency: none'
          : 'Loudest frequency ${hz!.round()} hertz${note == null ? '' : ', note $note'}',
      excludeSemantics: true,
      child: SizedBox(
        height: 66,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              hz == null ? '—' : '${hz!.round()}',
              style: TextStyle(
                color: hz == null ? c.textMuted : c.textPrimary,
                fontSize: 54,
                fontWeight: FontWeight.w600,
                letterSpacing: -1.5,
                height: 1.15,
                fontFeatures: tabular,
              ),
            ),
            const SizedBox(width: 10),
            Text('Hz', style: TextStyle(color: c.textSecondary, fontSize: 18)),
            const Spacer(),
            if (note != null)
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  note,
                  style: TextStyle(
                    color: tintText,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    fontFeatures: tabular,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HoldPeaksRow extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _HoldPeaksRow({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Material(
      color: c.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: MergeSemantics(
        child: InkWell(
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Hold peaks',
                          style: TextStyle(color: c.textPrimary, fontSize: 15)),
                      Text('Keep the highest level of each band',
                          style: TextStyle(color: c.textSecondary, fontSize: 12.5)),
                    ],
                  ),
                ),
                Switch(
                  value: value,
                  onChanged: onChanged,
                  activeTrackColor: _kTint,
                  activeThumbColor: Color.lerp(_kTint, Colors.black, 0.78),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool busy;

  const _BigButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final enabled = onTap != null;
    final ink = Color.lerp(_kTint, Colors.black, 0.78)!;
    final fg = filled ? ink : (enabled || busy ? c.textPrimary : c.textMuted);
    return Material(
      color: filled ? _kTint : c.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: filled ? BorderSide.none : BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  )
                else
                  Icon(icon, size: 20, color: fg),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
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

// ── Spectrum painter ─────────────────────────────────────────────────────────

/// Axis labels: (frequency in Hz, display string). Placed on the real
/// log-frequency scale of the bars.
const _kFreqLabels = <(double, String)>[
  (_kMinFreq, '60'),
  (200.0, '200'),
  (1000.0, '1k'),
  (5000.0, '5k'),
  (_kMaxFreq, '16k Hz'),
];

class _SpectrumPainter extends CustomPainter {
  final List<double> bands;

  /// Peak-hold levels, or null when "Hold peaks" is off.
  final List<double>? peaks;
  final Color tint;
  final double fadedAlpha;
  final Color peakColor;
  final Color grid;
  final TextStyle labelStyle;

  _SpectrumPainter({
    required this.bands,
    required this.peaks,
    required this.tint,
    required this.fadedAlpha,
    required this.peakColor,
    required this.grid,
    required this.labelStyle,
  });

  // Vertical space reserved for frequency labels at the bottom
  static const _labelAreaHeight = 24.0;
  static const _barGap = 2.0;
  static const _peakHeadroom = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final barAreaHeight = size.height - _labelAreaHeight;
    // Leave room at the top so a full-scale peak marker stays visible.
    final scale = barAreaHeight - _peakHeadroom;
    final bandWidth = size.width / _kNumBands;
    final barWidth = max(1.0, bandWidth - _barGap);

    // ── Grid lines at 25 %, 50 %, 75 % ────────────────────────────────────
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final frac in [0.25, 0.50, 0.75]) {
      final y = (barAreaHeight - frac * barAreaHeight).roundToDouble() + 0.5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // ── Bars ───────────────────────────────────────────────────────────────
    final hot = Paint()..color = tint;
    final faded = Paint()..color = tint.withValues(alpha: fadedAlpha);
    final peakPaint = Paint()..color = peakColor;

    for (var b = 0; b < _kNumBands; b++) {
      final v = bands[b]; // 0..1
      final left = b * bandWidth + _barGap / 2;

      if (v > 0.001) {
        final barH = max(2.0, v * scale);
        final rect = Rect.fromLTWH(left, barAreaHeight - barH, barWidth, barH);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: const Radius.circular(3),
            topRight: const Radius.circular(3),
            bottomLeft: const Radius.circular(1),
            bottomRight: const Radius.circular(1),
          ),
          v > _kHotLevel ? hot : faded,
        );
      }

      final p = peaks?[b] ?? 0;
      if (p > 0.02) {
        final y = barAreaHeight - p * scale - 4;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, y, barWidth, 2),
            const Radius.circular(1),
          ),
          peakPaint,
        );
      }
    }

    // ── Frequency labels ────────────────────────────────────────────────────
    final freqRatio = _kMaxFreq / _kMinFreq;
    for (final (freq, label) in _kFreqLabels) {
      final x = log(freq / _kMinFreq) / log(freqRatio) * size.width;
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      // Edge labels hug the edges; the rest are centred on their frequency.
      final dx = (freq == _kMinFreq
              ? 0.0
              : freq == _kMaxFreq
                  ? size.width - tp.width
                  : x - tp.width / 2)
          .clamp(0.0, max(0.0, size.width - tp.width))
          .toDouble();
      tp.paint(canvas, Offset(dx, barAreaHeight + 8));
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => true;
}
