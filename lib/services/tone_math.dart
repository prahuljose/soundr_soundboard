import 'dart:math';

import 'guitar_tuning.dart';

// Pure helpers for the tone generator and pitch pipe. No Flutter, no audio,
// so everything here is unit tested.

const double kMinHz = 20;
const double kMaxHz = 20000;

/// Above this a tone is hard for many people to hear, which tempts them to
/// turn the volume up.
const double kHighHz = 15000;

/// Volume (0..1) above which the caution line shows.
const double kLoudVolume = 0.8;

/// The waveforms on offer. Kept separate from the audio engine's enum so the
/// maths stays independent of it.
enum ToneWave { sine, square, triangle, saw }

extension ToneWaveLabel on ToneWave {
  String get label => switch (this) {
    ToneWave.sine => 'Sine',
    ToneWave.square => 'Square',
    ToneWave.triangle => 'Triangle',
    ToneWave.saw => 'Saw',
  };
}

double clampHz(double hz) =>
    hz.isNaN ? kMinHz : hz.clamp(kMinHz, kMaxHz).toDouble();

// ── Log scale ───────────────────────────────────────────────────────────────

final double _decades = log(kMaxHz / kMinHz) / ln10; // 3

/// 0..1 → 20 Hz..20 kHz, evenly spaced per octave (log scale).
double sliderToHz(double t) {
  final x = t.isNaN ? 0.0 : t.clamp(0.0, 1.0).toDouble();
  if (x == 0) return kMinHz;
  if (x == 1) return kMaxHz;
  return kMinHz * pow(10, x * _decades).toDouble();
}

/// Inverse of [sliderToHz].
double hzToSlider(double hz) {
  final f = clampHz(hz);
  if (f == kMinHz) return 0;
  if (f == kMaxHz) return 1;
  return (log(f / kMinHz) / ln10) / _decades;
}

// ── Steps & rounding ────────────────────────────────────────────────────────

/// The −/+ step at [hz]: 1 Hz below 1 kHz, 10 Hz below 10 kHz, 100 Hz above.
double fineStep(double hz) => hz < 1000
    ? 1
    : hz < 10000
    ? 10
    : 100;

/// One step up ([up]) or down from [hz], landing on the step grid so
/// 440.4 → 441 and 1000 → 999 going down (the finer step below 1 kHz).
/// [multiplier] makes bigger jumps while a button is held.
double nudgeHz(double hz, {required bool up, int multiplier = 1}) {
  final f = clampHz(hz);
  // Going down from exactly a boundary uses the finer step below it.
  final step = fineStep(up ? f : f - 1e-9) * multiplier;
  final q = f / step;
  final onGrid = (q - q.round()).abs() < 1e-6;
  final double next;
  if (up) {
    next = (onGrid ? q.round() + 1 : q.ceil()) * step;
  } else {
    next = (onGrid ? q.round() - 1 : q.floor()) * step;
  }
  return clampHz(_tidy(next));
}

/// Rounds a dragged value to something tidy for its range: whole Hz below
/// 1 kHz, 10 Hz below 10 kHz, 100 Hz above. 1 Hz below 100 Hz too, so the
/// low end still moves smoothly.
double snapHz(double hz) {
  final f = clampHz(hz);
  final step = fineStep(f);
  return clampHz(_tidy((f / step).round() * step));
}

/// Strips floating point noise (e.g. 440.00000000001).
double _tidy(double v) => (v * 1000).round() / 1000;

// ── Formatting ──────────────────────────────────────────────────────────────

String _trim(String s) =>
    s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;

/// Number and unit separately, for the big readout: (`"440"`, `"Hz"`),
/// (`"1.25"`, `"kHz"`), (`"15"`, `"kHz"`).
(String, String) formatHzParts(double hz) {
  if (hz >= 1000) {
    final k = (hz / 1000 * 1000).round() / 1000; // 3 dp of kHz = 1 Hz
    return (_trim(k.toStringAsFixed(3)), 'kHz');
  }
  final r = (hz * 10).round() / 10;
  if (r >= 1000) return ('1', 'kHz');
  return (_trim(r.toStringAsFixed(1)), 'Hz');
}

/// "440 Hz", "440.5 Hz", "1.25 kHz", "15 kHz".
String formatHz(double hz) {
  final (n, u) = formatHzParts(hz);
  return '$n $u';
}

/// "+0 cents", "−12 cents" (true minus sign, as on the tuner).
String formatCents(int cents) => '${cents < 0 ? '−' : '+'}${cents.abs()} cents';

