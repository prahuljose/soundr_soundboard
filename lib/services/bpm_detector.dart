import 'dart:math';
import 'dart:typed_data';

/// A tempo estimate from [BpmDetector].
class BpmEstimate {
  /// Beats per minute, within [BpmDetector.minBpm]..[BpmDetector.maxBpm].
  final double bpm;

  /// 0..1: how periodic the audio is at this tempo (the normalised
  /// autocorrelation of the onset envelope at the beat period).
  final double confidence;

  const BpmEstimate(this.bpm, this.confidence);

  /// Whether the beat is clear enough to show to the user.
  bool get isReliable => confidence >= BpmDetector.reliableConfidence;

  @override
  String toString() =>
      'BpmEstimate(${bpm.toStringAsFixed(1)} BPM, ${confidence.toStringAsFixed(2)})';
}

/// Streaming tempo estimator for music or clapping heard through a mic.
///
/// 1. **Onset envelope.** The signal is split into three bands (lows, mids,
///    highs) with one-pole filters. Every [hop] samples (~5.8 ms) each band's
///    energy is log-compressed relative to the recent peak level, and the
///    rises since the previous hop (half-wave-rectified difference) are
///    summed. Kicks, claps and hats all show up as spikes; sustained sound
///    does not.
/// 2. **Periodicity.** [estimate] autocorrelates the last [windowSeconds] of
///    that envelope. Every autocorrelation peak between 40 and 240 BPM is a
///    candidate.
/// 3. **Octave choice.** A pulse also correlates at 2×, 3×… its period, and
///    music with eighth-note hats correlates at half the beat period. Each
///    candidate's strength is discounted by the strength at half / a third
///    of its lag (so a multiple of the real pulse loses), then weighted by a
///    perceptual prior — a log-Gaussian centred on 120 BPM.
/// 4. **Refinement.** The winning lag is sharpened with parabolic
///    interpolation and by following its peaks at 2×, 3×… the lag, which
///    divides the frame-quantisation error.
///
/// Tempo-octave errors (½× / 2×) are inherent to the problem — slow music
/// with steady eighth notes is genuinely ambiguous — so callers should let
/// the user halve or double the result.
class BpmDetector {
  BpmDetector({this.sampleRate = 44100, this.onOnset})
    : _lowA = 1 - exp(-2 * pi * 200 / sampleRate),
      _highA = 1 - exp(-2 * pi * 3000 / sampleRate),
      _peakDecay = exp(-hop / sampleRate / 4.0);

  static const double minBpm = 40;
  static const double maxBpm = 240;

  /// Samples per envelope frame.
  static const int hop = 256;

  /// How much audio [estimate] looks at.
  static const double windowSeconds = 10;

  /// Shortest stretch of audio [estimate] will work with.
  static const double minSeconds = 2.5;

  /// Estimates below this confidence are noise, not a beat.
  static const double reliableConfidence = 0.22;

  /// Centre and width (octaves) of the perceptual tempo prior.
  static const double priorBpm = 120;
  static const double priorOctaves = 0.9;

  /// How strongly a candidate is discounted by the autocorrelation at half
  /// and a third of its lag.
  static const double _subharmonicDiscount = 0.5;

  /// Energy range (re. the recent peak) kept by the log compression.
  static const double _compression = 100;

  /// Mean-square level below which the input counts as silence (≈ −60 dBFS).
  static const double _silence = 1e-6;

  final int sampleRate;

  /// Called for each detected onset, with a strength of roughly 0..1.
  final void Function(double strength)? onOnset;

  final double _lowA, _highA, _peakDecay;

  double get _frameRate => sampleRate / hop;

  // Filter state.
  double _lp1 = 0, _lp2 = 0, _hpLp = 0;
  // Per-hop accumulators.
  double _eLow = 0, _eMid = 0, _eHigh = 0;
  int _inHop = 0;
  // Previous compressed band energies.
  double _cLow = 0, _cMid = 0, _cHigh = 0;
  double _peak = 0; // decaying peak of the frame energy
  double _loudest = 0; // loudest frame since reset
  int _samples = 0;
  int? _carry; // odd byte left over from the last PCM chunk

  final List<double> _env = [];

  // Onset picking.
  double _fluxMean = 0;
  double _prev1 = 0, _prev2 = 0;
  int _sinceOnset = 1 << 20;

  /// Recent input level, 0..1 (RMS of the last frame).
  double level = 0;

  /// Milliseconds of audio received since the last [reset].
  int get audioMs => (_samples * 1000 / sampleRate).round();

