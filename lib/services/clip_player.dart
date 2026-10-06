import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'wav.dart';

/// Plays in-memory clips through SoLoud, one at a time, with a 0..1
/// [progress] for drawing a playhead. Silent no-op when the audio engine
/// isn't initialised (tests), but [progress] still runs on a timer so UIs
/// behave the same.
class ClipPlayer {
  final progress = ValueNotifier<double?>(null); // null = not playing

  /// Which clip is playing (the [play] tag), or null.
  final playing = ValueNotifier<Object?>(null);

  AudioSource? _source;
  SoundHandle? _handle;
  Timer? _ticker;
  int _gen = 0;

  bool get isPlaying => playing.value != null;

  /// Plays [samples]; [tag] identifies it (e.g. 'original' / 'attempt').
  Future<void> play(Float64List samples, {Object tag = true, int sampleRate = 44100}) async {
    await stop();
    final gen = ++_gen;
    final total = Duration(microseconds: samples.length * 1000000 ~/ sampleRate);
    if (total == Duration.zero) return;
    playing.value = tag;
    progress.value = 0;
    final sl = SoLoud.instance;
    if (sl.isInitialized) {
      try {
        final src = await sl.loadMem('clip_${identityHashCode(samples)}_$gen.wav',
            Wav.encode(samples, sampleRate: sampleRate));
        if (gen != _gen) {
          sl.disposeSource(src).ignore();
          return;
        }
        _source = src;
        _handle = await sl.play(src);
      } catch (_) {}
    }
    final sw = Stopwatch()..start();
    _ticker = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (gen != _gen) return;
      final p = sw.elapsedMicroseconds / total.inMicroseconds;
      if (p >= 1) {
        stop();
      } else {
        progress.value = p;
      }
    });
  }

  Future<void> stop() async {
    _gen++;
    _ticker?.cancel();
    _ticker = null;
    progress.value = null;
    playing.value = null;
    final sl = SoLoud.instance;
    final h = _handle, s = _source;
    _handle = null;
    _source = null;
    if (!sl.isInitialized) return;
    try {
      if (h != null) await sl.stop(h);
      if (s != null) await sl.disposeSource(s);
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    progress.dispose();
    playing.dispose();
  }
}
