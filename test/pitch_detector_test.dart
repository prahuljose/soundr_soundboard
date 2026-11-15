import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/guitar_tuning.dart';
import 'package:soundr_soundboard/services/pitch_detector.dart';

import 'support/guitar_synth.dart';

double cents(double hz, double target) => 1200 * log(hz / target) / ln2;

/// Runs [samples] through a detector and returns every reading.
/// [config] is an instrument's detector range (default: the guitar's).
List<PitchReading?> detect(List<double> samples,
    {int sampleRate = 44100, DetectorConfig? config}) {
  final out = <PitchReading?>[];
  final d = config == null
      ? PitchDetector(sampleRate: sampleRate, onReading: out.add)
      : config.build(sampleRate: sampleRate, onReading: out.add);
  d.addSamples(samples);
  return out;
}

/// Every voiced reading must be the right note (no octave or fifth slips)
/// and the settled median within [tol] cents.
///
/// [tailGate] drops readings quieter than a tenth of the loudest, as the
/// tuner engine does: with no fundamental at all, the last whisper of a
/// note is little more than its 2nd harmonic and truly is an octave up.
void expectNote(List<PitchReading?> readings, double hz, String name,
    {double tol = 3, int minVoiced = 15, double from = 0.3, bool tailGate = false}) {
  var voiced = readings.whereType<PitchReading>().toList();
  if (tailGate) {
    final peak = voiced.map((r) => r.rms).fold(0.0, max);
    voiced = voiced.where((r) => r.rms >= peak * 0.1).toList();
  }
  expect(voiced.length, greaterThan(minVoiced), reason: name);
  for (final r in voiced) {
    expect(cents(r.hz, hz).abs(), lessThan(50),
        reason: '$name: read ${r.hz.toStringAsFixed(2)} Hz');
  }
  expect(cents(medianHz(readings, from: from), hz).abs(), lessThan(tol),
      reason: name);
}

/// Median of the voiced readings between [from] and [to] seconds.
double medianHz(List<PitchReading?> readings, {double from = 0.15, double to = 1.2}) {
  const hop = 2048 / 44100;
  final hz = <double>[];
  for (var i = 0; i < readings.length; i++) {
    final t = (i + 1) * hop;
    final r = readings[i];
    if (t >= from && t <= to && r != null) hz.add(r.hz);
  }
  expect(hz, isNotEmpty, reason: 'no pitch found');
  hz.sort();
  return hz[hz.length ~/ 2];
}

