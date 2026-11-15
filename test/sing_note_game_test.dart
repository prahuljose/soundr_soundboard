import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/guitar_tuning.dart';
import 'package:soundr_soundboard/services/pitch_detector.dart';
import 'package:soundr_soundboard/services/sing_note_game.dart';

double hz(num midi, [double cents = 0]) =>
    midiToHz(midi) * pow(2, cents / 1200).toDouble();

/// A sung note: a few harmonics, vibrato and a little breath noise.
List<double> voice(
  double f, {
  double seconds = 1,
  double vibratoCents = 20,
  double vibratoHz = 5,
  double amp = 0.3,
  int seed = 1,
}) {
  final rnd = Random(seed);
  final n = (seconds * 44100).round();
  final out = List<double>.filled(n, 0);
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / 44100;
    final fi = f * pow(2, vibratoCents * sin(2 * pi * vibratoHz * t) / 1200);
    phase += 2 * pi * fi / 44100;
    final env = min(1.0, t / 0.05);
    out[i] = amp *
            env *
            (sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase) + 0.12 * sin(4 * phase)) /
            1.6 +
        (rnd.nextDouble() * 2 - 1) * 0.01;
  }
  return out;
}

/// Feeds [tracker] a steady reading every 46 ms from [from] for [ms].
int sing(SingNoteTracker tracker, double? Function(int t) pitch, int from, int ms) {
  var t = from;
  for (; t < from + ms; t += 46) {
    tracker.add(pitch(t), t);
  }
  return t;
}

