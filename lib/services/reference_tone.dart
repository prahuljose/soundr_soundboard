import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'wav.dart';

/// Plays a string's target note so it can be tuned by ear.
///
/// The tone is a soft synthesized pluck: harmonics fading at different
/// rates, so a phone speaker that can't reproduce an 82 Hz fundamental
/// still conveys the pitch through the overtones.
class ReferenceTone {
  ReferenceTone._();

  static const duration = Duration(milliseconds: 2400);
  static const _rate = 44100;

  static final Map<String, AudioSource> _sources = {};
  static SoundHandle? _handle;

  /// Plays [hz]; any tone already playing stops first. Silently does
  /// nothing if the audio engine isn't available.
  static Future<void> play(double hz) async {
    stop();
    final sl = SoLoud.instance;
    if (!sl.isInitialized) return;
    try {
      final key = hz.toStringAsFixed(3);
      final src = _sources[key] ??= await sl.loadMem(
        'tuner_ref_$key.wav',
        wav(hz),
      );
      _handle = await sl.play(src, volume: 0.9);
    } catch (_) {}
  }

  static void stop() {
    final h = _handle;
    _handle = null;
    if (h == null) return;
    try {
      SoLoud.instance.fadeVolume(h, 0, const Duration(milliseconds: 80));
      SoLoud.instance.scheduleStop(h, const Duration(milliseconds: 80));
    } catch (_) {}
  }

  /// Frees the cached tones (when leaving the tuner).
  static void dispose() {
    stop();
    final sl = SoLoud.instance;
    for (final s in _sources.values) {
      try {
        sl.disposeSource(s).ignore();
      } catch (_) {}
    }
    _sources.clear();
  }

  /// Samples in -1..1. Public for tests.
  static Float64List samples(double hz) {
    final n = _rate * duration.inMilliseconds ~/ 1000;
    final out = Float64List(n);
    final attack = (0.006 * _rate).round();
    final release = (0.25 * _rate).round();
    for (var k = 1; k <= 12; k++) {
      final f = hz * k;
      if (f > _rate / 2.5) break;
      final amp = pow(k, -0.85).toDouble() * (k == 1 ? 0.8 : 1);
      final decay = 0.9 + 0.55 * k; // higher harmonics fade faster
      final w = 2 * pi * f / _rate;
      for (var i = 0; i < n; i++) {
        out[i] += amp * exp(-decay * i / _rate) * sin(w * i);
      }
    }
    var peak = 0.0;
    for (final v in out) {
      peak = max(peak, v.abs());
    }
    for (var i = 0; i < n; i++) {
      var env = 1.0;
      if (i < attack) env = i / attack;
      if (i > n - release) env = (n - i) / release;
      out[i] = out[i] / peak * 0.8 * env;
    }
    return out;
  }

  /// A 16-bit mono WAV of [samples]. Public for tests.
  static Uint8List wav(double hz) => Wav.encode(samples(hz), sampleRate: _rate);
}
