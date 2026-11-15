import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/guitar_tuning.dart';
import 'package:soundr_soundboard/services/pitch_detector.dart';

import 'support/guitar_synth.dart';

const _hopMs = 2048 * 1000 / 44100;

/// Plays [samples] through detector → engine; returns each reading with
/// its time in ms. [startMs] continues a session's clock. [config] is the
/// instrument's detector range (default: the guitar's).
List<(int, TunerReading)> run(TunerEngine engine, List<double> samples,
    {int startMs = 0, DetectorConfig config = const DetectorConfig(60, 1400)}) {
  final out = <(int, TunerReading)>[];
  var i = 0;
  final PitchDetector detector = config.build(
    sampleRate: 44100,
    onReading: (r) {
      final t = startMs + (++i * _hopMs).round();
      out.add((t, engine.add(r, t)));
    },
  );
  detector.addSamples(samples);
  return out;
}

/// A string as a phone hears it: bass notes arrive with only a tenth of
/// their fundamental.
List<double> pluck(Instrument i, double hz, {double seconds = 1.6, int seed = 3}) =>
    pluckedString(hz,
        seconds: seconds, seed: seed, fundamentalGain: i == bass ? 0.1 : null);

double hzFor(int midi, double cents, {double a4 = 440}) =>
    midiToHz(midi, a4: a4) * pow(2, cents / 1200).toDouble();

