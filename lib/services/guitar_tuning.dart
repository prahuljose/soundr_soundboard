import 'dart:math';

import 'pitch_detector.dart';

// ── Notes ───────────────────────────────────────────────────────────────────

// '#' and 'b' rather than ♯/♭: the app font has no music symbols.
const _sharpNames = [
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];
const _flatNames = [
  'C',
  'Db',
  'D',
  'Eb',
  'E',
  'F',
  'Gb',
  'G',
  'Ab',
  'A',
  'Bb',
  'B',
];

/// Letter name without octave, e.g. "E", "F#", "Bb".
String noteName(int midi, {bool flats = false}) =>
    (flats ? _flatNames : _sharpNames)[midi % 12];

/// Scientific octave number (middle C = C4).
int noteOctave(int midi) => midi ~/ 12 - 1;

double midiToHz(num midi, {double a4 = 440}) =>
    a4 * pow(2, (midi - 69) / 12).toDouble();

double hzToMidi(double hz, {double a4 = 440}) => 69 + 12 * log(hz / a4) / ln2;

/// How far [hz] is from [midi], in cents (100 per semitone).
double centsOff(double hz, int midi, {double a4 = 440}) =>
    (hzToMidi(hz, a4: a4) - midi) * 100;

// ── Tunings ─────────────────────────────────────────────────────────────────

class GuitarTuning {
  final String id;
  final String name;

  /// MIDI notes, low (6th) string to high (1st) string.
  final List<int> strings;
  final bool flats;

  const GuitarTuning(this.id, this.name, this.strings, {this.flats = false});

  /// "E A D G B E"
  String get letters => strings.map((m) => noteName(m, flats: flats)).join(' ');

  String label(int index) => noteName(strings[index], flats: flats);
}

// E2=40 A2=45 D3=50 G3=55 B3=59 E4=64
const guitarTunings = [
  GuitarTuning('standard', 'Standard', [40, 45, 50, 55, 59, 64]),
  GuitarTuning('drop_d', 'Drop D', [38, 45, 50, 55, 59, 64]),
  GuitarTuning('half_down', 'Half step down', [
    39,
    44,
    49,
    54,
    58,
    63,
  ], flats: true),
  GuitarTuning('full_down', 'Full step down', [38, 43, 48, 53, 57, 62]),
  GuitarTuning('drop_c', 'Drop C', [36, 43, 48, 53, 57, 62]),
  GuitarTuning('open_g', 'Open G', [38, 43, 50, 55, 59, 62]),
  GuitarTuning('open_d', 'Open D', [38, 45, 50, 54, 57, 62]),
  GuitarTuning('dadgad', 'DADGAD', [38, 45, 50, 55, 57, 62]),
];

GuitarTuning tuningById(String? id) => guitarTunings.firstWhere(
  (t) => t.id == id,
  orElse: () => guitarTunings.first,
);

// ── Tuner engine ────────────────────────────────────────────────────────────

enum TunerStatus {
  /// Nothing heard yet, or the last note has faded.
  waiting,
  flat,
  inTune,
  sharp,
}

/// What the tuner screen shows. Immutable snapshot.
class TunerReading {
  final TunerStatus status;

  /// String index (0 = low string) being tuned, or null in chromatic mode.
  final int? stringIndex;

  /// The note being tuned to.
  final int? targetMidi;

  /// Smoothed distance from the target, in cents.
  final double? cents;

  /// Smoothed frequency heard.
  final double? hz;

  const TunerReading({
    this.status = TunerStatus.waiting,
    this.stringIndex,
    this.targetMidi,
    this.cents,
    this.hz,
  });

  bool get active => status != TunerStatus.waiting;
}

/// Turns raw [PitchReading]s into a steady tuner display.
///
/// * picks the string you're playing (auto) or tunes to the one chosen
///   (manual), or to the nearest note in chromatic mode;
/// * smooths with a short median so the needle doesn't jitter;
/// * ignores a note's fading tail, which is noisy, and holds the last value
///   briefly before going back to waiting;
/// * marks a string tuned once it has stayed in tune for [settleMs].
///
/// Time is passed in (milliseconds) so it can be tested without waiting.
class TunerEngine {
  GuitarTuning tuning;
  double a4;

  /// Tune to every note instead of the guitar's strings.
  bool chromatic;

  /// Manual mode: the string chosen on the headstock. Null = auto.
  int? lockedString;

  /// Within this many cents counts as in tune.
  static const inTuneCents = 5.0;

  /// In tune this long (ms) marks the string done.
  static const settleMs = 600;

  /// A tuned string this far out for [_untuneMs] loses its tick.
  static const _untuneCents = 15.0;
  static const _untuneMs = 800;

  /// After the last usable reading, keep showing it this long.
  static const holdMs = 1500;

  final Set<int> tuned = {};

  /// Called once each time a string becomes tuned.
  void Function(int stringIndex)? onStringTuned;