  void reset() {
    _lp1 = _lp2 = _hpLp = 0;
    _eLow = _eMid = _eHigh = 0;
    _inHop = 0;
    _cLow = _cMid = _cHigh = 0;
    _peak = 0;
    _loudest = 0;
    _samples = 0;
    _carry = null;
    _env.clear();
    _fluxMean = 0;
    _prev1 = _prev2 = 0;
    _sinceOnset = 1 << 20;
    level = 0;
  }

  /// Feeds little-endian 16-bit mono PCM. Chunks may split a sample.
  void addPcm16(Uint8List bytes) {
    var i = 0;
    final carry = _carry;
    if (carry != null && bytes.isNotEmpty) {
      _addSample(_toSample(carry, bytes[0]));
      _carry = null;
      i = 1;
    }
    final n = bytes.length;
    for (; i + 1 < n; i += 2) {
      _addSample(_toSample(bytes[i], bytes[i + 1]));
    }
    if (i < n) _carry = bytes[i];
  }

  static double _toSample(int lo, int hi) {
    var v = lo | (hi << 8);
    if (v >= 0x8000) v -= 0x10000;
    return v / 32768.0;
  }

  /// Feeds samples in −1..1.
  void addSamples(List<double> samples) {
    for (var i = 0; i < samples.length; i++) {
      _addSample(samples[i]);
    }
  }

  void _addSample(double x) {
    _samples++;
    _lp1 += _lowA * (x - _lp1);
    _lp2 += _lowA * (_lp1 - _lp2);
    _hpLp += _highA * (x - _hpLp);
    final low = _lp2;
    final high = x - _hpLp;
    final mid = _hpLp - _lp2;
    _eLow += low * low;
    _eMid += mid * mid;
    _eHigh += high * high;
    if (++_inHop == hop) _endFrame();
  }

  void _endFrame() {
    final eLow = _eLow / hop, eMid = _eMid / hop, eHigh = _eHigh / hop;
    _eLow = _eMid = _eHigh = 0;
    _inHop = 0;

    final total = eLow + eMid + eHigh;
    level = sqrt(total).clamp(0.0, 1.0);
    if (total > _loudest) _loudest = total;
    _peak = max(max(_peak * _peakDecay, total), _silence);

    final k = _compression / _peak;
    final cLow = log(1 + k * eLow);
    final cMid = log(1 + k * eMid);
    final cHigh = log(1 + k * eHigh);
    final flux =
        max(0.0, cLow - _cLow) + max(0.0, cMid - _cMid) + max(0.0, cHigh - _cHigh);
    _cLow = cLow;
    _cMid = cMid;
    _cHigh = cHigh;

    _env.add(flux);
    final cap = (windowSeconds * _frameRate).ceil();
    if (_env.length > cap * 2) _env.removeRange(0, _env.length - cap);

    _pickOnset(flux);
  }

  /// Reports the previous frame as an onset if it was a local peak standing
  /// clear of the recent average.
  void _pickOnset(double flux) {
    _sinceOnset++;
    final candidate = _prev1;
    final minGap = (0.07 * _frameRate).round();
    if (candidate > _prev2 &&
        candidate >= flux &&
        candidate > 0.35 + 2.5 * _fluxMean &&
        _sinceOnset > minGap &&
        _loudest > _silence) {
      _sinceOnset = 0;
      onOnset?.call((candidate / 4).clamp(0.0, 1.0));
    }
    _fluxMean += 0.01 * (flux - _fluxMean);
    _prev2 = _prev1;
    _prev1 = flux;
  }

  static double _prior(double bpm) {
    final oct = log(bpm / priorBpm) / ln2;
    return exp(-0.5 * oct * oct / (priorOctaves * priorOctaves));
  }

