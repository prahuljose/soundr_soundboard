import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/bpm_detector.dart';

const rate = 44100;

/// A metronome-like click on every beat.
List<double> clickTrack(double bpm, {double seconds = 9, double noise = 0, int seed = 1}) {
  final rnd = Random(seed);
  final n = (seconds * rate).round();
  final out = List<double>.filled(n, 0);
  final period = 60 / bpm * rate;
  for (var b = 0; b * period < n; b++) {
    final at = (b * period + 0.11 * rate).round();
    for (var i = 0; i < 0.04 * rate && at + i < n; i++) {
      final t = i / rate;
      out[at + i] += 0.6 * sin(2 * pi * 1000 * t) * exp(-45 * t);
    }
  }
  if (noise > 0) {
    for (var i = 0; i < n; i++) {
      out[i] += noise * (rnd.nextDouble() * 2 - 1);
    }
  }
  return out;
}

/// Kick on every beat, hi-hat on every eighth note (straight, no swing).
List<double> kickHat(double bpm,
    {double seconds = 9, double noise = 0, double hat = 0.2, int seed = 1}) {
  final rnd = Random(seed);
  final n = (seconds * rate).round();
  final out = List<double>.filled(n, 0);
  final period = 60 / bpm * rate;
  for (var e = 0; e * period / 2 < n; e++) {
    final at = (e * period / 2 + 0.07 * rate).round();
    // Hat: a short burst of high-passed noise.
    var prev = 0.0;
    for (var i = 0; i < 0.05 * rate && at + i < n; i++) {
      final w = rnd.nextDouble() * 2 - 1;
      out[at + i] += hat * (w - prev) * 0.5 * exp(-70 * i / rate);
      prev = w;
    }
    if (e.isEven) {
      // Kick: a sine dropping from ~120 Hz to ~50 Hz.
      var phase = 0.0;
      for (var i = 0; i < 0.18 * rate && at + i < n; i++) {
        final t = i / rate;
        phase += 2 * pi * (50 + 70 * exp(-30 * t)) / rate;
        out[at + i] += 0.8 * sin(phase) * exp(-18 * t);
      }
    }
  }
  if (noise > 0) {
    for (var i = 0; i < n; i++) {
      out[i] += noise * (rnd.nextDouble() * 2 - 1);
    }
  }
  return out;
}

