import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/pitch_detector.dart';
import 'package:soundr_soundboard/services/voice_effects.dart';

const sr = 44100;

Float64List tone(double hz, {double seconds = 1.5, double amp = 0.5}) =>
    Float64List.fromList(
      List.generate(
        (seconds * sr).round(),
        (i) => amp * sin(2 * pi * hz * i / sr),
      ),
    );

/// A vowel-ish voice: a 140 Hz glottal buzz (decaying harmonics) with a
/// slow pitch drift and a syllable-like amplitude envelope.
Float64List voice({double seconds = 2}) {
  final n = (seconds * sr).round();
  final out = Float64List(n);
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    final f0 = 140 * (1 + 0.05 * sin(2 * pi * 0.7 * t));
    phase += 2 * pi * f0 / sr;
    var v = 0.0;
    for (var k = 1; k <= 25; k++) {
      // Rough formants near 700 Hz and 1200 Hz.
      final f = k * f0;
      final formant =
          1 / (1 + pow((f - 700) / 250, 2)) +
          0.6 / (1 + pow((f - 1200) / 300, 2));
      v += (0.15 / k + formant) * sin(k * phase);
    }
    final env = 0.5 + 0.5 * sin(2 * pi * 2.5 * t).abs();
    out[i] = 0.12 * v * env;
  }
  return out;
}

double medianPitch(Float64List x) {
  final hz = <double>[];
  final d = PitchDetector(
    onReading: (r) {
      if (r != null) hz.add(r.hz);
    },
  );
  d.addSamples(x);
  expect(hz, isNotEmpty, reason: 'no pitch found');
  hz.sort();
  return hz[hz.length ~/ 2];
}

double cents(double hz, num target) => 1200 * log(hz / target) / ln2;

/// Amplitude of the [hz] component in [x] (Goertzel over the middle).
double magnitudeAt(Float64List x, double hz) {
  final from = x.length ~/ 4, to = x.length * 3 ~/ 4;
  final w = 2 * pi * hz / sr;
  final coeff = 2 * cos(w);
  var s1 = 0.0, s2 = 0.0;
  for (var i = from; i < to; i++) {
    final s = x[i] + coeff * s1 - s2;
    s2 = s1;
    s1 = s;
  }
  final power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
  return sqrt(max(0.0, power)) / (to - from);
}

double rms(Float64List x, int from, int to) {
  var s = 0.0;
  for (var i = from; i < to; i++) {
    s += x[i] * x[i];
  }
  return sqrt(s / max(1, to - from));
}

double db(double ratio) => 20 * log(ratio) / ln10;

