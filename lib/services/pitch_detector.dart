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

/// Monophonic pitch detection for an instrument tuner, using the YIN algorithm
/// (de Cheveigné & Kawahara, 2002).
///
/// Feed it 16-bit mono PCM as it arrives with [addPcm16] (or plain samples
/// with [addSamples]); every [hopSize] input samples it analyses the most
/// recent window and calls [onReading] with a [PitchReading], or with null
/// when it's quiet or there's no clear pitch.
///
/// Audio is reduced to [sampleRate] / [downsample] before analysis. The
/// default of 2 is plenty for a guitar (the highest open string is ~330 Hz)
/// and four times less work.
///
/// The defaults suit a guitar. Other instruments pass their own range: the
/// analysis window is at least three periods of [minHz], so a lower [minHz]
/// means more latency and more work per reading. A bass (down to ~26 Hz)
/// stays cheap by using [downsample] 4. YIN looks for the repeat period of
/// the whole waveform, so it finds the note from its overtones even when a
/// phone mic barely picks up the fundamental.
class PitchDetector {
  final int sampleRate;

  /// Lowest and highest pitches reported. 60 Hz leaves room below drop C
  /// (65.4 Hz); 1400 Hz covers the high E string's upper frets.
  final double minHz;
  final double maxHz;

  /// Input samples averaged into one analysis sample (1, 2, 4…).
  final int downsample;

  /// Input samples between analyses (~46 ms at 44.1 kHz).
  final int hopSize;

  /// Quieter windows are treated as silence.
  final double silenceRms;

  /// Less periodic windows (noise, a dying note, two strings at once)
  /// are reported as no pitch.
  final double minClarity;

  final void Function(PitchReading? reading) onReading;

  // Analysis runs at a reduced rate.
  late final double _rate = sampleRate / downsample;
  late final int _tauMin = max(2, (_rate / maxHz).floor());
  late final int _tauMax = (_rate / minHz).ceil();
  // Integration window: at least ~3 periods of the lowest pitch.
  late final int _window = _nextPow2(_tauMax * 3);
  late final int _needed = _window + _tauMax + 2;

  // Append-only buffer, compacted when full, so adding a sample is O(1).
  late final Float64List _buf = Float64List(_needed * 4);
  int _filled = 0;
  int _sinceHop = 0;
  double _pendingSum = 0; // samples awaiting the rest of their group
  int _pendingCount = 0;

  late final Float64List _diff = Float64List(_tauMax + 1);

  /// Input samples received so far — an audio clock for [onReading].
  int get samplesIn => _samplesIn;
  int _samplesIn = 0;

  /// [samplesIn] as milliseconds of audio.
  int get audioMs => _samplesIn * 1000 ~/ sampleRate;

  PitchDetector({
    this.sampleRate = 44100,
    this.minHz = 60,
    this.maxHz = 1400,
    this.downsample = 2,
    this.hopSize = 2048,
    this.silenceRms = 0.006,
    this.minClarity = 0.9,
    required this.onReading,
  }) : assert(downsample >= 1),
       assert(minHz > 0 && maxHz > minHz);

  /// Audio needed before the first reading, in milliseconds.
  int get latencyMs => (_needed * 1000 / _rate).ceil();

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
    _pendingSum = 0;
    _pendingCount = 0;
  }

  void _addSample(double s) {
    _samplesIn++;
    // Downsample by averaging each group: a gentle low-pass against
    // aliasing.
    _pendingSum += s;
    if (++_pendingCount >= downsample) {
      _push(_pendingSum / downsample);
      _pendingSum = 0;
      _pendingCount = 0;
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
