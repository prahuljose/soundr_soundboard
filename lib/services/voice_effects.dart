import 'dart:math';
import 'dart:typed_data';

/// The voices offered by the voice changer, in grid order.
enum VoiceEffect {
  normal('Normal', '🙂'),
  chipmunk('Chipmunk', '🐿️'),
  helium('Helium', '🎈'),
  deep('Deep', '🐻'),
  monster('Monster', '👹'),
  robot('Robot', '🤖'),
  alien('Alien', '👽'),
  echo('Echo', '🏔️'),
  stadium('Stadium', '🏟️'),
  radio('Radio', '📻'),
  underwater('Underwater', '🌊'),
  backwards('Backwards', '🔁');

  final String label;
  final String emoji;
  const VoiceEffect(this.label, this.emoji);
}

/// Top-level entry point for `compute` / `Isolate.run`.
Float64List renderVoiceEffect((VoiceEffect, Float64List) job) =>
    VoiceEffects.apply(job.$1, job.$2);

/// Offline voice effects on mono 44.1 kHz samples in -1..1. Everything is
/// rendered to a buffer (no real-time processing), so what you preview is
/// exactly what gets shared or saved. Deterministic: the same input always
/// gives the same output.
class VoiceEffects {
  VoiceEffects._();

  static const sampleRate = 44100;
  static const _sr = sampleRate;

  /// Output peak level.
  static const targetPeak = 0.9;

  /// Renders [effect] on [input]: a new buffer, peak-normalised to
  /// [targetPeak]. Effects with a tail (echo, reverb) come out a little
  /// longer than the input; speed changes make it shorter or longer.
  static Float64List apply(VoiceEffect effect, Float64List input) {
    if (input.isEmpty) return Float64List(0);
    if (_peak(input) < 1e-4) return Float64List(input.length);
    // Level the input first so drive / clipping stages behave the same for
    // quiet and loud recordings.
    final x = normalize(input);
    final Float64List y;
    switch (effect) {
      case VoiceEffect.normal:
        y = x;
      case VoiceEffect.chipmunk:
        y = pitchShift(x, 8, speed: 1.12);
      case VoiceEffect.helium:
        y = pitchShift(x, 5);
        _Biquad.highPass(170, 0.707).process(y);
        _Biquad.highShelf(2800, 7).process(y);
        _Biquad.peaking(1200, 1.2, -3).process(y);
      case VoiceEffect.deep:
        y = pitchShift(x, -5);
        _Biquad.lowShelf(200, 3).process(y);
      case VoiceEffect.monster:
        final low = pitchShift(x, -8, speed: 0.92);
        _Biquad.lowShelf(180, 5).process(low);
        final growl = normalize(low);
        _drive(growl, 2.6);
        y = reverb(
          growl,
          size: 0.9,
          feedback: 0.78,
          damp: 0.45,
          wet: 0.22,
          tailSeconds: 0.9,
        );
      case VoiceEffect.robot:
        y = robot(x);
        _Biquad.highPass(120, 0.707).process(y);
        _Biquad.peaking(2400, 1.5, 4).process(y);
      case VoiceEffect.alien:
        final up = pitchShift(x, 4);
        final wob = vibrato(up, rateHz: 6.5, depthMs: 1.3);
        y = ringModulate(wob, 170, mix: 0.45);
      case VoiceEffect.echo:
        y = echo(x, delayMs: 260, feedback: 0.45, mix: 0.65);
      case VoiceEffect.stadium:
        y = reverb(
          x,
          size: 1.5,
          feedback: 0.86,
          damp: 0.3,
          wet: 0.5,
          preDelayMs: 45,
          tailSeconds: 2.4,
        );
      case VoiceEffect.radio:
        y = telephone(x);
      case VoiceEffect.underwater:
        final wob = vibrato(x, rateHz: 1.3, depthMs: 3.5);
        _tremolo(wob, 3.2, 0.18);
        for (final q in _butterworth4) {
          _Biquad.lowPass(650, q).process(wob);
        }
        y = reverb(
          wob,
          size: 0.6,
          feedback: 0.7,
          damp: 0.6,
          wet: 0.3,
          tailSeconds: 0.6,
        );
      case VoiceEffect.backwards:
        y = reverse(x);
    }
    return _finish(y, minLength: _minLength(effect, input.length));
  }

  static int _minLength(VoiceEffect e, int n) => switch (e) {
    VoiceEffect.chipmunk => (n / 1.12).round(),
    VoiceEffect.monster => (n / 0.92).round(),
    _ => n,
  };

