import 'dart:math';

import 'guitar_tuning.dart' show hzToMidi;

/// Pure logic for the "Sing the Note" game: which notes to play, how a sung
/// pitch compares with the target, when a note counts as held, and scoring.

/// How far [hz] is from the nearest octave of [targetMidi], in cents.
///
/// Voices sit in different octaves, so only the pitch class matters: a low
/// voice humming an octave (or two) below the tone still matches. The result
/// is in [-600, 600): negative = too low, positive = too high.
double foldedCents(double hz, int targetMidi) {
  final cents = (hzToMidi(hz) - targetMidi) * 100;
  final folded = (cents + 600) % 1200 - 600; // Dart's % is never negative
  return folded;
}

enum SingStatus { waiting, low, high, inTune }

enum SingOutcome { success, timeout, skipped }

/// How a note went, for the results row: ✓ / ≈ / ✗.
enum SingGrade { hit, close, miss }

class SingNoteResult {
  final int midi;
  final SingOutcome outcome;

  /// 0..1 share of this note's points.
  final double fraction;

  /// Mean distance from the note while holding it, in cents.
  final double? meanAbsCents;

  /// Closest the voice got, in cents (null if nothing was sung).
  final double? bestAbsCents;

  /// Singing time before first landing on the note.
  final int? lockMs;
  final int replays;

  const SingNoteResult({
    required this.midi,
    required this.outcome,
    required this.fraction,
    this.meanAbsCents,
    this.bestAbsCents,
    this.lockMs,
    this.replays = 0,
  });

  SingGrade get grade => outcome == SingOutcome.success
      ? SingGrade.hit
      : (fraction >= 0.15 ? SingGrade.close : SingGrade.miss);
}

class SingNoteGame {
  SingNoteGame._();

  /// Notes per round.
  static const roundLength = 8;

  /// Reference tones come from F3–C5: clear on a phone speaker and easy to
  /// place for any voice (the octave doesn't matter when singing back).
  static const lowestMidi = 53;
  static const highestMidi = 72;

  /// Within this many cents (after smoothing) counts as on the note…
  static const toleranceCents = 25.0;

  /// …and once on it, the voice may drift this much further before it
  /// counts as off again (stops flicker at the edge).
  static const hysteresisCents = 6.0;

  /// In-tune time needed to finish a note.
  static const holdMs = 1000;

  /// Singing time allowed per note.
  static const limitMs = 6000;

  /// A hold in progress at the limit may run on this long to finish.
  static const graceMs = 1500;

  static const _naturals = [0, 2, 4, 5, 7, 9, 11];
  static const _sharps = [1, 3, 6, 8, 10];

  /// Target notes (MIDI) for a round: natural notes first, the last third
  /// sharps. No pitch class repeats while there are unused ones.
  static List<int> pickNotes(Random rng, {int count = roundLength}) {
    final sharpCount = count >= 3 ? count ~/ 3 : 0;
    final out = <int>[];
    void take(List<int> classes, int n) {
      var pool = <int>[];
      for (var i = 0; i < n; i++) {
        if (pool.isEmpty) pool = [...classes]..shuffle(rng);
        // Avoid the same note twice in a row across a reshuffle.
        if (out.isNotEmpty && pool.length > 1 && pool.last == out.last % 12) {
          pool.insert(0, pool.removeLast());
        }
        final pc = pool.removeLast();
        final options = [
          for (var m = lowestMidi; m <= highestMidi; m++)
            if (m % 12 == pc) m,
        ];
        out.add(options[rng.nextInt(options.length)]);
      }
    }

    take(_naturals, count - sharpCount);
    take(_sharps, sharpCount);
    return out;
  }

  /// Share (0..1) of a note's points.
  ///
  /// Held it: 60 % for landing it, up to 25 % for accuracy (mean distance
  /// while holding: ≤ 5 cents is full marks, the tolerance edge none) and up
  /// to 15 % for speed (on the note within 1.5 s of singing time is full
  /// marks, 5 s none).
  ///
  /// Ran out of time: up to half, for how much of the hold was done or how
  /// close the voice got. Each "hear it again" costs 5 % (at most 15 %).
  static double noteFraction({
    required SingOutcome outcome,
    double? meanAbsCents,
    double? bestAbsCents,
    int? lockMs,
    double holdProgress = 0,
    int replays = 0,
    double tolerance = toleranceCents,
  }) {
    double f;
    switch (outcome) {
      case SingOutcome.skipped:
        return 0;
      case SingOutcome.success:
        final acc =
            1 -
            (((meanAbsCents ?? tolerance) - 5) / (tolerance - 5)).clamp(
              0.0,
              1.0,
            );
        final speed = 1 - (((lockMs ?? 5000) - 1500) / 3500).clamp(0.0, 1.0);
        f = 0.6 + 0.25 * acc + 0.15 * speed;
      case SingOutcome.timeout:
        final closeness = bestAbsCents == null
            ? 0.0
            : 1 -
                  ((bestAbsCents - tolerance) / (200 - tolerance)).clamp(
                    0.0,
                    1.0,
                  );
        f = max(0.5 * holdProgress.clamp(0.0, 1.0), 0.35 * closeness);
    }
    f -= 0.05 * min(replays, 3);
    return f.clamp(0.0, 1.0);
  }