void main() {
  // Open strings across the tunings the tuner offers (C2 … E4), plus a
  // few fretted notes on the high strings.
  const notes = {
    'C2': 65.41, 'D2': 73.42, 'Eb2': 77.78, 'E2': 82.41,
    'G2': 98.00, 'Ab2': 103.83, 'A2': 110.00, 'C3': 130.81,
    'Db3': 138.59, 'D3': 146.83, 'F3': 174.61, 'F#3': 185.00,
    'G3': 196.00, 'A3': 220.00, 'Bb3': 233.08, 'B3': 246.94,
    'D4': 293.66, 'Eb4': 311.13, 'E4': 329.63, 'A4': 440.00,
    'E5': 659.26, 'A5': 880.00,
  };

  group('plucked guitar strings', () {
    for (final e in notes.entries) {
      test('${e.key} within 2 cents, no octave errors', () {
        final samples = pluckedString(e.value, seconds: 1.4, seed: e.key.hashCode);
        final readings = detect(samples);
        final voiced = readings.whereType<PitchReading>().toList();
        // Every reading must be the right note — an octave or fifth slip
        // would be ±700…1200 cents. (The dying tail wobbles a little; the
        // tuner's smoothing deals with that.)
        expect(voiced.length, greaterThan(15));
        for (final r in voiced) {
          expect(cents(r.hz, e.value).abs(), lessThan(50),
              reason: '${e.key}: read ${r.hz.toStringAsFixed(2)} Hz');
        }
        expect(cents(medianHz(readings), e.value).abs(), lessThan(2));
      });
    }
  });

  test('a detuned string reads the detune, not the target', () {
    for (final off in [-30.0, -8.0, -3.0, 3.0, 12.0, 45.0]) {
      final hz = 110.0 * pow(2, off / 1200);
      final got = medianHz(detect(pluckedString(hz.toDouble(), seconds: 1.2)));
      expect(cents(got, 110), closeTo(off, 1.5), reason: '$off cents');
    }
  });

  test('pure sine is exact', () {
    final samples = sine(82.41, seconds: 0.6);
    expect(cents(medianHz(detect(samples), to: 0.6), 82.41).abs(), lessThan(0.5));
  });

  test('silence and quiet hiss give no pitch', () {
    expect(detect(List.filled(44100, 0.0)).whereType<PitchReading>(), isEmpty);
    final rnd = Random(1);
    final hiss = List.generate(44100, (_) => (rnd.nextDouble() * 2 - 1) * 0.004);
    expect(detect(hiss).whereType<PitchReading>(), isEmpty);
  });

  test('loud white noise is not mistaken for a note', () {
    final rnd = Random(7);
    final noise = List.generate(44100, (_) => (rnd.nextDouble() * 2 - 1) * 0.3);
    final voiced = detect(noise).whereType<PitchReading>().length;
    expect(voiced, lessThanOrEqualTo(1));
  });

  test('works from 16-bit PCM bytes and at 48 kHz', () {
    final samples = pluckedString(146.83, seconds: 1.0, sampleRate: 48000);
    final bytes = ByteData(samples.length * 2);
    for (var i = 0; i < samples.length; i++) {
      bytes.setInt16(i * 2, (samples[i] * 32767).round(), Endian.little);
    }
    final out = <PitchReading?>[];
    PitchDetector(sampleRate: 48000, onReading: out.add)
        .addPcm16(bytes.buffer.asUint8List());
    final hz = out.whereType<PitchReading>().map((r) => r.hz).toList()..sort();
    expect(cents(hz[hz.length ~/ 2], 146.83).abs(), lessThan(2));
  });

  group('bass: weak or missing fundamental', () {
    // A phone mic passes little below ~80 Hz, so the note has to be found
    // from its overtones.
    const notes = {
      'B0': 30.87, 'D1': 36.71, 'E1': 41.20, 'A1': 55.00,
      'D2': 73.42, 'G2': 98.00,
    };
    for (final e in notes.entries) {
      for (final gain in [0.2, 0.1, 0.0]) {
        test('${e.key}, fundamental at ${(gain * 100).round()}%', () {
          final samples = pluckedString(e.value,
              seconds: 1.6, seed: e.key.hashCode, fundamentalGain: gain);
          expectNote(detect(samples, config: bass.detector), e.value, e.key,
              tailGate: gain == 0, minVoiced: gain == 0 ? 10 : 15);
        });
      }
    }

    test('a flat low B and a sharp G still read true', () {
      for (final (hz, off) in [(30.87, -40.0), (30.87, 15.0), (98.0, 30.0)]) {
        final f = hz * pow(2, off / 1200);
        final got = medianHz(
            detect(pluckedString(f.toDouble(), seconds: 1.5, fundamentalGain: 0.1),
                config: bass.detector),
            from: 0.3);
        expect(cents(got, hz), closeTo(off, 2), reason: '$hz $off');
      }
    });

    test('first reading within a quarter of a second', () {
      final d = bass.detector.build(sampleRate: 44100, onReading: (_) {});
      expect(d.latencyMs, lessThan(250));
      // ignore: avoid_print
      print('latency ms: guitar '
          '${guitar.detector.build(sampleRate: 44100, onReading: (_) {}).latencyMs}'
          ', ukulele '
          '${ukulele.detector.build(sampleRate: 44100, onReading: (_) {}).latencyMs}'
          ', bass ${d.latencyMs}, violin '
          '${violin.detector.build(sampleRate: 44100, onReading: (_) {}).latencyMs}');
    });
  });

  group('ukulele', () {
    const notes = {
      'D3': 146.83, 'G3': 196.00, 'B3': 246.94, 'C4': 261.63, 'D4': 293.66,
      'E4': 329.63, 'F#4': 369.99, 'G4': 392.00, 'A4': 440.00, 'B4': 493.88,
    };
    for (final e in notes.entries) {
      test(e.key, () {
        final samples = pluckedString(e.value, seconds: 1.4, seed: e.key.hashCode);
        expectNote(detect(samples, config: ukulele.detector), e.value, e.key,
            from: 0.15);
      });
    }
  });

  group('violin family', () {
    const notes = {
      'C3': 130.81, 'G3': 196.00, 'D4': 293.66, 'A4': 440.00, 'E5': 659.26,
      'B5': 987.77, // first-position stretch on the E string
    };
    for (final e in notes.entries) {
      test('${e.key} plucked', () {
        final samples = pluckedString(e.value, seconds: 1.4, seed: e.key.hashCode);
        expectNote(detect(samples, config: violin.detector), e.value, e.key,
            from: 0.15);
      });
      test('${e.key} bowed', () {
        final samples = bowedString(e.value, seconds: 1.4);
        expectNote(detect(samples, config: violin.detector), e.value, e.key,
            from: 0.15);
      });
    }
    test('cello C2 and A3', () {
      final config = violin.detectorFor(violin.tuningById('cello'));
      for (final hz in [65.41, 98.0, 146.83, 220.0]) {
        expectNote(detect(bowedString(hz, seconds: 1.4), config: config), hz, '$hz');
        expectNote(detect(pluckedString(hz, seconds: 1.4), config: config), hz, '$hz');
      }
    });
  });

  for (final (name, config, low) in [
    ('guitar', null, 82.41),
    ('bass', bass.detector, 41.2),
    ('ukulele', ukulele.detector, 261.63),
    ('violin', violin.detector, 196.0),
  ]) {
    test('$name config is fast enough for real time', () {
      // A sustained tone, so every window is fully analysed.
      final samples = [
        for (var i = 0; i < 5 * 44100; i++)
          0.3 * sin(2 * pi * low * i / 44100) +
              0.3 * sin(2 * pi * low * 2 * i / 44100),
      ];
      final sw = Stopwatch()..start();
      final n = detect(samples, config: config).whereType<PitchReading>().length;
      sw.stop();
      expect(n, greaterThan(90));
      // 5 s of audio; JIT test VM is far slower than a release build.
      expect(sw.elapsedMilliseconds, lessThan(2500),
          reason: '${sw.elapsedMilliseconds} ms for 5 s of audio');
      // ignore: avoid_print
      print('pitch detector ($name): ${sw.elapsedMilliseconds} ms per 5 s of audio');
    });
  }
}