  // ── Building blocks ──────────────────────────────────────────────────────

  /// Scales so the peak is [peak], boosting by at most [maxGain]. Silence
  /// stays silence.
  static Float64List normalize(
    Float64List x, {
    double peak = targetPeak,
    double maxGain = 16,
  }) {
    final p = _peak(x);
    final out = Float64List(x.length);
    if (p < 1e-9 || !p.isFinite) return out;
    final g = min(peak / p, maxGain);
    for (var i = 0; i < x.length; i++) {
      out[i] = x[i] * g;
    }
    return out;
  }

  /// Exact reversal.
  static Float64List reverse(Float64List x) {
    final n = x.length;
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = x[n - 1 - i];
    }
    return out;
  }

  /// Plays [x] [factor] times faster (shorter and higher, like a tape).
  static Float64List changeSpeed(Float64List x, double factor) =>
      _readAt(x, factor, max(1, (x.length / factor).round()));

  /// Shifts pitch by [semitones] (±12) keeping the duration — or, with
  /// [speed] ≠ 1, also making it that many times faster. Time-stretches
  /// with WSOLA, then resamples.
  static Float64List pitchShift(
    Float64List x,
    double semitones, {
    double speed = 1,
  }) {
    final ratio = pow(2, semitones / 12).toDouble();
    final stretched = timeStretch(x, ratio / speed);
    return _readAt(stretched, ratio, max(1, (x.length / speed).round()));
  }

  /// Changes duration by [alpha] (output length / input length) without
  /// changing pitch: WSOLA — Hann-windowed frames overlap-added at a fixed
  /// output hop, each taken from near its nominal input position at the
  /// offset that best continues the previous frame's waveform.
  static Float64List timeStretch(Float64List x, double alpha) {
    if (x.isEmpty) return Float64List(0);
    const n = 1536; // ~35 ms frames
    const hs = n ~/ 2; // output hop (50% overlap; periodic Hann sums to 1)
    const tol = 400; // search ±9 ms — longer than a low voice's period
    final outLen = max(1, (x.length * alpha).round());
    final ha = hs / alpha;
    const pad = n + tol + 8;
    final xp = Float64List(x.length + 2 * pad + 4 * n);
    xp.setRange(pad, pad + x.length, x);
    final maxStart = xp.length - n;
    final win = _hann(n);
    final y = Float64List(outLen + 2 * n);

    var prev = -1;
    for (var k = 0; ; k++) {
      final outStart = n + (k - 1) * hs; // buffer offset n
      if (outStart - n >= outLen) break;
      final nominal = (pad + k * ha - hs).round().clamp(0, maxStart);
      var best = nominal;
      if (prev >= 0) {
        final nat = min(prev + hs, maxStart);
        best = _bestOffset(xp, nat, nominal, tol, hs, maxStart);
      }
      for (var i = 0; i < n; i++) {
        y[outStart + i] += xp[best + i] * win[i];
      }
      prev = best;
    }
    return Float64List.fromList(Float64List.sublistView(y, n, n + outLen));
  }

  /// The start within [nominal] ± [tol] whose first [len] samples best
  /// match those at [nat]: a coarse decimated search, then a fine one.
  static int _bestOffset(
    Float64List x,
    int nat,
    int nominal,
    int tol,
    int len,
    int maxStart,
  ) {
    final lo = max(0, nominal - tol);
    final hi = min(maxStart, nominal + tol);
    double corr(int p, int stride) {
      var s = 0.0;
      for (var i = 0; i < len; i += stride) {
        s += x[p + i] * x[nat + i];
      }
      return s;
    }

    var best = nominal;
    var bestScore = corr(nominal, 4);
    for (var p = lo; p <= hi; p += 4) {
      final s = corr(p, 4);
      if (s > bestScore) {
        bestScore = s;
        best = p;
      }
    }
    final c = best;
    bestScore = corr(c, 2);
    for (var p = max(lo, c - 3); p <= min(hi, c + 3); p++) {
      final s = corr(p, 2);
      if (s > bestScore) {
        bestScore = s;
        best = p;
      }
    }
    return best;
  }

  /// Reads [x] every [step] samples (cubic interpolation) for [outLen]
  /// samples, low-passing first when that would alias.
  static Float64List _readAt(Float64List x, double step, int outLen) {
    var src = x;
    if (step > 1.02) {
      src = Float64List.fromList(x);
      final fc = min(0.45 * _sr / step, 19000.0);
      for (final q in _butterworth4) {
        _Biquad.lowPass(fc, q).process(src);
      }
    }
    final out = Float64List(outLen);
    for (var i = 0; i < outLen; i++) {
      out[i] = _cubic(src, i * step);
    }
    return out;
  }

  /// Catmull-Rom interpolation of [x] at fractional index [t] (0 outside).
  static double _cubic(Float64List x, double t) {
    final i = t.floor();
    final f = t - i;
    final n = x.length;
    double at(int j) => (j < 0 || j >= n) ? 0.0 : x[j];
    final p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
    return p1 +
        0.5 *
            f *
            (p2 -
                p0 +
                f *
                    (2 * p0 -
                        5 * p1 +
                        4 * p2 -
                        p3 +
                        f * (3 * (p1 - p2) + p3 - p0)));
  }

  /// Robot: a fixed-pitch "vocoder-lite". Each short frame keeps its
  /// spectral envelope (what makes the words) but loses its phase, and
  /// frames are laid down every [hop] samples — so the voice buzzes at a
  /// single pitch (44100 / 400 ≈ 110 Hz).
  static Float64List robot(Float64List x, {int hop = 400}) {
    const n = 1024;
    final win = _hann(n);
    final fft = _Fft(n);
    final re = Float64List(n), im = Float64List(n);
    final y = Float64List(x.length + n);
    for (var start = -n ~/ 2; start < x.length; start += hop) {
      for (var i = 0; i < n; i++) {
        final j = start + i;
        re[i] = (j >= 0 && j < x.length) ? x[j] * win[i] : 0.0;
        im[i] = 0;
      }
      fft.transform(re, im);
      for (var k = 0; k < n; k++) {
        final m = sqrt(re[k] * re[k] + im[k] * im[k]);
        // Zero phase, delayed by n/2 so the pulse sits mid-frame.
        re[k] = k.isOdd ? -m : m;
        im[k] = 0;
      }
      fft.inverse(re, im);
      for (var i = 0; i < n; i++) {
        final j = start + i;
        if (j >= 0 && j < y.length) y[j] += re[i] * win[i];
      }
    }
    return Float64List.fromList(Float64List.sublistView(y, 0, x.length));
  }

  /// Multiplies by a sine carrier at [hz]; [mix] 1 is pure ring modulation.
  static Float64List ringModulate(Float64List x, double hz, {double mix = 1}) {
    final out = Float64List(x.length);
    final w = 2 * pi * hz / _sr;
    for (var i = 0; i < x.length; i++) {
      out[i] = x[i] * ((1 - mix) + mix * sin(w * i));
    }
    return out;
  }

  /// Pitch wobble: a delay line swept by a sine at [rateHz], ±[depthMs].
  static Float64List vibrato(
    Float64List x, {
    required double rateHz,
    required double depthMs,
  }) {
    final depth = depthMs / 1000 * _sr;
    final base = depth + 2;
    final w = 2 * pi * rateHz / _sr;
    final out = Float64List(x.length);
    for (var i = 0; i < x.length; i++) {
      out[i] = _cubic(x, i - base - depth * sin(w * i));
    }
    return out;
  }

  /// Repeating echo: a feedback delay of [delayMs], each repeat a little
  /// darker. The output runs on until the echoes have died away.
  static Float64List echo(
    Float64List x, {
    double delayMs = 250,
    double feedback = 0.45,
    double mix = 0.6,
    double maxTailSeconds = 2.5,
  }) {
    final d = max(1, (delayMs / 1000 * _sr).round());
    // Repeats until ~-50 dB.
    final repeats = (log(0.003) / log(feedback)).ceil();
    final tail = min(repeats * d, (maxTailSeconds * _sr).round());
    final total = x.length + tail;
    final line = Float64List(total);
    final out = Float64List(total);
    var lp = 0.0;
    for (var i = 0; i < total; i++) {
      final input = i < x.length ? x[i] : 0.0;
      final delayed = i >= d ? line[i - d] : 0.0;
      lp += 0.55 * (delayed - lp); // gentle high-cut per repeat
      line[i] = input + feedback * lp;
      out[i] = input + mix * lp;
    }
    return out;
  }

  /// Freeverb-lite: four damped feedback combs in parallel into two
  /// allpasses. [size] scales the comb delays (bigger room), [feedback]
  /// sets the decay, [damp] how fast highs die away.
  static Float64List reverb(
    Float64List x, {
    double size = 1,
    double feedback = 0.84,
    double damp = 0.25,
    double wet = 0.3,
    double dry = 1,
    double preDelayMs = 0,
    double tailSeconds = 1.5,
  }) {
    final pre = (preDelayMs / 1000 * _sr).round();
    final total = x.length + (tailSeconds * _sr).round();
    final combs = [
      for (final d in const [1116, 1277, 1422, 1617])
        _Comb((d * size).round(), feedback, damp),
    ];
    final aps = [_Allpass(556), _Allpass(341)];
    final out = Float64List(total);
    for (var i = 0; i < total; i++) {
      final input = i < x.length ? x[i] : 0.0;
      final j = i - pre;
      final send = (j >= 0 && j < x.length ? x[j] : 0.0) * 0.25;
      var r = 0.0;
      for (final c in combs) {
        r += c.process(send);
      }
      for (final a in aps) {
        r = a.process(r);
      }
      out[i] = dry * input + wet * r;
    }
    return out;
  }

  /// Telephone / AM radio: band-limited to ~300–3400 Hz with a nasal
  /// mid bump, a little line hiss and soft clipping.
  static Float64List telephone(Float64List x) {
    final y = Float64List.fromList(x);
    final rnd = Random(7);
    for (var i = 0; i < y.length; i++) {
      y[i] += (rnd.nextDouble() * 2 - 1) * 0.012;
    }
    for (final q in _butterworth4) {
      _Biquad.highPass(300, q).process(y);
    }
    for (final q in _butterworth4) {
      _Biquad.lowPass(3400, q).process(y);
    }
    _Biquad.peaking(1700, 1.1, 5).process(y);
    final z = normalize(y, peak: 1);
    _drive(z, 2.2);
    return z;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  /// Q values for a 4th-order Butterworth as two biquads.
  static const _butterworth4 = [0.5412, 1.3066];

  /// Soft clipping in place, gain-compensated.
  static void _drive(Float64List x, double amount) {
    final norm = 1 / _tanh(amount);
    for (var i = 0; i < x.length; i++) {
      x[i] = _tanh(x[i] * amount) * norm;
    }
  }

  static double _tanh(double v) {
    if (v > 20) return 1;
    if (v < -20) return -1;
    final e = exp(2 * v);
    return (e - 1) / (e + 1);
  }

  static void _tremolo(Float64List x, double hz, double depth) {
    final w = 2 * pi * hz / _sr;
    for (var i = 0; i < x.length; i++) {
      x[i] *= 1 - depth * 0.5 * (1 + sin(w * i));
    }
  }

  static double _peak(Float64List x) {
    var p = 0.0;
    for (final v in x) {
      final a = v.abs();
      if (a > p) p = a;
    }
    return p;
  }

  static Float64List _hann(int n) => Float64List.fromList(
    List.generate(n, (i) => 0.5 - 0.5 * cos(2 * pi * i / n)),
  );

  /// Clears NaNs, trims a silent tail beyond [minLength], normalises and
  /// fades the edges so nothing clicks.
  static Float64List _finish(Float64List y, {required int minLength}) {
    for (var i = 0; i < y.length; i++) {
      if (!y[i].isFinite) y[i] = 0;
    }
    final p = _peak(y);
    var end = y.length;
    if (p > 0 && y.length > minLength) {
      final thr = p * 0.003; // about -50 dB
      var last = y.length - 1;
      while (last > minLength && y[last].abs() < thr) {
        last--;
      }
      end = min(y.length, max(minLength, last + _sr ~/ 20));
    }
    final out = normalize(Float64List.sublistView(y, 0, end), maxGain: 1e6);
    final fade = min(_sr * 4 ~/ 1000, out.length ~/ 2);
    for (var i = 0; i < fade; i++) {
      final g = i / fade;
      out[i] *= g;
      out[out.length - 1 - i] *= g;
    }
    return out;
  }
}

