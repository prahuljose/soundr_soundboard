import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// Records a short clip from the mic into memory (44.1 kHz mono), with a
/// live level for meters. Used by the voice changer and the reverse
/// challenge, which both work on raw samples rather than files.
///
/// The caller handles the microphone permission first.
class MicClipRecorder {
  static const sampleRate = 44100;

  /// Stops by itself after this long.
  final Duration maxLength;

  /// Called when recording stops on its own at [maxLength].
  final VoidCallback? onAutoStop;

  /// Feeds PCM instead of the microphone (tests).
  final Stream<Uint8List>? debugStream;

  MicClipRecorder({
    this.maxLength = const Duration(seconds: 15),
    this.onAutoStop,
    this.debugStream,
  });

  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final _chunks = BytesBuilder(copy: false);

  /// 0..1, roughly perceptual (dB scaled), updated per chunk.
  final level = ValueNotifier<double>(0);

  /// Recording time so far.
  final elapsed = ValueNotifier<Duration>(Duration.zero);

  bool get isRecording => _sub != null;
  int _bytes = 0;

  Future<void> start() async {
    if (isRecording) return;
    _chunks.clear();
    _bytes = 0;
    elapsed.value = Duration.zero;
    final stream = debugStream ??
        await _recorder.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
        ));
    _sub = stream.listen(_onChunk);
  }

  void _onChunk(Uint8List chunk) {
    _chunks.add(chunk);
    _bytes += chunk.length;
    final d = ByteData.sublistView(chunk);
    var sum = 0.0;
    final n = chunk.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final v = d.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
    }
    final rms = n == 0 ? 0.0 : sqrt(sum / n);
    // -60 dB → 0, 0 dB → 1
    final db = rms <= 0 ? -60.0 : 20 * log(rms) / ln10;
    level.value = ((db + 60) / 60).clamp(0.0, 1.0);
    elapsed.value = Duration(microseconds: (_bytes ~/ 2) * 1000000 ~/ sampleRate);
    if (elapsed.value >= maxLength) {
      onAutoStop?.call();
    }
  }

  /// Stops and returns the recording as samples in -1..1.
  Future<Float64List> stop() async {
    await _sub?.cancel();
    _sub = null;
    if (debugStream == null) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    level.value = 0;
    final bytes = _chunks.takeBytes();
    final d = ByteData.sublistView(bytes);
    final out = Float64List(bytes.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = d.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    if (debugStream == null) {
      try {
        await _recorder.stop();
      } catch (_) {}
      await _recorder.dispose();
    }
    level.dispose();
    elapsed.dispose();
  }
}