void main() {
  group('note maths', () {
    test('names, octaves and frequencies', () {
      expect(midiToHz(69), 440);
      expect(midiToHz(40), closeTo(82.41, 0.01));
      expect(noteName(40), 'E');
      expect(noteOctave(40), 2);
      expect(noteName(63, flats: true), 'Eb');
      expect(noteName(66), 'F#');
      expect(centsOff(440 * pow(2, 7 / 1200).toDouble(), 69), closeTo(7, 1e-9));
      expect(midiToHz(69, a4: 432), 432);
    });

    test('tunings', () {
      expect(guitarTunings.first.letters, 'E A D G B E');
      expect(tuningById('drop_d').letters, 'D A D G B E');
      expect(tuningById('half_down').letters, 'Eb Ab Db Gb Bb Eb');
      expect(tuningById('dadgad').letters, 'D A D G A D');
      expect(tuningById('nope').id, 'standard');
      for (final t in guitarTunings) {
        expect(t.strings.length, 6);
      }
    });

    test('instruments and their tunings', () {
      expect(instruments.map((i) => i.name),
          ['Guitar', 'Ukulele', 'Bass', 'Violin']);
      expect(ukulele.tuningById('uke_standard').letters, 'G C E A');
      expect(ukulele.tuningById('uke_standard').strings, [67, 60, 64, 69]);
      expect(ukulele.tuningById('uke_low_g').strings, [55, 60, 64, 69]);
      expect(ukulele.tuningById('uke_baritone').letters, 'D G B E');
      expect(ukulele.tuningById('uke_d').letters, 'A D F# B');
      expect(bass.tuningById('bass_standard').strings, [28, 33, 38, 43]);
      expect(bass.tuningById('bass_drop_d').letters, 'D A D G');
      expect(bass.tuningById('bass_5').strings, [23, 28, 33, 38, 43]);
      expect(midiToHz(23), closeTo(30.87, 0.01));
      expect(violin.tuningById('violin').strings, [55, 62, 69, 76]);
      expect(violin.tuningById('viola').letters, 'C G D A');
      expect(violin.tuningById('cello').letters, 'C G D A');

      final ids = <String>{};
      for (final i in instruments) {
        for (final t in i.tunings) {
          expect(ids.add(t.id), isTrue, reason: 'duplicate id ${t.id}');
          expect(t.strings.length, inInclusiveRange(4, 6));
          // No two strings share a note, so auto mode can tell them apart.
          expect(t.strings.toSet().length, t.strings.length, reason: t.id);
          // Every string, well flat (drop C's low C has the least room,
          // 1.5 semitones) to a tone sharp, is in the range the detector
          // listens over.
          final d = i.detectorFor(t);
          for (final m in t.strings) {
            expect(midiToHz(m - 1.4), greaterThan(d.minHz), reason: t.id);
            expect(midiToHz(m + 2), lessThan(d.maxHz), reason: t.id);
          }
        }
      }
    });

    test('only the high-G ukuleles are re-entrant; the rest ascend', () {
      for (final i in instruments) {
        for (final t in i.tunings) {
          final reentrant = t.id == 'uke_standard' || t.id == 'uke_d';
          expect(t.reentrant, reentrant, reason: t.id);
          if (reentrant) continue;
          for (var s = 1; s < t.strings.length; s++) {
            expect(t.strings[s], greaterThan(t.strings[s - 1]), reason: t.id);
          }
        }
      }
    });

    test('string numbers count down to 1 for any string count', () {
      final uke = ukulele.tunings.first;
      expect([for (var s = 0; s < 4; s++) uke.stringNumber(s)], [4, 3, 2, 1]);
      expect('${uke.stringNumber(0)} ${uke.label(0)}', '4 G');
      final five = bass.tuningById('bass_5');
      expect(five.stringNumber(0), 5);
      expect(five.label(0), 'B');
      expect(guitarTunings.first.stringNumber(0), 6);
    });

    test('lookups fall back: unknown instrument → guitar, tuning → first', () {
      expect(instrumentById(null), guitar);
      expect(instrumentById('theremin'), guitar);
      expect(instrumentById('bass'), bass);
      // Ids saved when the tuner was guitar-only.
      expect(guitar.tuningById('dadgad').name, 'DADGAD');
      expect(ukulele.tuningById('dadgad').id, 'uke_standard');
      expect(violin.tuningById(null).id, 'violin');
    });

    test('names and reference notes', () {
      expect(ukulele.titleFor(ukulele.tuningById('uke_low_g')), 'Ukulele · Low G');
      expect(violin.titleFor(violin.tuningById('cello')), 'Cello');
      // Bass references sound an octave up; everything else as written.
      expect(bass.referenceHz(28), closeTo(82.41, 0.01));
      expect(guitar.referenceHz(40), closeTo(82.41, 0.01));
      expect(violin.referenceHz(76, a4: 442), closeTo(662.25, 0.01));
    });
  });

  group('auto mode finds each string and reads it accurately', () {
    for (final instrument in instruments) {
      for (final tuning in instrument.tunings) {
        test('${instrument.name}: ${tuning.name}', () {
          final config = instrument.detectorFor(tuning);
          for (var s = 0; s < tuning.strings.length; s++) {
            for (final off in [-25.0, 0.0, 12.0]) {
              final engine = TunerEngine(tuning: tuning);
              final hz = hzFor(tuning.strings[s], off);
              final readings =
                  run(engine, pluck(instrument, hz, seed: s), config: config);
              final active = readings.where((e) => e.$2.active).toList();
              expect(active.length, greaterThan(12), reason: '${tuning.name} $s');
              for (final (t, r) in active) {
                expect(r.stringIndex, s,
                    reason: '${tuning.name} string $s at $t ms');
                expect(r.targetMidi, tuning.strings[s]);
                // Allow for the sharp pick attack in the first ~150 ms.
                final tol = t < 250 ? 6.0 : 3.0;
                expect(r.cents!, closeTo(off, tol),
                    reason: '${tuning.name} string $s ${off}c at $t ms');
              }
            }
          }
        });
      }
    }
  });

  group('re-entrant ukulele (G4 C4 E4 A4: 4th string above the 3rd)', () {
    final uke = ukulele.tunings.first;

    TunerReading last(TunerEngine e, int midi, double off) => run(
            e, pluckedString(hzFor(midi, off), seconds: 1.0),
            config: ukulele.detector)
        .lastWhere((x) => x.$2.active)
        .$2;

    test('each note maps to its own string, in instrument order', () {
      expect(last(TunerEngine(tuning: uke), 67, 0).stringIndex, 0); // G4
      expect(last(TunerEngine(tuning: uke), 60, 0).stringIndex, 1); // C4
      expect(last(TunerEngine(tuning: uke), 64, 0).stringIndex, 2); // E4
      expect(last(TunerEngine(tuning: uke), 69, 0).stringIndex, 3); // A4
    });

    test('a note between two strings goes to the nearer, wherever it sits', () {
      // F#4 +40c is nearer the G string (index 0) than E (index 2).
      final r = last(TunerEngine(tuning: uke), 66, 40);
      expect(r.stringIndex, 0);
      expect(r.cents!, closeTo(-60, 3));
      // A slack A string (G#4 +30c) still reads as A, not the G beside it
      // in pitch but at the other edge of the neck.
      final a = last(TunerEngine(tuning: uke), 68, 30);
      expect(a.stringIndex, 3);
      expect(a.cents!, closeTo(-70, 3));
      // And a sharp G (G4 +45c) stays G.
      expect(last(TunerEngine(tuning: uke), 67, 45).stringIndex, 0);
    });

    test('low G uses the same string an octave down', () {
      final lowG = ukulele.tuningById('uke_low_g');
      final r = last(TunerEngine(tuning: lowG), 55, -8);
      expect(r.stringIndex, 0);
      expect(r.cents!, closeTo(-8, 3));
      // The high G is an octave off the low-G string and nearer the A.
      expect(last(TunerEngine(tuning: lowG), 67, 0).stringIndex, 3);
    });

    test('locked to the G string, a C is read against G', () {
      final e = TunerEngine(tuning: uke, lockedString: 0);
      final r = last(e, 60, 0);
      expect(r.stringIndex, 0);
      expect(r.cents!, closeTo(-700, 4));
    });

    test('tuned in the order G C E A → all 4 tuned', () {
      final e = TunerEngine(tuning: uke);
      final order = <int>[];
      e.onStringTuned = order.add;
      var t = 0;
      for (final m in uke.strings) {
        expect(e.allTuned, isFalse);
        final r = run(e, pluckedString(hzFor(m, 1), seconds: 1.5),
            startMs: t, config: ukulele.detector);
        t = r.last.$1 + 2000;
      }
      expect(order, [0, 1, 2, 3]);
      expect(e.allTuned, isTrue);
    });
  });

  group('allTuned follows the string count', () {
    for (final (instrument, id, count) in [
      (bass, 'bass_standard', 4),
      (bass, 'bass_5', 5),
      (violin, 'violin', 4),
      (guitar, 'standard', 6),
    ]) {
      test('${instrument.name} $id: $count strings', () {
        final tuning = instrument.tuningById(id);
        expect(tuning.strings.length, count);
        final e = TunerEngine(tuning: tuning);
        var t = 0;
        for (final m in tuning.strings) {
          expect(e.allTuned, isFalse, reason: 'before midi $m');
          final r = run(e, pluck(instrument, hzFor(m, -1), seconds: 1.5),
              startMs: t, config: instrument.detectorFor(tuning));
          t = r.last.$1 + 2000;
        }
        expect(e.tuned.length, count);
        expect(e.allTuned, isTrue);
      });
    }

    test('four ticks left over from a bass are not "all tuned" on five strings', () {
      final e = TunerEngine(tuning: bass.tunings.first);
      e.tuned.addAll([0, 1, 2, 3]);
      expect(e.allTuned, isTrue);
      e.tuning = bass.tuningById('bass_5');
      expect(e.allTuned, isFalse);
    });
  });

  test('bass E1 with a weak fundamental: flat, then in tune', () {
    final e = TunerEngine(tuning: bass.tunings.first);
    var r = run(e, pluck(bass, hzFor(28, -22), seconds: 1.2), config: bass.detector);
    final flat = r.lastWhere((x) => x.$2.active).$2;
    expect(flat.stringIndex, 0);
    expect(flat.status, TunerStatus.flat);
    expect(flat.hz!, closeTo(hzFor(28, -22), 0.1));
    r = run(e, pluck(bass, hzFor(28, 1), seconds: 1.5),
        startMs: r.last.$1 + 500, config: bass.detector);
    expect(r.lastWhere((x) => x.$2.active).$2.status, TunerStatus.inTune);
    expect(e.tuned, {0});
  });

  test('bowed violin strings hold steady', () {
    final e = TunerEngine(tuning: violin.tunings.first);
    for (var s = 0; s < 4; s++) {
      e.resetNote();
      final hz = hzFor(violin.tunings.first.strings[s], 7);
      final r = run(e, bowedString(hz, seconds: 1.2), config: violin.detector);
      final active = r.where((x) => x.$2.active && x.$1 > 250).toList();
      expect(active.length, greaterThan(12));
      for (final (_, x) in active) {
        expect(x.stringIndex, s);
        expect(x.cents!, closeTo(7, 3));
      }
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
