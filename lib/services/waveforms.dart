import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/sound_model.dart';

/// Peak-envelope waveforms for drawing, decoded once per sound and cached.
///
/// Uses SoLoud's sample reader (works for wav and mp3). If decoding fails for
/// any reason, a stable pseudo-waveform derived from the sound's id is used
/// instead, so the UI never shows an empty strip.
class Waveforms {
  Waveforms._();

  static final Map<String, List<double>> _cache = {};

  /// [bars] levels in 0..1, loudest bar = 1.
  static Future<List<double>> of(SoundModel sound, {int bars = 40}) async {
    final key = '${sound.id}:${sound.trimStart}:${sound.trimEnd}:$bars';
    final cached = _cache[key];
    if (cached != null) return cached;

    List<double> levels;
    try {
      levels = await _decode(sound, bars);
    } catch (_) {
      levels = placeholder(sound.id, bars);
    }
    _cache[key] = levels;
    return levels;
  }

  /// The cached waveform if it's already been decoded, else null.
  static List<double>? peek(SoundModel sound, {int bars = 40}) =>
      _cache['${sound.id}:${sound.trimStart}:${sound.trimEnd}:$bars'];

  static Future<List<double>> _decode(SoundModel sound, int bars) async {
    final Uint8List bytes;
    if (sound.isUserClip && sound.filePath != null) {
      bytes = await File(sound.filePath!).readAsBytes();
    } else {
      final data = await rootBundle.load('assets/sounds/raw/${sound.file}');
      bytes = data.buffer.asUint8List();
    }
    final trimmed = sound.isUserClip && sound.trimEnd > sound.trimStart;

    // Point-sample densely, then keep the loudest sample in each bar's slice.
    const perBar = 48;
    // Experimental in flutter_soloud 3.x; any failure (or an API change on
    // upgrade) lands in [of]'s catch and the placeholder is drawn instead.
    // ignore: experimental_member_use
    final samples = await SoLoud.instance.readSamplesFromMem(
      bytes,
      bars * perBar,
      startTime: trimmed ? sound.trimStart : 0,
      endTime: trimmed ? sound.trimEnd : -1,
    );
    if (samples.isEmpty) throw StateError('no samples');

    final peaks = List<double>.filled(bars, 0);
    for (var i = 0; i < samples.length; i++) {
      final b = min(bars - 1, i ~/ perBar);
      final v = samples[i].abs();
      if (v > peaks[b]) peaks[b] = v;
    }
    final loudest = peaks.reduce(max);
    if (loudest <= 0) throw StateError('silent');
    // A gentle curve lifts quiet passages so the shape stays readable.
    return [for (final p in peaks) pow(p / loudest, 0.7).toDouble()];
  }

  /// Deterministic stand-in shaped like a short sound (rise, body, tail).
  static List<double> placeholder(String id, int bars) {
    var x = id.codeUnits.fold<int>(17, (a, c) => (a * 31 + c) % 233280);
    return List.generate(bars, (i) {
      x = (x * 9301 + 49297) % 233280;
      final env = sin((i + 0.5) / bars * pi);
      return (0.25 + 0.75 * (x / 233280)) * (0.3 + 0.7 * env);
    });
  }
}