void main() {
  group('pitch shift', () {
    test('+12 semitones doubles the pitch and keeps the duration', () {
      final x = tone(220);
      final y = VoiceEffects.pitchShift(x, 12);
      expect(y.length, closeTo(x.length, x.length * 0.05));
      expect(cents(medianPitch(y), 440).abs(), lessThan(15));
    });

    test('−12 semitones halves the pitch and keeps the duration', () {
      final x = tone(220);
      final y = VoiceEffects.pitchShift(x, -12);
      expect(y.length, closeTo(x.length, x.length * 0.05));
      expect(cents(medianPitch(y), 110).abs(), lessThan(15));
    });

    test('+5 and −5 semitones land on the right notes', () {
      final x = tone(220);
      expect(
        cents(
          medianPitch(VoiceEffects.pitchShift(x, 5)),
          220 * pow(2, 5 / 12),
        ).abs(),
        lessThan(15),
      );
      expect(
        cents(
          medianPitch(VoiceEffects.pitchShift(x, -5)),
          220 * pow(2, -5 / 12),
        ).abs(),
        lessThan(15),
      );
    });

    test('works on a voice-like signal too', () {
      final y = VoiceEffects.pitchShift(voice(), 7);
      final measured = medianPitch(y);
      // The source drifts ±5% around 140 Hz.
      expect(cents(measured, 140 * pow(2, 7 / 12)).abs(), lessThan(100));
    });
  });

  test('speed ×2 halves the length and doubles the pitch', () {
    final x = tone(220);
    final y = VoiceEffects.changeSpeed(x, 2);
    expect(y.length, x.length ~/ 2);
    expect(cents(medianPitch(y), 440).abs(), lessThan(10));
  });

  test('reverse is exact', () {
    final x = voice(seconds: 0.5);
    final y = VoiceEffects.reverse(x);
    expect(y.length, x.length);
    for (var i = 0; i < x.length; i++) {
      expect(y[i], x[x.length - 1 - i]);
    }
    expect(VoiceEffects.reverse(y), x);
  });

  test('telephone keeps 1 kHz and strongly cuts 100 Hz and 8 kHz', () {
    final x = Float64List(sr * 2);
    for (var i = 0; i < x.length; i++) {
      final t = i / sr;
      x[i] =
          0.25 *
          (sin(2 * pi * 100 * t) +
              sin(2 * pi * 1000 * t) +
              sin(2 * pi * 8000 * t));
    }
    final y = VoiceEffects.telephone(x);
    final mid = magnitudeAt(y, 1000);
    expect(db(magnitudeAt(y, 100) / mid), lessThan(-25));
    expect(db(magnitudeAt(y, 8000) / mid), lessThan(-25));
  });

  test('echo repeats the sound about one delay later', () {
    // A 60 ms burst, then silence.
    final x = Float64List(sr);
    for (var i = 0; i < sr * 0.06; i++) {
      x[i] = 0.6 * sin(2 * pi * 500 * i / sr);
    }
    final y = VoiceEffects.echo(x, delayMs: 250, feedback: 0.45, mix: 0.6);
    expect(y.length, greaterThan(x.length));
    int at(double s) => (s * sr).round();
    final burst = rms(y, 0, at(0.06));
    final gap = rms(y, at(0.1), at(0.24));
    final first = rms(y, at(0.25), at(0.31));
    final second = rms(y, at(0.5), at(0.56));
    expect(gap, lessThan(burst * 0.01));
    expect(first, greaterThan(burst * 0.3));
    expect(second, greaterThan(burst * 0.08));
    expect(second, lessThan(first));
  });

  test('stadium and echo let the tail ring past the end', () {
    final x = voice(seconds: 1);
    for (final e in [VoiceEffect.echo, VoiceEffect.stadium]) {
      final y = VoiceEffects.apply(e, x);
      expect(y.length, greaterThan(x.length + sr * 0.3), reason: e.name);
      expect(
        rms(y, x.length, x.length + sr ~/ 10),
        greaterThan(0.005),
        reason: e.name,
      );
    }
  });

  group('every effect', () {
    final x = voice();
    for (final e in VoiceEffect.values) {
      test('${e.name}: peaks ≤ 1, ~0.9, not silent, no NaN, sane length', () {
        final sw = Stopwatch()..start();
        final y = VoiceEffects.apply(e, x);
        sw.stop();
        var peak = 0.0;
        for (final v in y) {
          expect(v.isFinite, isTrue);
          peak = max(peak, v.abs());
        }
        expect(peak, lessThanOrEqualTo(1.0));
        expect(peak, closeTo(VoiceEffects.targetPeak, 0.02));
        expect(rms(y, 0, y.length), greaterThan(0.03));
        expect(y.length, inInclusiveRange(x.length * 0.8, x.length + sr * 3));
        // 2 s of audio, JIT, debug — a loose bound that catches runaway costs.
        expect(
          sw.elapsedMilliseconds,
          lessThan(1500),
          reason: '${e.name} took ${sw.elapsedMilliseconds} ms',
        );
      });
    }

    test('silence in → silence out', () {
      final silent = Float64List(sr);
      for (final e in VoiceEffect.values) {
        final y = VoiceEffects.apply(e, silent);
        expect(y.every((v) => v == 0), isTrue, reason: e.name);
      }
      expect(VoiceEffects.apply(VoiceEffect.robot, Float64List(0)), isEmpty);
    });

    test('quiet input is levelled up', () {
      final quiet = Float64List.fromList(x.map((v) => v * 0.05).toList());
      final y = VoiceEffects.apply(VoiceEffect.normal, quiet);
      var peak = 0.0;
      for (final v in y) {
        peak = max(peak, v.abs());
      }
      expect(peak, closeTo(0.9, 0.02));
    });

    test('deterministic', () {
      final a = VoiceEffects.apply(VoiceEffect.radio, x);
      final b = VoiceEffects.apply(VoiceEffect.radio, x);
      expect(a, b);
    });
  });

  test('robot buzzes at a fixed pitch', () {
    final y = VoiceEffects.robot(voice());
    expect(cents(medianPitch(y), 44100 / 400).abs(), lessThan(30));
  });

  test('renders 15 s of every effect in reasonable time (JIT)', () {
    final x = voice(seconds: 15);
    final times = <String, int>{};
    for (final e in VoiceEffect.values) {
      final sw = Stopwatch()..start();
      VoiceEffects.apply(e, x);
      times[e.name] = sw.elapsedMilliseconds;
    }
    // ignore: avoid_print
    print('15 s render times (ms, JIT): $times');
    for (final t in times.values) {
      expect(t, lessThan(3000));
    }
  });
}