// ── Notes ───────────────────────────────────────────────────────────────────

/// The note nearest a frequency, and how far off it is.
class NearestNote {
  final int midi;

  /// −50..+50, rounded.
  final int cents;

  const NearestNote(this.midi, this.cents);

  /// "A4", "C#5".
  String get name => '${noteName(midi)}${noteOctave(midi)}';

  /// "A4 · +0 cents"
  String get label => '$name · ${formatCents(cents)}';
}

NearestNote nearestNote(double hz, {double a4 = 440}) {
  final m = hzToMidi(clampHz(hz), a4: a4);
  final midi = m.round();
  return NearestNote(midi, ((m - midi) * 100).round());
}

// ── Sweep ───────────────────────────────────────────────────────────────────

/// Frequency of a log sweep from [from] to [to] Hz, [t] seconds into a
/// sweep lasting [seconds]. Equal time per octave, which is how a sweep
/// sounds even. Clamped to the ends outside 0..[seconds].
double sweepHz(
  double t, {
  double from = kMinHz,
  double to = kMaxHz,
  double seconds = 10,
}) {
  if (seconds <= 0 || t >= seconds) return to;
  if (t <= 0) return from;
  return from * pow(to / from, t / seconds).toDouble();
}

// ── Typed entry ─────────────────────────────────────────────────────────────

/// Parses what someone typed: "440", "440.5", "440 Hz", "1k", "1.5 kHz",
/// "1,000". Returns null if it isn't a positive number. Does not clamp;
/// see [inAudibleRange].
double? parseHz(String input) {
  var s = input.trim().toLowerCase().replaceAll(RegExp(r'[\s,_]'), '');
  if (s.isEmpty) return null;
  var scale = 1.0;
  if (s.endsWith('khz')) {
    scale = 1000;
    s = s.substring(0, s.length - 3);
  } else if (s.endsWith('hz')) {
    s = s.substring(0, s.length - 2);
  } else if (s.endsWith('k')) {
    scale = 1000;
    s = s.substring(0, s.length - 1);
  }
  if (!RegExp(r'^(\d+\.?\d*|\.\d+)$').hasMatch(s)) return null;
  final v = double.tryParse(s);
  if (v == null || v <= 0) return null;
  return _tidy(v * scale);
}

bool inAudibleRange(double hz) => hz >= kMinHz && hz <= kMaxHz;

// ── Loudness ────────────────────────────────────────────────────────────────

/// Engine volume for a slider position (0..1) and waveform.
///
/// The slider is squared so it feels even to the ear. Each waveform gets
/// its own gain so switching shape doesn't jump in loudness: square and saw
/// carry far more energy (and harmonics the ear is sensitive to) than a
/// sine at the same peak. Never above 1, so nothing clips.
double toneGain(double volume, ToneWave wave) {
  final v = volume.isNaN ? 0.0 : volume.clamp(0.0, 1.0).toDouble();
  final shape = switch (wave) {
    ToneWave.sine => 1.0,
    ToneWave.triangle => 1.0,
    ToneWave.saw => 0.7,
    ToneWave.square => 0.5,
  };
  return min(1.0, v * v * shape);
}

bool showCaution(double hz, double volume) =>
    hz > kHighHz || volume > kLoudVolume;

// ── Drawing ─────────────────────────────────────────────────────────────────

/// One period of [wave] at [phase] (cycles; any real number), −1..1.
/// Starts at zero rising, like the engine's oscillator, for sine,
/// triangle and saw.
double waveSample(ToneWave wave, double phase) {
  final p = phase - phase.floorToDouble(); // 0..1
  return switch (wave) {
    ToneWave.sine => sin(2 * pi * p),
    ToneWave.square => p < 0.5 ? 1 : -1,
    ToneWave.triangle =>
      p < 0.25
          ? 4 * p
          : p < 0.75
          ? 2 - 4 * p
          : 4 * p - 4,
    ToneWave.saw => p < 0.5 ? 2 * p : 2 * p - 2,
  };
}

// ── Pitch pipe ──────────────────────────────────────────────────────────────

const int kMinOctave = 2;
const int kMaxOctave = 6;

/// MIDI note for pitch class [pc] (0 = C … 11 = B) in [octave] (C4 = 60).
int pipeMidi(int pc, int octave) => (octave + 1) * 12 + pc;

/// The guitar tuner's saved A4 calibration ("440", "442"…), if sensible.
double parseA4(String? saved) {
  final v = int.tryParse(saved?.trim() ?? '');
  return v != null && v >= 430 && v <= 450 ? v.toDouble() : 440;
}
