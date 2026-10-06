import 'dart:math';

/// A plucked guitar string for tests: harmonics with string inharmonicity,
/// a weak fundamental on low notes (as from a phone mic), faster decay for
/// higher harmonics, a noisy pick attack and a little background noise.
List<double> pluckedString(
  double hz, {
  double seconds = 1.5,
  int sampleRate = 44100,
  double amplitude = 0.5,
  int seed = 3,
}) {
  final rnd = Random(seed);
  final n = (seconds * sampleRate).round();
  final out = List<double>.filled(n, 0);
  // Wound strings are a little stiffer (more inharmonic) than plain ones.
  final b = hz < 200 ? 1.2e-4 : 0.6e-4;
  final weakFundamental = hz < 120;
  for (var k = 1; k <= 14; k++) {
    final fk = k * hz * sqrt(1 + b * k * k);
    if (fk > sampleRate / 2.2) break;
    var amp = 1 / k;
    if (k == 1 && weakFundamental) amp *= 0.35; // small speakers/mics roll off lows
    if (k == 2) amp *= 1.3;
    final decay = 1.2 + 0.9 * k; // per second
    final phase = rnd.nextDouble() * 2 * pi;
    final w = 2 * pi * fk / sampleRate;
    for (var i = 0; i < n; i++) {
      out[i] += amp * exp(-decay * i / sampleRate) * sin(w * i + phase);
    }
  }
  var peak = 0.0;
  for (final v in out) {
    peak = max(peak, v.abs());
  }
  final attack = (0.02 * sampleRate).round();
  for (var i = 0; i < n; i++) {
    var v = out[i] / peak * amplitude;
    if (i < attack) v += (rnd.nextDouble() * 2 - 1) * 0.3 * (1 - i / attack);
    v += (rnd.nextDouble() * 2 - 1) * 0.004; // room noise
    out[i] = v;
  }
  return out;
}

List<double> sine(double hz, {double seconds = 1, int sampleRate = 44100, double amp = 0.5}) =>
    List.generate((seconds * sampleRate).round(),
        (i) => amp * sin(2 * pi * hz * i / sampleRate));
