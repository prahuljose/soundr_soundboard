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

/// The pitch range the detector listens for. A lower [minHz] needs a longer
/// analysis window (more latency, more work), so each instrument gets the
/// narrowest range that still hears a badly out-of-tune string.
class DetectorConfig {
  final double minHz;
  final double maxHz;

  /// See [PitchDetector.downsample].
  final int downsample;

  const DetectorConfig(this.minHz, this.maxHz, {this.downsample = 2});

  PitchDetector build({
    required int sampleRate,
    required void Function(PitchReading?) onReading,
  }) => PitchDetector(
    sampleRate: sampleRate,
    minHz: minHz,
    maxHz: maxHz,
    downsample: downsample,
    onReading: onReading,
  );
}

/// One way of tuning an instrument's strings. (Named for the guitar, which
/// came first; it serves every instrument.)
class GuitarTuning {
  final String id;
  final String name;

  /// MIDI notes in the order the strings sit on the instrument, from the
  /// highest-numbered string to string 1 — for a guitar that's low E (6th)
  /// to high E (1st). NOT necessarily ascending: a ukulele's 4th string is
  /// a high G ("re-entrant" tuning).
  final List<int> strings;
  final bool flats;

  /// Overrides the instrument's detector range (e.g. cello among violins).
  final DetectorConfig? detector;

  const GuitarTuning(
    this.id,
    this.name,
    this.strings, {
    this.flats = false,
    this.detector,
  });

  /// "E A D G B E"
  String get letters => strings.map((m) => noteName(m, flats: flats)).join(' ');

  String label(int index) => noteName(strings[index], flats: flats);

  /// The number players use: 1 is the last string in [strings].
  int stringNumber(int index) => strings.length - index;

  /// Whether the strings rise in pitch all the way across.
  bool get reentrant {
    for (var i = 1; i < strings.length; i++) {
      if (strings[i] <= strings[i - 1]) return true;
    }
    return false;
  }
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

/// A guitar tuning by id (standard if unknown).
GuitarTuning tuningById(String? id) => guitar.tuningById(id);

// G3=55 C4=60 E4=64 G4=67 A4=69. String 4 first, as on the instrument.
const ukuleleTunings = [
  GuitarTuning('uke_standard', 'Standard', [67, 60, 64, 69]),
  GuitarTuning('uke_low_g', 'Low G', [55, 60, 64, 69]),
  GuitarTuning('uke_baritone', 'Baritone', [50, 55, 59, 64]),
  GuitarTuning('uke_d', 'D tuning', [69, 62, 66, 71]),
];

// B0=23 E1=28 A1=33 D2=38 G2=43
const bassTunings = [
  GuitarTuning('bass_standard', 'Standard', [28, 33, 38, 43]),
  GuitarTuning('bass_drop_d', 'Drop D', [26, 33, 38, 43]),
  GuitarTuning('bass_5', '5-string', [23, 28, 33, 38, 43]),
];

// The violin family, all in fifths. G3=55 D4=62 A4=69 E5=76
const violinTunings = [
  GuitarTuning('violin', 'Violin', [55, 62, 69, 76]),
  GuitarTuning('viola', 'Viola', [48, 55, 62, 69]),
  GuitarTuning('cello', 'Cello', [
    36,
    43,
    50,
    57,
  ], detector: DetectorConfig(55, 1400)),
];

/// How the tuner draws the top of the instrument.
enum HeadShape {
  /// Flat headstock with a shaped crown.
  guitar,

  /// Small flat headstock with a rounded top.
  ukulele,

  /// Broad, square-shouldered headstock.
  bass,

  /// Pegbox and scroll, pegs staggered.
  scroll,
}

class Instrument {
  final String id;
  final String name;
  final List<GuitarTuning> tunings;
  final DetectorConfig detector;
  final HeadShape head;

  /// The tunings are instruments in their own right (violin, viola, cello),
  /// so a tuning's name stands alone instead of "Violin · Viola".
  final bool family;

  /// Reference notes play an octave up: a phone speaker can't sound a bass.
  final bool referenceOctaveUp;

  const Instrument(
    this.id,
    this.name,
    this.tunings, {
    required this.detector,
    required this.head,
    this.family = false,
    this.referenceOctaveUp = false,
  });

  GuitarTuning tuningById(String? id) =>
      tunings.firstWhere((t) => t.id == id, orElse: () => tunings.first);

  DetectorConfig detectorFor(GuitarTuning tuning) =>
      tuning.detector ?? detector;

  /// "Ukulele · Low G", or just "Cello" in a family.
  String titleFor(GuitarTuning tuning) =>
      family ? tuning.name : '$name · ${tuning.name}';

  /// The frequency to play as the reference for [midi].
  double referenceHz(int midi, {double a4 = 440}) =>
      midiToHz(midi, a4: a4) * (referenceOctaveUp ? 2 : 1);
}

/// 60–1400 Hz: room below drop C (65.4 Hz) up to the high E's top frets.
const guitar = Instrument(
  'guitar',
  'Guitar',
  guitarTunings,
  detector: DetectorConfig(60, 1400),
  head: HeadShape.guitar,
);

/// Nothing lower than the baritone's D3 (147 Hz), so a short window: about
/// half the guitar's latency.
const ukulele = Instrument(
  'ukulele',
  'Ukulele',
  ukuleleTunings,
  detector: DetectorConfig(110, 1600),
  head: HeadShape.ukulele,
);

/// Down to a slack low B (B0 = 30.9 Hz). Analysed at a quarter of the
/// sample rate, which keeps the long window as cheap as the guitar's.
const bass = Instrument(
  'bass',
  'Bass',
  bassTunings,
  detector: DetectorConfig(26, 400, downsample: 4),
  head: HeadShape.bass,
  referenceOctaveUp: true,
);

/// Viola C3 (131 Hz) up past the violin's E5 (659 Hz). Analysed at the
/// full sample rate: at half rate a bright bowed note high on the E string
/// reads several cents out.
const violin = Instrument(
  'violin',
  'Violin',
  violinTunings,
  detector: DetectorConfig(110, 2000, downsample: 1),
  head: HeadShape.scroll,
  family: true,
);

const instruments = [guitar, ukulele, bass, violin];

/// An instrument by id (guitar if unknown).
Instrument instrumentById(String? id) =>
    instruments.firstWhere((i) => i.id == id, orElse: () => guitar);

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

  /// Index into the tuning's strings, or null in chromatic mode.
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

  /// Tune to every note instead of the instrument's strings.
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

  /// Every string of the current tuning, however many it has.
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
  /// between two targets doesn't flicker between them. Strings may be in
  /// any pitch order (re-entrant ukulele), so every one is compared.
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
