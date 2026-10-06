import 'dart:math';
import 'dart:typed_data';

/// Scoring for the Reverse Audio Challenge: how much the player's attempt,
/// once reversed, sounds like the phrase they first recorded.
///
/// It's a fun, rough score rather than speech recognition. Both clips are
/// trimmed of silence and cut into 20 ms frames (10 ms apart); each frame
/// gets a loudness value (relative to the clip's loudest moment, so mic
/// distance doesn't matter), a coarse spectral shape (energy in nine
/// 2/3-octave bands, minus their mean, so it describes *which* sounds rather
/// than how loud) and a zero-crossing rate (hiss vs. voice). The two frame
/// sequences are aligned with dynamic time warping, so saying it faster or
/// slower is fine, and the length-normalised distance is mapped to 0–100.
class ReverseScore {
  ReverseScore._();

  // Analysis runs at a third of 44.1 kHz (14.7 kHz): voices live below
  // ~7 kHz, and it's three times less work.
  static const _decimate = 3;
  static const _bandCentres = [
    110.0, 175.0, 277.0, 440.0, 698.0, 1109.0, 1760.0, 2794.0, 4435.0,
  ];
  static const _bandQ = 2.16; // 2/3 octave

  /// Frames quieter than this (dB below the clip's peak) count as silence
  /// when trimming; the absolute floor catches a clip that's all hiss.
  static const _trimBelowPeakDb = 30.0;
  static const _absoluteFloorDb = -50.0;

  /// 0–100: how closely [reversedAttempt] matches [original].
  ///
  /// Clips with no sound in them, or less than ~0.15 s of it, score 0.
  static int compare(
    List<double> original,
    List<double> reversedAttempt, {
    int sampleRate = 44100,
  }) {
    final d = distance(original, reversedAttempt, sampleRate: sampleRate);
    if (d == null) return 0;
    return scoreForDistance(d);
  }

  /// Maps a [distance] to 0–100. Distances up to ~0.3 are the noise floor
  /// of a near-perfect copy; around 1.0 the clips have little in common.
  static int scoreForDistance(double d) {
    const tolerance = 0.25, scale = 0.55;
    final x = max(0.0, d - tolerance) / scale;
    return (100 * exp(-x * x)).round().clamp(0, 100);
  }

  /// Length-normalised DTW distance between the two clips' features, or
  /// null when either has (almost) no sound.
  static double? distance(
    List<double> a,
    List<double> b, {
    int sampleRate = 44100,
  }) {
    final fa = _Features.of(a, sampleRate);
    final fb = _Features.of(b, sampleRate);
    if (fa == null || fb == null) return null;
    var d = _dtw(fa, fb);
    // Very different lengths can't be the same phrase, whatever the warp.
    final ratio = max(fa.length, fb.length) / min(fa.length, fb.length);
    if (ratio > 1.6) d += (ratio - 1.6) * 0.6;
    return d;
  }

  // ── Helpers for the screen ──────────────────────────────────────────────

  /// [samples] back to front.
  static Float64List reverse(List<double> samples) {
    final n = samples.length;
    final out = Float64List(n);
    for (var i = 0; i < n; i++) {
      out[i] = samples[n - 1 - i];
    }
    return out;
  }

  /// [samples] without leading and trailing silence, keeping [padSeconds]
  /// either side. Empty when there's no sound at all.
  static Float64List trimSilence(
    List<double> samples, {
    int sampleRate = 44100,
    double padSeconds = 0.08,
  }) {
    final win = max(1, sampleRate ~/ 100); // 10 ms
    final frames = samples.length ~/ win;
    if (frames == 0) return Float64List(0);
    final db = Float64List(frames);
    var peak = -200.0;
    for (var f = 0; f < frames; f++) {
      var sum = 0.0;
      for (var i = f * win; i < (f + 1) * win; i++) {
        sum += samples[i] * samples[i];
      }
      db[f] = 10 * log(sum / win + 1e-12) / ln10;
      peak = max(peak, db[f]);
    }
    if (peak < _absoluteFloorDb) return Float64List(0);
    final gate = max(peak - _trimBelowPeakDb - 6, _absoluteFloorDb);
    var first = 0, last = frames - 1;
    while (first < frames && db[first] < gate) {
      first++;
    }
    while (last > first && db[last] < gate) {
      last--;
    }
    final pad = (padSeconds * sampleRate).round();
    final start = max(0, first * win - pad);
    final end = min(samples.length, (last + 1) * win + pad);
    return Float64List.fromList(samples.sublist(start, end));
  }