Uint8List pcm16(List<double> samples) {
  final b = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    b.setInt16(i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

BpmEstimate? run(List<double> samples) => (BpmDetector()..addSamples(samples)).estimate();

const tempos = [60.0, 72.0, 90.0, 100.0, 120.0, 128.0, 140.0, 174.0];

void main() {
  group('click tracks', () {
    for (final bpm in tempos) {
      for (final noise in [0.0, 0.03]) {
        test('$bpm BPM${noise > 0 ? ' + noise' : ''}', () {
          final e = run(clickTrack(bpm, noise: noise))!;
          // ignore: avoid_print
          print('click  ${bpm.toStringAsFixed(0).padLeft(3)} noise=$noise → $e');
          expect(e.bpm, closeTo(bpm, 1.5));
          expect(e.isReliable, isTrue);
        });
      }
    }
  });

  group('kick + eighth-note hats', () {
    // At 60 and 72 BPM the hats tick at 120 / 144 — right where people tap —
    // so the prior may pick the eighth-note pulse (2×). Everything from
    // 90 BPM up must come out at the beat.
    const doubleAllowed = [60.0, 72.0];
    for (final bpm in tempos) {
      for (final noise in [0.0, 0.03]) {
        test('$bpm BPM${noise > 0 ? ' + noise' : ''}', () {
          final e = run(kickHat(bpm, noise: noise))!;
          // ignore: avoid_print
          print('kick+hat ${bpm.toStringAsFixed(0).padLeft(3)} noise=$noise → $e');
          final ok = (e.bpm - bpm).abs() <= 1.5 ||
              (doubleAllowed.contains(bpm) && (e.bpm - 2 * bpm).abs() <= 1.5);
          expect(ok, isTrue, reason: 'got ${e.bpm} for $bpm');
          expect(e.isReliable, isTrue);
        });
      }
    }
  });

  group('kick + loud eighth-note hats (octave-ambiguous)', () {
    // With hats nearly as loud as the kick the eighth-note pulse is as
    // strong as the beat, and the prior decides. The result is still locked
    // to the music, but may be an octave out at the extremes: 2× at 60 and
    // 72 BPM, ½× at 174 BPM. (That is what the ½× / 2× buttons are for.)
    const allowed = {60: 2.0, 72: 2.0, 174: 0.5};
    for (final bpm in tempos) {
      test('$bpm BPM', () {
        final e = run(kickHat(bpm, hat: 0.7))!;
        // ignore: avoid_print
        print('loud hats ${bpm.toStringAsFixed(0).padLeft(3)} → $e');
        final factor = allowed[bpm.round()];
        final ok = (e.bpm - bpm).abs() <= 1.5 ||
            (factor != null && (e.bpm - factor * bpm).abs() <= 1.5);
        expect(ok, isTrue, reason: 'got ${e.bpm} for $bpm');
        expect(e.isReliable, isTrue);
      });
    }
  });

  test('silence gives no estimate', () {
    expect(run(List.filled(8 * rate, 0.0)), isNull);
  });

  test('noise is not a beat', () {
    for (final amp in [0.002, 0.05, 0.4]) {
      for (var seed = 1; seed <= 4; seed++) {
        final rnd = Random(seed);
        final e = run(List.generate(8 * rate, (_) => amp * (rnd.nextDouble() * 2 - 1)));
        expect(e == null || !e.isReliable, isTrue, reason: 'amp $amp seed $seed: $e');
      }
    }
  });

  test('too little audio gives no estimate', () {
    expect(run(clickTrack(120, seconds: 1.5)), isNull);
  });

  test('PCM chunks that split a sample decode the same', () {
    final samples = kickHat(128, seconds: 6);
    final bytes = pcm16(samples);
    final whole = BpmDetector()..addPcm16(bytes);
    final odd = BpmDetector();
    for (var i = 0; i < bytes.length; i += 1001) {
      odd.addPcm16(Uint8List.sublistView(bytes, i, min(i + 1001, bytes.length)));
    }
    expect(odd.audioMs, whole.audioMs);
    expect(odd.estimate()!.bpm, closeTo(whole.estimate()!.bpm, 1e-9));
    expect(whole.estimate()!.bpm, closeTo(128, 1.5));
  });

  test('reports one onset per click', () {
    var onsets = 0;
    final d = BpmDetector(onOnset: (_) => onsets++);
    d.addSamples(clickTrack(120, seconds: 8, noise: 0.01));
    expect(onsets, inInclusiveRange(15, 17)); // 16 clicks in 8 s
    onsets = 0;
    d.reset();
    d.addSamples(List.filled(4 * rate, 0.0));
    expect(onsets, 0);
  });

  test('follows a tempo change and resets cleanly', () {
    final d = BpmDetector()..addSamples(clickTrack(90));
    expect(d.estimate()!.bpm, closeTo(90, 1.5));
    d.reset();
    expect(d.estimate(), isNull);
    d.addSamples(clickTrack(140));
    expect(d.estimate()!.bpm, closeTo(140, 1.5));
  });

  test('runs much faster than real time', () {
    final samples = kickHat(120, seconds: 10, noise: 0.02);
    final sw = Stopwatch()..start();
    final d = BpmDetector();
    // Estimate twice a second, as the screen does.
    for (var i = 0; i < samples.length; i += rate ~/ 2) {
      d.addSamples(samples.sublist(i, min(i + rate ~/ 2, samples.length)));
      d.estimate();
    }
    sw.stop();
    // ignore: avoid_print
    print('10 s of audio + 20 estimates in ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsedMilliseconds, lessThan(2500));
  });

  group('TapTempo', () {
    Duration ms(num v) => Duration(microseconds: (v * 1000).round());

    test('median of the gaps, steady after four taps', () {
      final t = TapTempo();
      expect(t.bpm, isNull);
      t.tap(ms(0));
      expect(t.bpm, isNull);
      t.tap(ms(500));
      expect(t.bpm, closeTo(120, 0.01));
      expect(t.isSteady, isFalse);
      t.tap(ms(1000));
      expect(t.isSteady, isFalse);
      t.tap(ms(1500));
      expect(t.isSteady, isTrue);
      expect(t.count, 4);
    });

    test('one sloppy tap does not swing the result', () {
      final t = TapTempo();
      for (final at in [0, 500, 1000, 1500, 2180, 2500, 3000]) {
        t.tap(ms(at));
      }
      expect(t.bpm, closeTo(120, 0.01));
    });

    test('uneven tapping is not steady', () {
      final t = TapTempo();
      for (final at in [0, 400, 1100, 1500, 2300]) {
        t.tap(ms(at));
      }
      expect(t.isSteady, isFalse);
    });

    test('a pause over two seconds starts over', () {
      final t = TapTempo();
      for (final at in [0, 500, 1000, 1500]) {
        t.tap(ms(at));
      }
      t.tap(ms(3600));
      expect(t.count, 1);
      expect(t.bpm, isNull);
      t.tap(ms(4350));
      expect(t.bpm, closeTo(80, 0.01));
    });

    test('follows a change of tempo within a few taps', () {
      final t = TapTempo();
      var at = 0.0;
      for (var i = 0; i < 8; i++) {
        t.tap(ms(at));
        at += 500;
      }
      for (var i = 0; i < 9; i++) {
        t.tap(ms(at));
        at += 400;
      }
      expect(t.bpm, closeTo(150, 0.01));
    });
  });
}
