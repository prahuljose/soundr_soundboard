import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/reverse_score.dart';

void main() {
  final phrase = speechLike(bananaPancakes);
  int score(List<double> attempt) => ReverseScore.compare(phrase, attempt);

  group('a good copy scores high', () {
    test('identical audio', () {
      expect(score(phrase), greaterThanOrEqualTo(95));
      expect(score(List.of(phrase)), 100);
    });

    test('said 15% slower or faster', () {
      expect(score(speechLike(bananaPancakes, stretch: 1.15)), greaterThanOrEqualTo(70));
      expect(score(speechLike(bananaPancakes, stretch: 0.85)), greaterThanOrEqualTo(70));
    });

    test('with mild background noise', () {
      expect(score(speechLike(bananaPancakes, noise: 0.01, seed: 3)), greaterThanOrEqualTo(70));
      expect(score(speechLike(bananaPancakes, noise: 0.02, seed: 4)), greaterThanOrEqualTo(70));
    });

    test('stretched and noisy together', () {
      expect(score(speechLike(bananaPancakes, stretch: 1.15, noise: 0.01, seed: 4)),
          greaterThanOrEqualTo(70));
      expect(score(speechLike(bananaPancakes, stretch: 0.85, noise: 0.01, seed: 8)),
          greaterThanOrEqualTo(70));
    });

    test('quieter or louder doesn\'t matter', () {
      expect(score([for (final v in phrase) v * 0.25]), greaterThanOrEqualTo(90));
      expect(score([for (final v in phrase) v * 1.5]), greaterThanOrEqualTo(90));
    });

    test('a different voice saying it the same way still does well', () {
      expect(score(speechLike(bananaPancakes, pitch: 1.3, formants: 1.08, stretch: 1.1, seed: 5)),
          greaterThanOrEqualTo(70));
    });

    test('extra silence around the attempt is ignored', () {
      final padded = [...List.filled(44100, 0.0), ...phrase, ...List.filled(30000, 0.0)];
      expect(score(padded), greaterThanOrEqualTo(95));
    });
  });

  group('something else scores low', () {
    test('a different phrase', () {
      expect(score(speechLike(helloThere)), lessThanOrEqualTo(40));
      expect(score(speechLike(redLorry)), lessThanOrEqualTo(40));
    });

    test('the attempt played the wrong way round', () {
      expect(score(ReverseScore.reverse(phrase)), lessThanOrEqualTo(40));
    });

    test('noise', () {
      expect(score(whiteNoise(2.5)), lessThanOrEqualTo(40));
    });

    test('a steady tone', () {
      expect(score([for (var i = 0; i < 88200; i++) 0.4 * sin(2 * pi * 220 * i / 44100)]),
          lessThanOrEqualTo(40));
    });

    test('silence, or next to nothing, is 0', () {
      expect(score(List.filled(88200, 0.0)), 0);
      expect(score(whiteNoise(2, amp: 0.001)), 0);
      expect(score(whiteNoise(0.05)), 0);
      expect(ReverseScore.compare(List.filled(88200, 0.0), phrase), 0);
      expect(score(const []), 0);
    });

    test('a much longer recording', () {
      expect(score(speechLike(longPhrase)), lessThanOrEqualTo(40));
    });
  });

  test('scores are symmetric enough and always in range', () {
    final other = speechLike(bananaPancakes, stretch: 1.1, noise: 0.01);
    final ab = ReverseScore.compare(phrase, other);
    final ba = ReverseScore.compare(other, phrase);
    expect((ab - ba).abs(), lessThanOrEqualTo(5));
    for (final d in [0.0, 0.2, 0.5, 1.0, 3.0, 100.0]) {
      expect(ReverseScore.scoreForDistance(d), inInclusiveRange(0, 100));
    }
    expect(ReverseScore.scoreForDistance(0.6), greaterThan(ReverseScore.scoreForDistance(0.8)));
  });

  test('two 6 s clips score quickly', () {
    List<double> sixSeconds(double stretch) {
      final s = speechLike(longPhrase, stretch: stretch);
      return [...s, ...List.filled(max(0, 6 * 44100 - s.length), 0.0)].sublist(0, 6 * 44100);
    }

    final a = Float64List.fromList(sixSeconds(1.15));
    final b = Float64List.fromList(sixSeconds(1.25));
    ReverseScore.compare(a, b); // warm up the JIT
    final sw = Stopwatch()..start();
    final s = ReverseScore.compare(a, b);
    sw.stop();
    // ignore: avoid_print
    print('6 s vs 6 s: ${sw.elapsedMilliseconds} ms (JIT), score $s');
    expect(sw.elapsedMilliseconds, lessThan(150)); // release builds are faster
  });

  group('helpers', () {
    test('reverse', () {
      expect(ReverseScore.reverse([1, 2, 3]), [3, 2, 1]);
      expect(ReverseScore.reverse(const []), isEmpty);
    });

    test('trimSilence keeps the sound plus a little padding', () {
      final clip = [...List.filled(22050, 0.0), ...List.filled(4410, 0.5), ...List.filled(22050, 0.0)];
      final t = ReverseScore.trimSilence(clip, padSeconds: 0.05);
      expect(t.length, closeTo(4410 + 2 * 2205, 450));
      expect(ReverseScore.trimSilence(List.filled(44100, 0.0)), isEmpty);
      expect(ReverseScore.soundSeconds(clip), closeTo(0.1, 0.011));
    });

    test('peakEnvelope', () {
      final env = peakEnvelope([0, 0.5, 0, 0, 0.125, 0, 0, 0], 4);
      expect(env, [1.0, 0.0, 0.5, 0.0]);
      expect(peakEnvelope(const [], 3), [0, 0, 0]);
    });

    test('stars and messages', () {
      expect([0, 54, 55, 79, 80, 100].map(ReverseScore.stars), [1, 1, 2, 2, 3, 3]);
      expect(ReverseScore.message(97), 'Spot on!');
      expect(ReverseScore.message(60), 'Pretty close');
      expect(ReverseScore.message(10), 'Keep practising');
    });
  });
}

