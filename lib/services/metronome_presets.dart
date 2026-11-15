import 'dart:convert';

import 'clip_repository.dart';

const int kMetronomeMinBpm = 40;
const int kMetronomeMaxBpm = 240;

/// Beats per bar the metronome offers (2/4, 3/4, 4/4, 6/8).
const List<int> kMetronomeBeats = [2, 3, 4, 6];

/// The most saved tempos kept.
const int kMetronomeMaxPresets = 20;

/// Longest preset name kept.
const int kMetronomePresetNameMax = 28;

/// How each beat is split into clicks.
///
/// A "beat" is one dot on the metronome: a quarter note in 2/4, 3/4 and 4/4,
/// and an eighth note in 6/8 (where the BPM counts eighth notes). The
/// subdivision always splits that beat, so in 6/8 "eighths" gives two clicks
/// per eighth-note beat.
enum MetronomeSubdivision {
  none(1, 'No subdivision', 'off'),
  eighths(2, 'Eighths', '8ths'),
  triplets(3, 'Triplets', 'triplets'),
  sixteenths(4, 'Sixteenths', '16ths');

  const MetronomeSubdivision(this.clicksPerBeat, this.label, this.shortLabel);

  final int clicksPerBeat;
  final String label;
  final String shortLabel;

  static MetronomeSubdivision fromClicks(Object? clicks) =>
      values.firstWhere((s) => s.clicksPerBeat == clicks, orElse: () => none);
}

/// Which sound a click plays.
enum ClickKind {
  /// The first beat of the bar.
  accent,

  /// Any other beat.
  beat,

  /// A subdivision between beats (quieter, lower).
  sub,
}

/// The click at sub-tick [tick] (0 = the downbeat the metronome started on),
/// with [clicksPerBeat] ticks to a beat.
ClickKind clickKindAt(
  int tick, {
  required int beatsPerBar,
  required int clicksPerBeat,
}) {
  if (tick % clicksPerBeat != 0) return ClickKind.sub;
  return (tick ~/ clicksPerBeat) % beatsPerBar == 0
      ? ClickKind.accent
      : ClickKind.beat;
}

/// The beat within the bar (0-based) that sub-tick [tick] falls in.
int beatAt(int tick, {required int beatsPerBar, required int clicksPerBeat}) =>
    (tick ~/ clicksPerBeat) % beatsPerBar;

/// When sub-tick [tick] sounds, in microseconds after the first click.
/// Computed from the tick index (never by adding up intervals) so rounding
/// can't accumulate into drift.
int clickTimeMicros(int tick, {required int bpm, required int clicksPerBeat}) =>
    (tick * 60000000 / (bpm * clicksPerBeat)).round();

String metronomeSignatureLabel(int beatsPerBar) =>
    beatsPerBar == 6 ? '6/8' : '$beatsPerBar/4';

/// A tempo, time signature and subdivision.
class MetronomeSetup {
  const MetronomeSetup({
    this.bpm = 120,
    this.beatsPerBar = 4,
    this.subdivision = MetronomeSubdivision.none,
  });

  final int bpm;
  final int beatsPerBar;
  final MetronomeSubdivision subdivision;

  /// e.g. "87 BPM · 4/4 · 8ths".
  String get summary => [
    '$bpm BPM',
    metronomeSignatureLabel(beatsPerBar),
    if (subdivision != MetronomeSubdivision.none) subdivision.shortLabel,
  ].join(' · ');

  Map<String, Object> toJson() => {
    'bpm': bpm,
    'beats': beatsPerBar,
    'sub': subdivision.clicksPerBeat,
  };

  /// Reads a setup, repairing out-of-range values; null if [json] isn't one.
  static MetronomeSetup? fromJson(Object? json) {
    if (json is! Map) return null;
    final bpm = json['bpm'];
    if (bpm is! num || !bpm.isFinite) return null;
    final beats = json['beats'];
    return MetronomeSetup(
      bpm: bpm.round().clamp(kMetronomeMinBpm, kMetronomeMaxBpm),
      beatsPerBar: kMetronomeBeats.contains(beats) ? beats as int : 4,
      subdivision: MetronomeSubdivision.fromClicks(json['sub']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MetronomeSetup &&
      other.bpm == bpm &&
      other.beatsPerBar == beatsPerBar &&
      other.subdivision == subdivision;

  @override
  int get hashCode => Object.hash(bpm, beatsPerBar, subdivision);

  @override
  String toString() => 'MetronomeSetup($summary)';
}

/// A saved, named [MetronomeSetup].
class MetronomePreset {
  const MetronomePreset({required this.name, required this.setup});

  /// May be empty, in which case [title] falls back to the tempo.
  final String name;
  final MetronomeSetup setup;

  String get title => name.isEmpty ? '${setup.bpm} BPM' : name;

  MetronomePreset renamed(String name) =>
      MetronomePreset(name: cleanPresetName(name), setup: setup);

  Map<String, Object> toJson() => {'name': name, ...setup.toJson()};

  static MetronomePreset? fromJson(Object? json) {
    final setup = MetronomeSetup.fromJson(json);
    if (setup == null) return null;
    final name = (json as Map)['name'];
    return MetronomePreset(
      name: cleanPresetName(name is String ? name : ''),
      setup: setup,
    );
  }
}

/// Trims [name], collapses whitespace and caps the length.
String cleanPresetName(String name) {
  final s = name.trim().replaceAll(RegExp(r'\s+'), ' ');
  return s.length <= kMetronomePresetNameMax
      ? s
      : s.substring(0, kMetronomePresetNameMax).trimRight();
}

String encodePresets(List<MetronomePreset> presets) =>
    jsonEncode([for (final p in presets) p.toJson()]);

/// Decodes saved presets. Anything unreadable is dropped rather than thrown:
/// bad JSON gives an empty list, bad entries are skipped, and at most
/// [kMetronomeMaxPresets] are kept.
List<MetronomePreset> decodePresets(String? json) {
  if (json == null || json.isEmpty) return [];
  final Object? data;
  try {
    data = jsonDecode(json);
  } catch (_) {
    return [];
  }
  if (data is! List) return [];
  final out = <MetronomePreset>[];
  for (final item in data) {
    final p = MetronomePreset.fromJson(item);
    if (p != null) out.add(p);
    if (out.length == kMetronomeMaxPresets) break;
  }
  return out;
}

String encodeSetup(MetronomeSetup setup) => jsonEncode(setup.toJson());

/// Decodes the last-used setup; null if missing or unreadable.
MetronomeSetup? decodeSetup(String? json) {
  if (json == null || json.isEmpty) return null;
  try {
    return MetronomeSetup.fromJson(jsonDecode(json));
  } catch (_) {
    return null;
  }
}

/// Where the metronome keeps its saved tempos and last-used setup.
abstract class MetronomeStore {
  static const presetsKey = 'metronome_presets';
  static const lastKey = 'metronome_last';

  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// The app's settings table.
class SettingsMetronomeStore implements MetronomeStore {
  const SettingsMetronomeStore();

  @override
  Future<String?> read(String key) => ClipRepository.getString(key);

  @override
  Future<void> write(String key, String value) =>
      ClipRepository.setString(key, value);
}

/// Keeps values in memory (tests and previews).
class MemoryMetronomeStore implements MetronomeStore {
  MemoryMetronomeStore([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
