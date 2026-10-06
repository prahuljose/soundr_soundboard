import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/guitar_tuning.dart';
import 'package:soundr_soundboard/services/pitch_detector.dart';

import 'support/guitar_synth.dart';

const _hopMs = 2048 * 1000 / 44100;

/// Plays [samples] through detector → engine; returns each reading with
/// its time in ms. [startMs] continues a session's clock.
List<(int, TunerReading)> run(TunerEngine engine, List<double> samples,
    {int startMs = 0}) {
  final out = <(int, TunerReading)>[];
  var i = 0;
  PitchDetector(onReading: (r) {
    final t = startMs + (++i * _hopMs).round();
    out.add((t, engine.add(r, t)));
  }).addSamples(samples);
  return out;
}

double hzFor(int midi, double cents, {double a4 = 440}) =>
    midiToHz(midi, a4: a4) * pow(2, cents / 1200).toDouble();

void main() {
  group('note maths', () {
    test('names, octaves and frequencies', () {
      expect(midiToHz(69), 440);
      expect(midiToHz(40), closeTo(82.41, 0.01));
      expect(noteName(40), 'E');
      expect(noteOctave(40), 2);
      expect(noteName(63, flats: true), 'E♭');
      expect(noteName(66), 'F♯');
      expect(centsOff(440 * pow(2, 7 / 1200).toDouble(), 69), closeTo(7, 1e-9));
      expect(midiToHz(69, a4: 432), 432);
    });

    test('tunings', () {
      expect(guitarTunings.first.letters, 'E A D G B E');
      expect(tuningById('drop_d').letters, 'D A D G B E');
      expect(tuningById('half_down').letters, 'E♭ A♭ D♭ G♭ B♭ E♭');
      expect(tuningById('dadgad').letters, 'D A D G A D');
      expect(tuningById('nope').id, 'standard');
      for (final t in guitarTunings) {
        expect(t.strings.length, 6);
        for (var i = 1; i < 6; i++) {
          expect(t.strings[i], greaterThan(t.strings[i - 1]), reason: t.name);
        }
      }
    });
  });

  group('auto mode finds each string and reads it accurately', () {
    for (final tuning in guitarTunings) {
      test(tuning.name, () {
        for (var s = 0; s < 6; s++) {
          for (final off in [-25.0, 0.0, 12.0]) {
            final engine = TunerEngine(tuning: tuning);
            final hz = hzFor(tuning.strings[s], off);
            final readings = run(engine, pluckedString(hz, seconds: 1.6, seed: s));
            final active = readings.where((e) => e.$2.active).toList();
            expect(active.length, greaterThan(12), reason: '${tuning.name} $s');
            for (final (t, r) in active) {
              expect(r.stringIndex, s, reason: '${tuning.name} string $s at $t ms');
              // Allow for the sharp pick attack in the first ~150 ms.
              final tol = t < 250 ? 6.0 : 3.0;
              expect(r.cents!, closeTo(off, tol),
                  reason: '${tuning.name} string $s ${off}c at $t ms');
            }
          }
        }
      });
    }
  });

  test('status: flat, sharp, in tune', () {
    TunerReading last(double off) {
      final e = TunerEngine(tuning: guitarTunings.first);
      final r = run(e, pluckedString(hzFor(45, off), seconds: 0.8));
      return r.lastWhere((x) => x.$2.active).$2;
    }

    expect(last(-20).status, TunerStatus.flat);
    expect(last(18).status, TunerStatus.sharp);
    expect(last(0).status, TunerStatus.inTune);
    expect(last(2).status, TunerStatus.inTune);
  });

  test('a string is marked tuned after holding in tune, once', () {
    final hits = <int>[];
    final e = TunerEngine(tuning: guitarTunings.first, onStringTuned: hits.add);
    run(e, pluckedString(hzFor(50, 1), seconds: 1.5));
    expect(e.tuned, {2});
    expect(hits, [2]);
    // A quick out-of-tune blip doesn't mark it.
    final e2 = TunerEngine(tuning: guitarTunings.first);
    run(e2, pluckedString(hzFor(50, 20), seconds: 1.5));
    expect(e2.tuned, isEmpty);
  });

  test('all six strings tuned → allTuned', () {
    final e = TunerEngine(tuning: guitarTunings.first);
    var t = 0;
    for (final m in guitarTunings.first.strings) {
      final r = run(e, pluckedString(hzFor(m, -1), seconds: 1.5), startMs: t);
      t = r.last.$1 + 2000;
    }
    expect(e.allTuned, isTrue);
  });

  test('a tuned string that drifts far out loses its tick', () {
    final e = TunerEngine(tuning: guitarTunings.first);
    final r = run(e, pluckedString(hzFor(55, 0), seconds: 1.5));
    expect(e.tuned, {3});
    run(e, pluckedString(hzFor(55, -40), seconds: 2.5), startMs: r.last.$1 + 500);
    expect(e.tuned, isEmpty);
  });

  test('manual mode tunes to the chosen string even when far off', () {
    // Low E string tuned way down to C2, user picked string 0 (E2).
    final e = TunerEngine(tuning: guitarTunings.first, lockedString: 0);
    final r = run(e, pluckedString(hzFor(36, 0), seconds: 1.0));
    final last = r.lastWhere((x) => x.$2.active).$2;
    expect(last.stringIndex, 0);
    expect(last.cents!, closeTo(-400, 4));
    expect(last.status, TunerStatus.flat);
  });

  test('chromatic mode names any note', () {
    final e = TunerEngine(tuning: guitarTunings.first, chromatic: true);
    final r = run(e, pluckedString(hzFor(61, -10), seconds: 1.0)); // C♯4
    final last = r.lastWhere((x) => x.$2.active).$2;
    expect(last.stringIndex, isNull);
    expect(last.targetMidi, 61);
    expect(last.cents!, closeTo(-10, 3));
  });

  test('A4 calibration shifts the target', () {
    final e = TunerEngine(tuning: guitarTunings.first, a4: 432);
    // A2 at A4 = 440 is 110 Hz, which is sharp against A4 = 432.
    final r = run(e, pluckedString(110, seconds: 1.0));
    final last = r.lastWhere((x) => x.$2.active).$2;
    expect(last.stringIndex, 1);
    expect(last.cents!, closeTo(1200 * log(440 / 432) / ln2, 3)); // ≈ +31.8
  });

  test('goes back to waiting after the note dies away, then hears the next', () {
    final e = TunerEngine(tuning: guitarTunings.first);
    var r = run(e, pluckedString(hzFor(40, 0), seconds: 1.0));
    expect(r.last.$2.active, isTrue);
    r = run(e, List.filled(44100 * 2, 0.0), startMs: r.last.$1);
    expect(r.last.$2.active, isFalse);
    r = run(e, pluckedString(hzFor(59, 8), seconds: 1.0), startMs: r.last.$1);
    final last = r.lastWhere((x) => x.$2.active).$2;
    expect(last.stringIndex, 4);
    expect(last.cents!, closeTo(8, 3));
  });

  test('switching strings between plucks without a pause', () {
    final e = TunerEngine(tuning: guitarTunings.first);
    final samples = [
      ...pluckedString(hzFor(45, 0), seconds: 0.8, seed: 1),
      ...pluckedString(hzFor(50, -15), seconds: 1.0, seed: 2),
    ];
    final r = run(e, samples);
    final tail = r.where((x) => x.$1 > 1300 && x.$2.active).toList();
    expect(tail, isNotEmpty);
    for (final (_, x) in tail) {
      expect(x.stringIndex, 2);
      expect(x.cents!, closeTo(-15, 3));
    }
  });
}