  /// The tempo of the audio so far, or null when there is too little audio,
  /// silence, or nothing periodic in it.
  BpmEstimate? estimate() {
    final fr = _frameRate;
    final cap = (windowSeconds * fr).ceil();
    // Skip the first moments: the mic opening and the level tracker settling.
    final skip = (0.15 * fr).round();
    final end = _env.length;
    final start = max(skip, end - cap);
    final n = end - start;
    if (n < minSeconds * fr || _loudest <= _silence) return null;

    final x = Float64List(n);
    var mean = 0.0;
    for (var i = 0; i < n; i++) {
      mean += _env[start + i];
    }
    mean /= n;
    var energy = 0.0;
    for (var i = 0; i < n; i++) {
      final v = _env[start + i] - mean;
      x[i] = v;
      energy += v * v;
    }
    if (energy < 1e-9) return null;

    final minLag = (60 / maxBpm * fr).floor();
    final maxLag = min((60 / minBpm * fr).ceil(), n ~/ 2);
    if (maxLag <= minLag + 2) return null;
    // Lags beyond the tempo range are only used to refine the winner.
    final acfLen = min(n * 2 ~/ 3, (4.0 * fr).ceil()) + 2;
    final r = Float64List(acfLen);
    for (var lag = 1; lag < acfLen; lag++) {
      var s = 0.0;
      final m = n - lag;
      for (var i = 0; i < m; i++) {
        s += x[i] * x[i + lag];
      }
      r[lag] = s / energy;
    }

    double around(double lag) {
      final c = lag.round();
      var best = 0.0;
      for (var i = c - 1; i <= c + 1; i++) {
        if (i >= 1 && i < acfLen && r[i] > best) best = r[i];
      }
      return best;
    }

    var bestScore = 0.0;
    var bestLag = -1;
    for (var lag = max(minLag, 2); lag <= maxLag && lag < acfLen - 1; lag++) {
      final v = r[lag];
      if (v < 0.05 || v < r[lag - 1] || v < r[lag + 1]) continue;
      final sub = max(around(lag / 2), around(lag / 3));
      final strength = v - _subharmonicDiscount * sub;
      if (strength <= 0) continue;
      final score = strength * _prior(60 * fr / lag);
      if (score > bestScore) {
        bestScore = score;
        bestLag = lag;
      }
    }
    if (bestLag < 0) return null;

    double refine(int peak) {
      final a = r[peak - 1], b = r[peak], c = r[peak + 1];
      final d = a - 2 * b + c;
      if (d >= 0) return peak.toDouble();
      return peak + (0.5 * (a - c) / d).clamp(-0.5, 0.5);
    }

    var period = refine(bestLag);
    final confidence = r[bestLag].clamp(0.0, 1.0);
    // Follow the peaks at multiples of the period: the k-th one pins the
    // period down k times more finely.
    for (var k = 2; k <= 8; k++) {
      final centre = (period * k).round();
      if (centre + 2 >= acfLen) break;
      var p = centre;
      for (var i = centre - 2; i <= centre + 2; i++) {
        if (r[i] > r[p]) p = i;
      }
      if (p == centre - 2 || p == centre + 2) break; // no peak here
      if (r[p] < 0.5 * r[bestLag]) break;
      period = refine(p) / k;
    }

    final bpm = (60 * fr / period).clamp(minBpm, maxBpm);
    return BpmEstimate(bpm, confidence);
  }
}

/// Tap tempo: the median of the recent gaps between taps, so one sloppy tap
/// doesn't swing the result. A pause of more than [timeout] starts over.
class TapTempo {
  TapTempo({this.timeout = const Duration(seconds: 2), this.keep = 9});

  /// A gap longer than this starts a fresh measurement.
  final Duration timeout;

  /// How many recent taps the estimate uses.
  final int keep;

  final List<int> _taps = []; // microseconds
  int _count = 0;

  /// Taps in the current run.
  int get count => _count;

  void reset() {
    _taps.clear();
    _count = 0;
  }

  /// Records a tap at [time] (any monotonic clock).
  void tap(Duration time) {
    final t = time.inMicroseconds;
    if (_taps.isNotEmpty && t - _taps.last > timeout.inMicroseconds) reset();
    _taps.add(t);
    _count++;
    if (_taps.length > keep) _taps.removeAt(0);
  }

  List<int> get _gaps => [
    for (var i = 1; i < _taps.length; i++) _taps[i] - _taps[i - 1],
  ];

  double? get _medianGap {
    final g = _gaps..sort();
    if (g.isEmpty) return null;
    final m = g.length ~/ 2;
    final v = g.length.isOdd ? g[m].toDouble() : (g[m - 1] + g[m]) / 2;
    return v > 0 ? v : null;
  }

  /// The tapped tempo, or null before the second tap.
  double? get bpm {
    final m = _medianGap;
    return m == null ? null : 60e6 / m;
  }

  /// True once there are 4+ taps and the last few gaps agree to within 12%.
  bool get isSteady {
    final m = _medianGap;
    if (m == null || _count < 4) return false;
    final g = _gaps;
    for (final v in g.skip(max(0, g.length - 3))) {
      if ((v - m).abs() > 0.12 * m) return false;
    }
    return true;
  }
}