  /// Round score, 0–100.
  static int total(List<SingNoteResult> results, {int? count}) {
    final n = count ?? results.length;
    if (n == 0) return 0;
    final sum = results.fold<double>(0, (a, r) => a + r.fraction);
    return (sum / n * 100).round().clamp(0, 100);
  }

  static int stars(int score) => score >= 85 ? 3 : (score >= 55 ? 2 : 1);

  static String message(int score) {
    if (score >= 90) return 'Pitch perfect!';
    if (score >= 70) return 'Nice ear';
    if (score >= 45) return 'Getting there';
    return 'Keep practising';
  }
}

/// Follows the voice against one target note.
///
/// Feed it every pitch reading (null = silence / no clear pitch) with the
/// audio clock. Readings are folded to the target's octave and smoothed with
/// a short median, so vibrato, a breathy frame or a stray octave error
/// doesn't knock the hold. In-tune time adds up (it needn't be one unbroken
/// stretch); [done] turns true after [holdTargetMs] of it.
class SingNoteTracker {
  final int targetMidi;
  final double tolerance;
  final int holdTargetMs;
  final int limitMs;

  SingNoteTracker({
    required this.targetMidi,
    this.tolerance = SingNoteGame.toleranceCents,
    this.holdTargetMs = SingNoteGame.holdMs,
    this.limitMs = SingNoteGame.limitMs,
  });

  static const _medianOf = 5;

  /// Shortest run of readings that counts as a sung pitch.
  static const _minStable = 3;

  /// Readings missing in a row before the voice is considered stopped.
  static const _maxMisses = 3;

  /// Longest gap between readings that still counts as continuous time.
  static const _maxStepMs = 120;

  final List<double> _recent = [];
  int _misses = 0;
  int _fromMs = 0;
  int? _lastMs;
  bool _begun = false;

  int _windowMs = 0; // singing time since the last begin()
  int _totalMs = 0; // singing time over all attempts
  double _absSum = 0;
  int _absCount = 0;

  /// Smoothed distance from the note, in cents; null when not singing.
  double? get cents => _cents;
  double? _cents;

  SingStatus get status => _status;
  SingStatus _status = SingStatus.waiting;

  int get heldMs => _heldMs;
  int _heldMs = 0;

  /// 0..1 of the hold.
  double get progress => (_heldMs / holdTargetMs).clamp(0.0, 1.0);

  bool get done => _heldMs >= holdTargetMs;

  /// 1 → 0 as the time for this attempt runs out.
  double get timeLeft => (1 - _windowMs / limitMs).clamp(0.0, 1.0);

  /// Out of time — unless a hold is under way, which gets a short grace.
  bool get timedOut {
    if (done || _windowMs < limitMs) return false;
    return !(_status == SingStatus.inTune &&
        _windowMs < limitMs + SingNoteGame.graceMs);
  }

  int get replays => _replays;
  int _replays = 0;

  int? get lockMs => _lockMs;
  int? _lockMs;

  double? get bestAbsCents => _best;
  double? _best;

  double? get meanAbsCents => _absCount == 0 ? null : _absSum / _absCount;

  /// Starts (or, after "hear it again", restarts) the singing window.
  /// Readings before [fromMs] are ignored — the mic is still hearing the
  /// reference tone. Hold progress carries over a restart.
  void begin(int fromMs, {bool replay = false}) {
    if (replay && _begun) _replays++;
    _begun = true;
    _fromMs = fromMs;
    _lastMs = null;
    _windowMs = 0;
    _recent.clear();
    _misses = 0;
    _cents = null;
    _status = SingStatus.waiting;
  }

  SingStatus add(double? hz, int ms) {
    if (!_begun || ms < _fromMs || done) return _status;
    final last = _lastMs;
    final dt = last == null ? 0 : (ms - last).clamp(0, _maxStepMs);
    _lastMs = ms;
    _windowMs += dt;
    _totalMs += dt;

    if (hz == null || hz <= 0) {
      if (++_misses >= _maxMisses) {
        _recent.clear();
        _cents = null;
        _status = SingStatus.waiting;
      }
      return _status;
    }
    _misses = 0;
    _recent.add(foldedCents(hz, targetMidi));
    if (_recent.length > _medianOf) _recent.removeAt(0);
    if (_recent.length < _minStable) return _status;

    final c = _median(_recent);
    _cents = c;
    final a = c.abs();
    if (_best == null || a < _best!) _best = a;

    final edge = _status == SingStatus.inTune
        ? tolerance + SingNoteGame.hysteresisCents
        : tolerance;
    if (a <= edge) {
      // The step that first lands on the note doesn't count as held time.
      if (_status == SingStatus.inTune) _heldMs += dt;
      _status = SingStatus.inTune;
      _lockMs ??= _totalMs;
      _absSum += a;
      _absCount++;
    } else {
      _status = c < 0 ? SingStatus.low : SingStatus.high;
    }
    return _status;
  }

  static double _median(List<double> values) {
    final s = [...values]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
  }

  SingNoteResult result(SingOutcome outcome) => SingNoteResult(
    midi: targetMidi,
    outcome: outcome,
    fraction: SingNoteGame.noteFraction(
      outcome: outcome,
      meanAbsCents: meanAbsCents,
      bestAbsCents: _best,
      lockMs: _lockMs,
      holdProgress: progress,
      replays: _replays,
      tolerance: tolerance,
    ),
    meanAbsCents: meanAbsCents,
    bestAbsCents: _best,
    lockMs: _lockMs,
    replays: _replays,
  );
}
