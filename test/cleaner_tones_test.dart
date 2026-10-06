import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/cleaner_tones.dart';
import 'package:soundr_soundboard/services/pitch_detector.dart';
import 'package:soundr_soundboard/services/wav.dart';

const _rate = CleanerTones.sampleRate;

/// Pitch readings (Hz) over the whole program.
List<double> pitches(Float64List s, {double maxHz = 1400}) {
  final out = <double>[];
  final d = PitchDetector(
    sampleRate: _rate,
    maxHz: maxHz,
    hopSize: 1024,
    minClarity: 0.8,
    onReading: (r) {
      if (r != null) out.add(r.hz);
    },
  );
  d.addSamples(s);
  return out;
}

/// Frequency from zero crossings in [s] between [from] and [to] seconds.
double zcrHz(Float64List s, double from, double to) {
  final a = (from * _rate).round(), b = (to * _rate).round();
  var crossings = 0;
  for (var i = a + 1; i < b; i++) {
    if ((s[i - 1] < 0) != (s[i] < 0)) crossings++;
  }
  return crossings / 2 / (to - from);
}

void checkBasics(Float64List s, Duration length) {
  expect(s.length, _rate * length.inSeconds);
  var peak = 0.0;
  for (final v in s) {
    expect(v.isFinite, isTrue);
    peak = max(peak, v.abs());
  }
  expect(peak, lessThanOrEqualTo(1.0));
  expect(peak, greaterThan(0.9)); // loud: close to full scale
  // Silent at both ends, and the 20 ms fades are smooth (no click).
  expect(s.first.abs(), lessThan(1e-6));
  expect(s.last.abs(), lessThan(1e-6));
  final fade = (0.02 * _rate).round();
  for (var i = 0; i < fade; i++) {
    final env = CleanerTones.peak * (0.5 - 0.5 * cos(pi * i / fade)) + 1e-4;
    expect(s[i].abs(), lessThanOrEqualTo(env));
    expect(s[s.length - 1 - i].abs(), lessThanOrEqualTo(env));
  }
}

void main() {
  group('water', () {
    const length = Duration(seconds: 30);
    final s = CleanerTones.program(CleanMode.water, length);

    test('exact length, silent ends, no clipping or NaN', () {
      checkBasics(s, length);
    });

    test('pitch stays around 165 Hz (160–180)', () {
      final p = pitches(s);
      expect(p.length, greaterThan(100));
      for (final hz in p) {
        expect(hz, inInclusiveRange(157, 183));
      }
      final mean = p.reduce((a, b) => a + b) / p.length;
      expect(mean, closeTo(170, 5));
      // The slow wobble actually moves it.
      expect(p.reduce(max) - p.reduce(min), greaterThan(12));
    });

    test('pulses: 0.9 s on, 0.3 s quiet gap', () {
      double rms(double from, double to) {
        final a = (from * _rate).round(), b = (to * _rate).round();
        var e = 0.0;
        for (var i = a; i < b; i++) {
          e += s[i] * s[i];
        }
        return sqrt(e / (b - a));
      }

      for (var k = 1; k < 20; k++) {
        final t = k * 1.2;
        expect(rms(t + 0.2, t + 0.7), greaterThan(0.6)); // on
        expect(rms(t + 0.95, t + 1.15), lessThan(0.01)); // gap
      }
    });

    test('no clicks anywhere (smooth sample-to-sample)', () {
      // A 180 Hz sine at 0.95 moves at most 2π·180/44100·0.95 ≈ 0.024.
      for (var i = 1; i < s.length; i++) {
        expect((s[i] - s[i - 1]).abs(), lessThan(0.03));
      }
    });
  });

  group('dust', () {
    const length = Duration(seconds: 20);
    final s = CleanerTones.program(CleanMode.dust, length);

    test('exact length, silent ends, no clipping or NaN', () {
      checkBasics(s, length);
    });

    test('sweeps cover ~200 Hz and ~1500 Hz', () {
      final p = pitches(s, maxHz: 2000);
      expect(p.length, greaterThan(50));
      expect(p.reduce(min), lessThan(230));
      expect(p.reduce(max), greaterThan(1350));
      for (final hz in p) {
        expect(hz, inInclusiveRange(180, 1650));
      }
      // Zero-crossing check at the bottom and top of the first sweep.
      expect(zcrHz(s, 3.4, 3.6), closeTo(200, 20));
      expect(zcrHz(s, 1.65, 1.85), closeTo(1500, 60));
    });

    test('repeats every 3.5 s', () {
      for (var k = 0; k < 5; k++) {
        final t = k * 3.5;
        expect(CleanerTones.frequencyAt(CleanMode.dust, t), closeTo(200, 0.01));
        expect(CleanerTones.frequencyAt(CleanMode.dust, t + 1.75),
            closeTo(1500, 0.01));
      }
    });
  });

  test('every length option renders exactly and encodes to WAV', () {
    for (final mode in CleanMode.values) {
      for (final length in CleanerTones.lengths(mode)) {
        final bytes = CleanerTones.wav(mode, length);
        final audio = Wav.decode(bytes);
        expect(audio.sampleRate, _rate);
        expect(audio.duration, length);
      }
    }
    expect(CleanerTones.defaultLength(CleanMode.water), const Duration(seconds: 30));
    expect(CleanerTones.defaultLength(CleanMode.dust), const Duration(seconds: 20));
  });

  test('intensity follows the audio for the animation', () {
    expect(CleanerTones.intensityAt(CleanMode.water, 0.5), 1);
    expect(CleanerTones.intensityAt(CleanMode.water, 1.0), 0);
    expect(CleanerTones.intensityAt(CleanMode.dust, 0), closeTo(0, 1e-9));
    expect(CleanerTones.intensityAt(CleanMode.dust, 1.75), closeTo(1, 1e-9));
  });
}