// ── Speech-like test signals (also used by the screen and golden tests) ──

/// One syllable of a speech-like test signal.
class Syl {
  final double seconds; // voiced part
  final double f0From, f0To; // pitch glide, Hz
  final double f1, f2; // formants, Hz (vowel colour)
  final bool consonant; // noisy burst before the vowel
  final double gap; // silence after, seconds

  const Syl(this.seconds, this.f0From, this.f0To, this.f1, this.f2,
      {this.consonant = false, this.gap = 0.06});
}

const bananaPancakes = [
  Syl(0.16, 170, 185, 700, 1200, consonant: true, gap: 0.02),
  Syl(0.18, 190, 210, 800, 1300, consonant: true, gap: 0.02),
  Syl(0.24, 200, 160, 650, 1100, consonant: true, gap: 0.12),
  Syl(0.22, 180, 200, 750, 1700, consonant: true, gap: 0.03),
  Syl(0.30, 190, 140, 450, 2100, consonant: true, gap: 0.05),
];

const helloThere = [
  Syl(0.14, 150, 160, 550, 1900, gap: 0.01),
  Syl(0.34, 165, 120, 450, 900, consonant: true, gap: 0.15),
  Syl(0.40, 130, 170, 400, 2300, consonant: true, gap: 0.05),
];

const redLorry = [
  Syl(0.20, 220, 230, 550, 1800, gap: 0.04),
  Syl(0.22, 240, 200, 500, 900, consonant: true, gap: 0.03),
  Syl(0.16, 210, 250, 300, 2400, gap: 0.10),
  Syl(0.22, 230, 230, 550, 1800, consonant: true, gap: 0.02),
  Syl(0.22, 250, 210, 500, 900, gap: 0.03),
  Syl(0.24, 220, 180, 300, 2400, consonant: true, gap: 0.05),
];

final longPhrase = [
  for (var i = 0; i < 12; i++)
    Syl(0.22 + 0.05 * (i % 3), 160 + 10.0 * (i % 5), 200 - 12.0 * (i % 4),
        400 + 90.0 * (i % 6), 900 + 260.0 * (i % 7),
        consonant: i.isEven, gap: 0.04 + 0.03 * (i % 2)),
];

/// A voice-like test signal: harmonic vowels with gliding pitch and two
/// formants, fast attacks and slower releases, noisy consonant bursts, and
/// a little room noise. [stretch] changes the timing without changing the
/// pitch (like saying it faster or slower); [pitch] and [formants] scale
/// the voice (like a different speaker).
List<double> speechLike(
  List<Syl> syls, {
  double stretch = 1,
  double pitch = 1,
  double formants = 1,
  double noise = 0.002,
  int seed = 1,
  int sampleRate = 44100,
}) {
  final rnd = Random(seed);
  final out = <double>[];
  void silence(double s) => out.addAll(List.filled((s * sampleRate).round(), 0.0));
  silence(0.25);
  for (final s in syls) {
    if (s.consonant) {
      final n = (0.045 * stretch * sampleRate).round();
      var prev = 0.0;
      for (var i = 0; i < n; i++) {
        final w = rnd.nextDouble() * 2 - 1;
        // First difference of white noise: hissy, like "s"/"t"/"p".
        out.add((w - prev) * 0.18 * sin(pi * i / n));
        prev = w;
      }
    }
    final n = (s.seconds * stretch * sampleRate).round();
    final attack = 0.02 * sampleRate, release = 0.08 * sampleRate * stretch;
    final f1 = s.f1 * formants, f2 = s.f2 * formants;
    final phases = List<double>.filled(40, 0);
    for (var i = 0; i < n; i++) {
      final t = i / n;
      final f0 = (s.f0From + (s.f0To - s.f0From) * t) * pitch;
      var v = 0.0;
      for (var k = 1; k < 40; k++) {
        final f = k * f0;
        if (f > 6000) break;
        phases[k] += 2 * pi * f / sampleRate;
        final g = 1 / (1 + pow((f - f1) / 120, 2)) +
            0.6 / (1 + pow((f - f2) / 200, 2)) +
            0.02;
        v += g / sqrt(k) * sin(phases[k]);
      }
      var env = 1.0;
      if (i < attack) env = i / attack;
      if (n - i < release) env *= (n - i) / release;
      out.add(v * env * 0.12);
    }
    silence(s.gap * stretch);
  }
  silence(0.3);
  var peak = 0.0;
  for (final v in out) {
    peak = max(peak, v.abs());
  }
  return [
    for (final v in out) v / peak * 0.6 + (rnd.nextDouble() * 2 - 1) * noise,
  ];
}

List<double> whiteNoise(double seconds, {double amp = 0.3, int seed = 7}) {
  final rnd = Random(seed);
  return List.generate(
      (seconds * 44100).round(), (_) => (rnd.nextDouble() * 2 - 1) * amp);
}