  /// Seconds of sound in [samples] once silence is trimmed.
  static double soundSeconds(List<double> samples, {int sampleRate = 44100}) =>
      trimSilence(samples, sampleRate: sampleRate, padSeconds: 0).length /
      sampleRate;

  /// 1–3 stars for a score.
  static int stars(int score) => score >= 80 ? 3 : (score >= 55 ? 2 : 1);

  /// A short verdict for a score.
  static String message(int score) {
    if (score >= 90) return 'Spot on!';
    if (score >= 75) return 'Nailed it';
    if (score >= 55) return 'Pretty close';
    if (score >= 35) return 'Getting there';
    return 'Keep practising';
  }

  // ── DTW ─────────────────────────────────────────────────────────────────

  static double _dtw(_Features a, _Features b) {
    final n = a.length, m = b.length;
    // Sakoe–Chiba band around the (stretched) diagonal.
    final band = max(12, (0.3 * max(n, m)).round());
    const inf = double.infinity;
    var prev = Float64List(m + 1)..fillRange(0, m + 1, inf);
    var cur = Float64List(m + 1);
    prev[0] = 0;
    for (var i = 1; i <= n; i++) {
      cur.fillRange(0, m + 1, inf);
      final centre = i * m / n;
      final lo = max(1, (centre - band).floor());
      final hi = min(m, (centre + band).ceil());
      for (var j = lo; j <= hi; j++) {
        final d = a.dist(i - 1, b, j - 1);
        // Symmetric step pattern: a diagonal step costs 2d, so stretching
        // one side isn't cheaper than matching frame for frame.
        final diag = prev[j - 1] + 2 * d;
        final up = prev[j] + d;
        final left = cur[j - 1] + d;
        cur[j] = min(diag, min(up, left));
      }
      final t = prev;
      prev = cur;
      cur = t;
    }
    final total = prev[m];
    if (total.isInfinite) return 10;
    return total / (n + m);
  }
}

/// Per-frame features of one clip, flattened: [_dims] values per frame.
class _Features {
  static const _dims = 2 + 9; // loudness, zcr, 9 band shapes
  final Float64List v;
  final Float64List activity; // 0..1 per frame, how far above the gaps
  final int length;

  _Features(this.v, this.activity, this.length);

  /// Weighted L1 distance between frame [i] of this and frame [j] of [o].
  double dist(int i, _Features o, int j) {
    final p = i * _dims, q = j * _dims;
    final ov = o.v;
    // Loudness always counts (the rhythm of the phrase); spectral shape
    // only where both frames have sound in them.
    final loud = (v[p] - ov[q]).abs();
    final act = sqrt(activity[i] * o.activity[j]);
    if (act == 0) return loud;
    var shape = 0.0;
    for (var k = 2; k < _dims; k++) {
      shape += (v[p + k] - ov[q + k]).abs();
    }
    final zcr = (v[p + 1] - ov[q + 1]).abs();
    return loud + act * (shape / 9 + zcr);
  }

  static _Features? of(List<double> raw, int sampleRate) {
    final trimmed = ReverseScore.trimSilence(raw, sampleRate: sampleRate, padSeconds: 0);
    if (trimmed.length < sampleRate * 0.15) return null;

    // Decimate (averaging is a gentle anti-alias filter) and remove DC.
    const dec = ReverseScore._decimate;
    final rate = sampleRate / dec;
    final n = trimmed.length ~/ dec;
    final x = Float64List(n);
    var mean = 0.0;
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      for (var k = 0; k < dec; k++) {
        s += trimmed[i * dec + k];
      }
      x[i] = s / dec;
      mean += x[i];
    }
    mean /= n;
    for (var i = 0; i < n; i++) {
      x[i] -= mean;
    }

