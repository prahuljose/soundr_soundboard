import 'dart:math';
import 'dart:typed_data';

/// One pitch estimate.
class PitchReading {
  /// Fundamental frequency in Hz.
  final double hz;

  /// 0..1 — how periodic the window was (1 = a perfect tone).
  final double clarity;

  /// Window loudness, RMS of samples in -1..1.
  final double rms;

  const PitchReading(this.hz, this.clarity, this.rms);
}

/// Monophonic pitch detection for a guitar tuner, using the YIN algorithm
/// (de Cheveigné & Kawahara, 2002).
///
/// Feed it 16-bit mono PCM as it arrives with [addPcm16] (or plain samples
/// with [addSamples]); every [hopSize] input samples it analyses the most
/// recent window and calls [onReading] with a [PitchReading], or with null
/// when it's quiet or there's no clear pitch.
///
/// Audio is halved to [sampleRate] / 2 before analysis — plenty for a guitar
/// (the highest open string is ~330 Hz) and four times less work.
class PitchDetector {
  final int sampleRate;

  /// Lowest and highest pitches reported. 60 Hz leaves room below drop C
  /// (65.4 Hz); 1400 Hz covers the high E string's upper frets.
  final double minHz;
  final double maxHz;

  /// Input samples between analyses (~46 ms at 44.1 kHz).
  final int hopSize;

  /// Quieter windows are treated as silence.
  final double silenceRms;

  /// Less periodic windows (noise, a dying note, two strings at once)
  /// are reported as no pitch.
  final double minClarity;

  final void Function(PitchReading? reading) onReading;

  // Analysis runs at half rate.
  late final int _rate = sampleRate ~/ 2;
  late final int _tauMin = max(2, (_rate / maxHz).floor());
  late final int _tauMax = (_rate / minHz).ceil();
  // Integration window: at least ~3 periods of the lowest pitch.
  late final int _window = _nextPow2(_tauMax * 3);
  late final int _needed = _window + _tauMax + 2;

  // Append-only buffer, compacted when full, so adding a sample is O(1).
  late final Float64List _buf = Float64List(_needed * 4);
  int _filled = 0;
  int _sinceHop = 0;
  double? _pendingHalf; // first of a pair awaiting its partner (downsampling)

  late final Float64List _diff = Float64List(_tauMax + 1);

  PitchDetector({
    this.sampleRate = 44100,
    this.minHz = 60,
    this.maxHz = 1400,
    this.hopSize = 2048,
    this.silenceRms = 0.006,
    this.minClarity = 0.9,
    required this.onReading,
  });

  static int _nextPow2(int n) {
    var p = 1;
    while (p < n) {
      p <<= 1;
    }
    return p;
  }

  /// Little-endian signed 16-bit mono PCM, as `record` streams it.
  void addPcm16(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final n = bytes.length ~/ 2;
    for (var i = 0; i < n; i++) {
      _addSample(data.getInt16(i * 2, Endian.little) / 32768.0);
    }
  }

  /// Samples in -1..1 at [sampleRate].
  void addSamples(List<double> samples) {
    for (final s in samples) {
      _addSample(s);
    }
  }

  void reset() {
    _filled = 0;
    _sinceHop = 0;
    _pendingHalf = null;
  }

  void _addSample(double s) {
    // 2:1 downsample; averaging pairs is a gentle low-pass against aliasing.
    final first = _pendingHalf;
    if (first == null) {
      _pendingHalf = s;
    } else {
      _pendingHalf = null;
      _push((first + s) * 0.5);
    }
    if (++_sinceHop >= hopSize) {
      _sinceHop = 0;
      if (_filled >= _needed) onReading(analyse());
    }
  }

  void _push(double v) {
    if (_filled == _buf.length) {
      // Keep only the newest window's worth of samples.
      _buf.setRange(0, _needed, _buf, _filled - _needed);
      _filled = _needed;
    }
    _buf[_filled++] = v;
  }

  /// Analyses the newest window. Public for tests.
  PitchReading? analyse() {
    if (_filled < _needed) return null;
    final x = _buf;
    final w = _window;
    final start = _filled - w - _tauMax;

    // Loudness and DC offset of the window.
    var mean = 0.0;
    for (var i = start; i < start + w + _tauMax; i++) {
      mean += x[i];
    }
    mean /= w + _tauMax;
    var energy = 0.0;
    for (var i = start; i < start + w; i++) {
      final v = x[i] - mean;
      energy += v * v;
    }
    final rms = sqrt(energy / w);
    if (rms < silenceRms) return null;

    // Step 2: difference function d(τ).
    final d = _diff;
    d[0] = 0;
    for (var tau = 1; tau <= _tauMax; tau++) {
      var sum = 0.0;
      for (var i = start; i < start + w; i++) {
        final delta = x[i] - x[i + tau];
        sum += delta * delta;
      }
      d[tau] = sum;
    }

    // Step 3: cumulative mean normalised difference d'(τ).
    var running = 0.0;
    d[0] = 1;
    for (var tau = 1; tau <= _tauMax; tau++) {
      running += d[tau];
      d[tau] = running == 0 ? 1 : d[tau] * tau / running;
    }

    // Step 4: first dip under the threshold, then walk to its bottom.
    const threshold = 0.15;
    var tau = -1;
    for (var t = _tauMin; t <= _tauMax; t++) {
      if (d[t] < threshold) {
        while (t + 1 <= _tauMax && d[t + 1] < d[t]) {
          t++;
        }
        tau = t;
        break;
      }
    }
    if (tau == -1) {
      // No clear dip: take the global minimum if it's still fairly periodic.
      var best = _tauMin;
      for (var t = _tauMin + 1; t <= _tauMax; t++) {
        if (d[t] < d[best]) best = t;
      }
      if (d[best] > 0.35) return null;
      tau = best;
    }
    if (tau <= _tauMin || tau >= _tauMax) return null;

    // Step 5: parabolic interpolation for sub-sample accuracy.
    final a = d[tau - 1], b = d[tau], c = d[tau + 1];
    final denom = a - 2 * b + c;
    final shift = denom.abs() < 1e-12 ? 0.0 : 0.5 * (a - c) / denom;
    final period = tau + shift.clamp(-1.0, 1.0);

    final hz = _rate / period;
    if (hz < minHz || hz > maxHz) return null;
    final clarity = (1 - b).clamp(0.0, 1.0);
    if (clarity < minClarity) return null;
    return PitchReading(hz, clarity, rms);
  }
}
