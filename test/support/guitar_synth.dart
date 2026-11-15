import 'dart:math';

/// A plucked string for tests: harmonics with string inharmonicity, a weak
/// fundamental on low notes (as from a phone mic), faster decay for higher
/// harmonics, a noisy pick attack and a little background noise.
///
/// [fundamentalGain] scales the first harmonic: by default 0.35 below
/// 120 Hz and 1 above. Phone mics roll off steeply under ~80 Hz, so bass
/// tests pass 0.1 or less (0 = fundamental missing altogether).
///
/// [sustain] stretches the decay: a bass string rings about twice as long
/// as a guitar's (2), a nylon ukulele string rather less (below 1).
List<double> pluckedString(
  double hz, {
  double seconds = 1.5,
  int sampleRate = 44100,
  double amplitude = 0.5,
  int seed = 3,
  double? fundamentalGain,
  double sustain = 1,
}) {
  final rnd = Random(seed);
  final n = (seconds * sampleRate).round();
  final out = List<double>.filled(n, 0);
  // Wound strings are a little stiffer (more inharmonic) than plain ones.
  final b = hz < 200 ? 1.2e-4 : 0.6e-4;
  final gain1 = fundamentalGain ?? (hz < 120 ? 0.35 : 1.0);
  for (var k = 1; k <= 14; k++) {
    final fk = k * hz * sqrt(1 + b * k * k);
    if (fk > sampleRate / 2.2) break;
    var amp = 1 / k;
    if (k == 1) amp *= gain1; // small speakers/mics roll off lows
    if (k == 2) amp *= 1.3;
    final decay = (1.2 + 0.9 * k) / sustain; // per second
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

/// A bowed string: a steady sawtooth-like tone (harmonics at 1/k) that
/// swells in, with a little bow noise.
List<double> bowedString(
  double hz, {
  double seconds = 1.5,
  int sampleRate = 44100,
  double amplitude = 0.4,
  int seed = 5,
}) {
  final rnd = Random(seed);
  final n = (seconds * sampleRate).round();
  final out = List<double>.filled(n, 0);
  for (var k = 1; k <= 16; k++) {
    final fk = k * hz;
    if (fk > sampleRate / 2.2) break;
    final phase = rnd.nextDouble() * 2 * pi;
    final w = 2 * pi * fk / sampleRate;
    for (var i = 0; i < n; i++) {
      out[i] += sin(w * i + phase) / k;
    }
  }
  var peak = 0.0;
  for (final v in out) {
    peak = max(peak, v.abs());
  }
  final swell = (0.08 * sampleRate).round();
  for (var i = 0; i < n; i++) {
    final env = i < swell ? i / swell : 1.0;
    out[i] =
        out[i] / peak * amplitude * env + (rnd.nextDouble() * 2 - 1) * 0.01;
  }
  return out;
}