    final block = (rate / 100).round(); // 10 ms
    final blocks = n ~/ block;
    if (blocks < 4) return null;
    const bands = 9;
    final energy = Float64List(blocks);
    final zc = Float64List(blocks);
    final bandE = Float64List(blocks * bands);

    for (var i = 0; i < blocks * block; i++) {
      final s = x[i];
      energy[i ~/ block] += s * s;
      if (i > 0 && (s >= 0) != (x[i - 1] >= 0)) zc[i ~/ block] += 1;
    }
    // One band-pass biquad (RBJ, 0 dB peak) per band.
    for (var b = 0; b < bands; b++) {
      final w0 = 2 * pi * ReverseScore._bandCentres[b] / rate;
      final alpha = sin(w0) / (2 * ReverseScore._bandQ);
      final a0 = 1 + alpha;
      final b0 = alpha / a0, b2 = -alpha / a0;
      final a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0;
      var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;
      for (var i = 0; i < blocks * block; i++) {
        final s = x[i];
        final y = b0 * s + b2 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = s;
        y2 = y1;
        y1 = y;
        bandE[(i ~/ block) * bands + b] += y * y;
      }
    }

    // 20 ms frames, 10 ms apart: pairs of blocks.
    final frames = blocks - 1;
    final v = Float64List(frames * _dims);
    final activity = Float64List(frames);
    final loud = Float64List(frames);
    var peak = -200.0;
    for (var f = 0; f < frames; f++) {
      final e = (energy[f] + energy[f + 1]) / (2 * block);
      loud[f] = 10 * log(e + 1e-12) / ln10;
      peak = max(peak, loud[f]);
    }
    // Loudness is measured down to the clip's own noise floor (its quietest
    // tenth), so a hissy room doesn't fill the gaps between words.
    final sorted = Float64List.fromList(loud)..sort();
    final floor = (sorted[frames ~/ 10] - peak + 3).clamp(-40.0, -20.0);
    const db = 10 / ln10;
    for (var f = 0; f < frames; f++) {
      final rel = ((loud[f] - peak - floor) / -floor).clamp(0.0, 1.0);
      final o = f * _dims;
      v[o] = rel * 5;
      v[o + 1] = (zc[f] + zc[f + 1]) / (2 * block) * 6; // ~0..3
      activity[f] = ((rel - 0.25) / 0.375).clamp(0.0, 1.0);
      var sum = 0.0;
      for (var b = 0; b < bands; b++) {
        final be = bandE[f * bands + b] + bandE[(f + 1) * bands + b];
        final l = db * log(be / (2 * block) + 1e-12);
        v[o + 2 + b] = l;
        sum += l;
      }
      final avg = sum / bands;
      for (var b = 0; b < bands; b++) {
        // Shape in units of 8 dB, capped so a single empty band can't
        // dominate.
        v[o + 2 + b] = ((v[o + 2 + b] - avg) / 8).clamp(-4.0, 4.0);
      }
    }
    return _Features(v, activity, frames);
  }
}

/// [bars] peak levels in 0..1 for drawing [samples] as a waveform; the
/// loudest bar is 1, and quiet parts are lifted a little to stay visible.
List<double> peakEnvelope(List<double> samples, int bars) {
  if (samples.isEmpty || bars <= 0) return List.filled(max(0, bars), 0);
  final out = List<double>.filled(bars, 0);
  var top = 0.0;
  for (var b = 0; b < bars; b++) {
    final start = b * samples.length ~/ bars;
    final end = max(start + 1, (b + 1) * samples.length ~/ bars);
    var p = 0.0;
    for (var i = start; i < end && i < samples.length; i++) {
      final v = samples[i].abs();
      if (v > p) p = v;
    }
    out[b] = p;
    top = max(top, p);
  }
  if (top <= 0) return out;
  for (var b = 0; b < bars; b++) {
    out[b] = sqrt(out[b] / top);
  }
  return out;
}