/// RBJ cookbook biquad, transposed direct form II, processed in place.
class _Biquad {
  final double b0, b1, b2, a1, a2;
  double _z1 = 0, _z2 = 0;

  _Biquad._(double b0, double b1, double b2, double a0, double a1, double a2)
    : b0 = b0 / a0,
      b1 = b1 / a0,
      b2 = b2 / a0,
      a1 = a1 / a0,
      a2 = a2 / a0;

  static const _sr = VoiceEffects.sampleRate;

  factory _Biquad.lowPass(double f, double q) {
    final w = 2 * pi * f / _sr, c = cos(w), al = sin(w) / (2 * q);
    return _Biquad._((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
  }

  factory _Biquad.highPass(double f, double q) {
    final w = 2 * pi * f / _sr, c = cos(w), al = sin(w) / (2 * q);
    return _Biquad._(
      (1 + c) / 2,
      -(1 + c),
      (1 + c) / 2,
      1 + al,
      -2 * c,
      1 - al,
    );
  }

  factory _Biquad.peaking(double f, double q, double db) {
    final a = pow(10, db / 40).toDouble();
    final w = 2 * pi * f / _sr, c = cos(w), al = sin(w) / (2 * q);
    return _Biquad._(
      1 + al * a,
      -2 * c,
      1 - al * a,
      1 + al / a,
      -2 * c,
      1 - al / a,
    );
  }

  factory _Biquad.lowShelf(double f, double db) {
    final a = pow(10, db / 40).toDouble();
    final w = 2 * pi * f / _sr, c = cos(w), al = sin(w) / 2 * sqrt2;
    final sa = 2 * sqrt(a) * al;
    return _Biquad._(
      a * ((a + 1) - (a - 1) * c + sa),
      2 * a * ((a - 1) - (a + 1) * c),
      a * ((a + 1) - (a - 1) * c - sa),
      (a + 1) + (a - 1) * c + sa,
      -2 * ((a - 1) + (a + 1) * c),
      (a + 1) + (a - 1) * c - sa,
    );
  }

  factory _Biquad.highShelf(double f, double db) {
    final a = pow(10, db / 40).toDouble();
    final w = 2 * pi * f / _sr, c = cos(w), al = sin(w) / 2 * sqrt2;
    final sa = 2 * sqrt(a) * al;
    return _Biquad._(
      a * ((a + 1) + (a - 1) * c + sa),
      -2 * a * ((a - 1) + (a + 1) * c),
      a * ((a + 1) + (a - 1) * c - sa),
      (a + 1) - (a - 1) * c + sa,
      2 * ((a - 1) - (a + 1) * c),
      (a + 1) - (a - 1) * c - sa,
    );
  }

  void process(Float64List x) {
    var z1 = _z1, z2 = _z2;
    for (var i = 0; i < x.length; i++) {
      final v = x[i];
      final y = b0 * v + z1;
      z1 = b1 * v - a1 * y + z2;
      z2 = b2 * v - a2 * y;
      x[i] = y;
    }
    _z1 = z1;
    _z2 = z2;
  }
}

class _Comb {
  final Float64List _buf;
  final double feedback, damp;
  int _i = 0;
  double _store = 0;

  _Comb(int size, this.feedback, this.damp) : _buf = Float64List(max(1, size));

  double process(double input) {
    final out = _buf[_i];
    _store = out * (1 - damp) + _store * damp;
    _buf[_i] = input + _store * feedback;
    if (++_i >= _buf.length) _i = 0;
    return out;
  }
}

class _Allpass {
  final Float64List _buf;
  int _i = 0;

  _Allpass(int size) : _buf = Float64List(size);

  double process(double input) {
    final b = _buf[_i];
    _buf[_i] = input + b * 0.5;
    if (++_i >= _buf.length) _i = 0;
    return b - input;
  }
}

/// In-place radix-2 complex FFT of a fixed power-of-two size.
class _Fft {
  final int n;
  final Float64List _cos, _sin;
  final Int32List _rev;

  _Fft(this.n)
    : _cos = Float64List(n ~/ 2),
      _sin = Float64List(n ~/ 2),
      _rev = Int32List(n) {
    for (var i = 0; i < n ~/ 2; i++) {
      _cos[i] = cos(2 * pi * i / n);
      _sin[i] = -sin(2 * pi * i / n);
    }
    final bits = (log(n) / ln2).round();
    for (var i = 0; i < n; i++) {
      var r = 0, v = i;
      for (var b = 0; b < bits; b++) {
        r = (r << 1) | (v & 1);
        v >>= 1;
      }
      _rev[i] = r;
    }
  }

  void transform(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      final j = _rev[i];
      if (j > i) {
        final tr = re[i], ti = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = tr;
        im[j] = ti;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, step = n ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _cos[k * step], wi = _sin[k * step];
          final a = start + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi;
          final xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }

  void inverse(Float64List re, Float64List im) {
    for (var i = 0; i < n; i++) {
      im[i] = -im[i];
    }
    transform(re, im);
    final s = 1 / n;
    for (var i = 0; i < n; i++) {
      re[i] *= s;
      im[i] = -im[i] * s;
    }
  }
}