void main() {
  group('foldedCents', () {
    test('zero on the note in any octave', () {
      for (final octave in [-24, -12, 0, 12, 24]) {
        expect(foldedCents(hz(57 + octave), 57), closeTo(0, 1e-6));
      }
    });

    test('keeps sign and size inside ±600', () {
      expect(foldedCents(hz(57, 30), 57), closeTo(30, 1e-6));
      expect(foldedCents(hz(45, -40), 57), closeTo(-40, 1e-6));
      expect(foldedCents(hz(60), 57), closeTo(300, 1e-6));
      expect(foldedCents(hz(54), 57), closeTo(-300, 1e-6));
      // A man an octave down singing a fourth below the note.
      expect(foldedCents(hz(57 - 12 - 5), 57), closeTo(-500, 1e-6));
    });

    test('wraps around the tritone', () {
      expect(foldedCents(hz(57, 590), 57), closeTo(590, 1e-6));
      expect(foldedCents(hz(57, 610), 57), closeTo(-590, 1e-6));
      expect(foldedCents(hz(57, -590), 57), closeTo(-590, 1e-6));
      expect(foldedCents(hz(57, -610), 57), closeTo(590, 1e-6));
      // Exactly half-way is reported as low; always within [-600, 600).
      expect(foldedCents(hz(57, 600), 57).abs(), closeTo(600, 1e-6));
      for (var c = -3000.0; c < 3000; c += 37) {
        final f = foldedCents(hz(57, c), 57);
        expect(f, inInclusiveRange(-600, 600));
        expect(((f - c) / 1200 - ((f - c) / 1200).round()).abs(), lessThan(1e-6));
      }
    });
  });

  group('pickNotes', () {
    test('is deterministic for a seed', () {
      expect(SingNoteGame.pickNotes(Random(7)), SingNoteGame.pickNotes(Random(7)));
      expect(SingNoteGame.pickNotes(Random(7)),
          isNot(SingNoteGame.pickNotes(Random(8))));
    });

    test('eight notes in range: naturals first, sharps last, no repeats', () {
      for (var seed = 0; seed < 200; seed++) {
        final notes = SingNoteGame.pickNotes(Random(seed));
        expect(notes, hasLength(8));
        for (final m in notes) {
          expect(m, inInclusiveRange(SingNoteGame.lowestMidi, SingNoteGame.highestMidi));
        }
        expect(notes.take(6).every((m) => noteName(m).length == 1), isTrue);
        expect(notes.skip(6).every((m) => noteName(m).endsWith('#')), isTrue);
        expect(notes.map((m) => m % 12).toSet(), hasLength(8));
      }
    });

    test('other lengths never repeat a note back to back', () {
      expect(SingNoteGame.pickNotes(Random(1), count: 2).every((m) => noteName(m).length == 1), isTrue);
      for (var seed = 0; seed < 50; seed++) {
        final notes = SingNoteGame.pickNotes(Random(seed), count: 30);
        expect(notes, hasLength(30));
        for (var i = 1; i < notes.length; i++) {
          expect(notes[i] % 12, isNot(notes[i - 1] % 12));
        }
      }
    });
  });

  group('tracker', () {
    test('holding the note for a second finishes it', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      final end = sing(t, (_) => hz(57, 6), 0, 3000);
      expect(t.done, isTrue);
      expect(t.status, SingStatus.inTune);
      expect(t.meanAbsCents, closeTo(6, 0.01));
      expect(t.lockMs, lessThan(200));
      expect(end, 3036);
      // Stopped counting once done.
      expect(t.heldMs, inInclusiveRange(1000, 1046));
    });

    test('takes about a second of in-tune singing, not less', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      sing(t, (_) => hz(57), 0, 900);
      expect(t.done, isFalse);
      expect(t.progress, inInclusiveRange(0.7, 0.9));
      sing(t, (_) => hz(57), 920, 400);
      expect(t.done, isTrue);
    });

    test('an octave or two below still matches', () {
      for (final shift in [-24, -12, 12]) {
        final t = SingNoteTracker(targetMidi: 64)..begin(0);
        sing(t, (_) => hz(64 + shift, -8), 0, 1400);
        expect(t.done, isTrue, reason: 'shift $shift');
      }
    });

    test('says which way to go', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      sing(t, (_) => hz(55), 0, 400);
      expect(t.status, SingStatus.low);
      expect(t.cents, closeTo(-200, 0.01));
      sing(t, (_) => hz(58, 20), 414, 400);
      expect(t.status, SingStatus.high);
      expect(t.progress, 0);
      expect(t.bestAbsCents, closeTo(120, 0.01));
      // An octave down and a bit sharp: still "too high".
      sing(t, (_) => hz(45, 60), 828, 400);
      expect(t.status, SingStatus.high);
      expect(t.cents, closeTo(60, 0.01));
    });

    test('vibrato of ±20 cents at 5 Hz does not break the hold', () {
      final t = SingNoteTracker(targetMidi: 60)..begin(0);
      var breaks = 0;
      var started = false;
      for (var ms = 0; ms < 1600 && !t.done; ms += 46) {
        final v = 20 * sin(2 * pi * 5 * ms / 1000);
        t.add(hz(60, 8 + v), ms);
        if (t.status == SingStatus.inTune) started = true;
        if (started && t.status != SingStatus.inTune) breaks++;
      }
      expect(breaks, 0);
      expect(t.done, isTrue);
      expect(t.meanAbsCents, lessThan(20));
    });

    test('wide wobble outside the band does not count as holding', () {
      final t = SingNoteTracker(targetMidi: 60)..begin(0);
      sing(t, (ms) => hz(60, 80 + 20 * sin(2 * pi * 5 * ms / 1000)), 0, 3000);
      expect(t.done, isFalse);
      expect(t.heldMs, 0);
      expect(t.status, SingStatus.high);
    });

    test('a dropped frame or a stray octave error is smoothed over', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      var i = 0;
      sing(t, (_) {
        i++;
        if (i % 7 == 0) return null; // breath
        if (i % 9 == 0) return hz(57 + 7); // a fifth, for one frame
        return hz(57, -5);
      }, 0, 1500);
      expect(t.done, isTrue);
    });

    test('silence resets to waiting but keeps hold progress', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      var at = sing(t, (_) => hz(57), 0, 600);
      final held = t.heldMs;
      expect(held, greaterThan(350));
      at = sing(t, (_) => null, at, 400);
      expect(t.status, SingStatus.waiting);
      expect(t.cents, isNull);
      expect(t.heldMs, held);
      sing(t, (_) => hz(57), at, 900);
      expect(t.done, isTrue);
    });

    test('ignores everything before begin and before the mute point', () {
      final t = SingNoteTracker(targetMidi: 57);
      sing(t, (_) => hz(57), 0, 2000);
      expect(t.heldMs, 0);
      t.begin(5000);
      sing(t, (_) => hz(57), 2000, 2900); // the tone itself, still muted
      expect(t.heldMs, 0);
      expect(t.status, SingStatus.waiting);
      expect(t.timeLeft, 1);
      sing(t, (_) => hz(57), 5000, 1300);
      expect(t.done, isTrue);
    });

    test('times out after six seconds of singing time', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      sing(t, (_) => null, 0, 5900);
      expect(t.timedOut, isFalse);
      expect(t.timeLeft, lessThan(0.05));
      sing(t, (_) => null, 5934, 200);
      expect(t.timedOut, isTrue);
      expect(t.timeLeft, 0);
      final r = t.result(SingOutcome.timeout);
      expect(r.fraction, 0);
      expect(r.grade, SingGrade.miss);
    });

    test('a hold under way at the limit gets a grace period', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      var at = sing(t, (_) => hz(55), 0, 5500);
      at = sing(t, (_) => hz(57), at, 700); // on it at ~5.6 s
      expect(t.timedOut, isFalse);
      expect(t.status, SingStatus.inTune);
      sing(t, (_) => hz(57), at, 800);
      expect(t.done, isTrue);
      expect(t.timedOut, isFalse);

      // …but not for ever.
      final u = SingNoteTracker(targetMidi: 57, holdTargetMs: 60000)..begin(0);
      sing(u, (_) => hz(57), 0, 7400);
      expect(u.timedOut, isFalse);
      sing(u, (_) => hz(57), 7406, 300);
      expect(u.timedOut, isTrue);
    });

    test('hear it again restarts the clock, keeps progress, counts replays', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      var at = sing(t, (_) => hz(57), 0, 600);
      at = sing(t, (_) => hz(50), at, 4000);
      final held = t.heldMs;
      expect(t.timeLeft, lessThan(0.3));
      t.begin(at + 2000, replay: true);
      expect(t.replays, 1);
      expect(t.timeLeft, 1);
      expect(t.heldMs, held);
      expect(t.status, SingStatus.waiting);
      sing(t, (_) => hz(57), at + 2000, 900);
      expect(t.done, isTrue);
      expect(t.result(SingOutcome.success).replays, 1);
    });

    test('a long gap between readings is not counted as held time', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      sing(t, (_) => hz(57), 0, 300);
      t.add(hz(57), 5000);
      expect(t.heldMs, lessThan(500));
    });
  });

  group('scoring', () {
    double f(SingOutcome o,
            {double? mean, double? best, int? lock, double hold = 0, int replays = 0}) =>
        SingNoteGame.noteFraction(
            outcome: o,
            meanAbsCents: mean,
            bestAbsCents: best,
            lockMs: lock,
            holdProgress: hold,
            replays: replays);

    test('a quick, accurate note is full marks', () {
      expect(f(SingOutcome.success, mean: 3, lock: 900), 1);
      expect(f(SingOutcome.success, mean: 5, lock: 1500), 1);
    });

    test('accuracy and speed each cost a share', () {
      expect(f(SingOutcome.success, mean: 25, lock: 900), closeTo(0.75, 1e-9));
      expect(f(SingOutcome.success, mean: 15, lock: 900), closeTo(0.875, 1e-9));
      expect(f(SingOutcome.success, mean: 3, lock: 5000), closeTo(0.85, 1e-9));
      expect(f(SingOutcome.success, mean: 3, lock: 3250), closeTo(0.925, 1e-9));
      expect(f(SingOutcome.success, mean: 30, lock: 9000), closeTo(0.6, 1e-9));
    });

    test('replays cost a little, capped', () {
      expect(f(SingOutcome.success, mean: 3, lock: 900, replays: 1), closeTo(0.95, 1e-9));
      expect(f(SingOutcome.success, mean: 3, lock: 900, replays: 9), closeTo(0.85, 1e-9));
      expect(f(SingOutcome.timeout, replays: 2), 0);
    });

    test('timeouts earn partial credit for closeness or hold, at most half', () {
      expect(f(SingOutcome.timeout), 0);
      expect(f(SingOutcome.timeout, best: 250), 0);
      expect(f(SingOutcome.timeout, best: 25), closeTo(0.35, 1e-9));
      expect(f(SingOutcome.timeout, best: 112.5), closeTo(0.175, 1e-9));
      expect(f(SingOutcome.timeout, best: 10, hold: 0.9), closeTo(0.45, 1e-9));
      expect(f(SingOutcome.timeout, best: 10, hold: 1), lessThan(f(SingOutcome.success, mean: 30, lock: 9000)));
      expect(f(SingOutcome.skipped, mean: 1, best: 1, lock: 1, hold: 1), 0);
    });

    test('totals, stars and messages', () {
      SingNoteResult r(double fraction) =>
          SingNoteResult(midi: 60, outcome: SingOutcome.success, fraction: fraction);
      expect(SingNoteGame.total([]), 0);
      expect(SingNoteGame.total(List.filled(8, r(1))), 100);
      expect(SingNoteGame.total([...List.filled(4, r(1)), ...List.filled(4, r(0))]), 50);
      expect(SingNoteGame.total([r(1)], count: 8), 13); // 12.5 a note
      expect(SingNoteGame.total([r(0.8), r(0.75)]), 78);

      expect(SingNoteGame.stars(100), 3);
      expect(SingNoteGame.stars(85), 3);
      expect(SingNoteGame.stars(84), 2);
      expect(SingNoteGame.stars(55), 2);
      expect(SingNoteGame.stars(54), 1);
      expect(SingNoteGame.stars(0), 1);

      expect(SingNoteGame.message(95), 'Pitch perfect!');
      expect(SingNoteGame.message(75), 'Nice ear');
      expect(SingNoteGame.message(50), 'Getting there');
      expect(SingNoteGame.message(10), 'Keep practising');
    });

    test('grades', () {
      final t = SingNoteTracker(targetMidi: 57)..begin(0);
      sing(t, (_) => hz(57, 60), 0, 6100);
      final r = t.result(SingOutcome.timeout);
      expect(r.grade, SingGrade.close);
      expect(r.fraction, closeTo(0.35 * (1 - 35 / 175), 1e-6));
      expect(t.result(SingOutcome.skipped).grade, SingGrade.miss);
      final u = SingNoteTracker(targetMidi: 57)..begin(0);
      sing(u, (_) => hz(57, 2), 0, 1300);
      final hit = u.result(SingOutcome.success);
      expect(hit.grade, SingGrade.hit);
      expect(hit.fraction, 1);
    });
  });

  group('with the real pitch detector', () {
    SingNoteTracker run(int target, List<double> samples) {
      final t = SingNoteTracker(targetMidi: target)..begin(0);
      late final PitchDetector d;
      d = PitchDetector(
        minHz: 70,
        maxHz: 1000,
        minClarity: 0.8,
        silenceRms: 0.008,
        onReading: (r) => t.add(r?.hz, d.audioMs),
      );
      d.addSamples(samples);
      return t;
    }

    test('a voice with vibrato locks on, in several octaves', () {
      for (final (target, sung) in [(57, 57), (57, 45), (69, 45), (60, 72), (53, 41), (66, 78)]) {
        final t = run(target, voice(hz(sung, 5), seconds: 1.8));
        expect(t.done, isTrue, reason: '$sung for $target');
        expect(t.meanAbsCents, lessThan(18), reason: '$sung for $target');
        expect(t.lockMs, lessThan(400));
      }
    });

    test('a wrong note is not accepted and points the right way', () {
      final low = run(57, voice(hz(43), seconds: 1.5)); // G, a tone below A
      expect(low.done, isFalse);
      expect(low.heldMs, 0);
      expect(low.status, SingStatus.low);
      expect(low.cents, closeTo(-200, 25));
      final high = run(57, voice(hz(59, 30), seconds: 1.5));
      expect(high.status, SingStatus.high);
      expect(high.heldMs, 0);
    });

    test('silence and noise do nothing', () {
      final rnd = Random(2);
      final t = run(57, [
        ...List.filled(44100, 0.0),
        ...List.generate(44100, (_) => (rnd.nextDouble() * 2 - 1) * 0.2),
      ]);
      expect(t.status, SingStatus.waiting);
      expect(t.heldMs, 0);
      expect(t.bestAbsCents, isNull);
    });
  });
}