  TunerEngine({
    required this.tuning,
    this.a4 = 440,
    this.chromatic = false,
    this.lockedString,
    this.onStringTuned,
  });

  TunerReading _reading = const TunerReading();
  TunerReading get reading => _reading;

  final List<double> _recent = []; // recent pitches, in MIDI units
  double? _candidate; // a different note, waiting for confirmation
  int _lastVoicedMs = -1 << 30;
  double _notePeakRms = 0;
  double _prevRms = 0;
  int? _autoString;
  int? _inTuneSinceMs;
  int? _outSinceMs;

  /// Forget the current note (e.g. after changing tuning or mode).
  void resetNote() {
    _recent.clear();
    _candidate = null;
    _autoString = null;
    _inTuneSinceMs = null;
    _outSinceMs = null;
    _notePeakRms = 0;
    _reading = const TunerReading();
  }

  void resetTuned() => tuned.clear();

  bool get allTuned => !chromatic && tuned.length == tuning.strings.length;

  /// Feeds one detector result at time [nowMs]. Returns the new reading.
  TunerReading add(PitchReading? r, int nowMs) {
    // Note-tail gate: once a pluck has faded below a tenth of its peak
    // (-20 dB) it's mostly room noise and the reading wanders, so stop
    // trusting it. A sudden rise in level is a new pluck and resets the
    // peak, so a softer second pluck is still heard.
    final rms = r?.rms ?? 0;
    if (rms > _prevRms * 1.6 || rms > _notePeakRms) _notePeakRms = rms;
    _prevRms = rms;
    if (r != null && r.rms < _notePeakRms * 0.1) r = null;

    if (r == null) {
      if (nowMs - _lastVoicedMs > holdMs && _reading.active) {
        _recent.clear();
        _candidate = null;
        _inTuneSinceMs = null;
        _reading = TunerReading(
          stringIndex: chromatic ? null : (lockedString ?? _autoString),
          targetMidi: _reading.targetMidi,
        );
      }
      return _reading;
    }

    final m = hzToMidi(r.hz, a4: a4);
    // A jump of more than ~60 cents is a new note: only switch once two
    // readings in a row agree, so one stray frame can't move the needle.
    if (_recent.isNotEmpty && (m - _median()).abs() > 0.6) {
      final cand = _candidate;
      if (cand != null && (m - cand).abs() < 0.35) {
        _recent
          ..clear()
          ..add(cand);
        _candidate = null;
        _inTuneSinceMs = null;
      } else {
        _candidate = m;
        return _reading;
      }
    } else {
      _candidate = null;
    }
    _recent.add(m);
    if (_recent.length > 5) _recent.removeAt(0);
    _lastVoicedMs = nowMs;

    final heard = _median();
    final int? stringIndex;
    final int target;
    if (chromatic) {
      stringIndex = null;
      target = heard.round();
    } else if (lockedString != null) {
      stringIndex = lockedString!.clamp(0, tuning.strings.length - 1);
      target = tuning.strings[stringIndex];
    } else {
      stringIndex = _nearestString(heard);
      target = tuning.strings[stringIndex];
    }

    final cents = (heard - target) * 100;
    final status = cents.abs() <= inTuneCents
        ? TunerStatus.inTune
        : cents < 0
        ? TunerStatus.flat
        : TunerStatus.sharp;

    _trackTuned(stringIndex, cents, nowMs);

    _reading = TunerReading(
      status: status,
      stringIndex: stringIndex,
      targetMidi: target,
      cents: cents,
      hz: a4 * pow(2, (heard - 69) / 12).toDouble(),
    );
    return _reading;
  }

  double _median() {
    final s = [..._recent]..sort();
    final n = s.length;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
  }

  /// Closest string, with a little stickiness so a string that's half way
  /// between two targets doesn't flicker between them.
  int _nearestString(double m) {
    var best = 0;
    for (var i = 1; i < tuning.strings.length; i++) {
      if ((m - tuning.strings[i]).abs() < (m - tuning.strings[best]).abs()) {
        best = i;
      }
    }
    final current = _autoString;
    if (current != null &&
        current != best &&
        (m - tuning.strings[current]).abs() - (m - tuning.strings[best]).abs() <
            0.3) {
      best = current;
    }
    return _autoString = best;
  }

  void _trackTuned(int? stringIndex, double cents, int nowMs) {
    if (stringIndex == null) return;
    if (cents.abs() <= inTuneCents) {
      _outSinceMs = null;
      final since = _inTuneSinceMs ??= nowMs;
      if (nowMs - since >= settleMs && tuned.add(stringIndex)) {
        onStringTuned?.call(stringIndex);
      }
    } else {
      _inTuneSinceMs = null;
      if (tuned.contains(stringIndex) && cents.abs() > _untuneCents) {
        final since = _outSinceMs ??= nowMs;
        if (nowMs - since >= _untuneMs) tuned.remove(stringIndex);
      } else {
        _outSinceMs = null;
      }
    }
  }
}
