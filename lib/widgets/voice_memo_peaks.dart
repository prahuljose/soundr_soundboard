import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../services/waveforms.dart';

/// Loudness envelopes for voice memo WAV files, for drawing waveforms.
///
/// Memos are 16-bit PCM WAVs that can run for minutes, so instead of decoding
/// the whole file this samples a few short windows per bar with random-access
/// reads on a background isolate — cheap whatever the memo's length. Results
/// are cached per file.
/// Anything unreadable falls back to a stable pseudo-waveform.
class VoiceMemoPeaks {
  VoiceMemoPeaks._();

  static final Map<String, List<double>> _cache = {};

  /// Already-computed levels for [path], or null.
  static List<double>? peek(String path, int bars) => _cache['$path:$bars'];

  /// [bars] levels in 0..1, loudest bar = 1.
  static Future<List<double>> of(String path, {required int bars}) async {
    final key = '$path:$bars';
    final cached = _cache[key];
    if (cached != null) return cached;
    List<double> levels;
    try {
      levels = await Isolate.run(() => _read(path, bars));
    } catch (_) {
      levels = Waveforms.placeholder(path, bars);
    }
    _cache[key] = levels;
    return levels;
  }

  static const _windowsPerBar = 4;
  static const _framesPerWindow = 512;

  static List<double> _read(String path, int bars) {
    final raf = File(path).openSync();
    try {
      // Walk the RIFF chunks for the format and the start of the samples.
      final head = raf.readSync(4096);
      final bd = ByteData.sublistView(head);
      String tag(int off) => String.fromCharCodes(head.sublist(off, off + 4));
      if (head.length < 44 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
        throw const FormatException('not a wav');
      }
      int? channels, bits, dataOffset, dataSize;
      var off = 12;
      while (off + 8 <= head.length) {
        final id = tag(off);
        final size = bd.getUint32(off + 4, Endian.little);
        if (id == 'fmt ' && off + 24 <= head.length) {
          if (bd.getUint16(off + 8, Endian.little) != 1) {
            throw const FormatException('not PCM');
          }
          channels = bd.getUint16(off + 10, Endian.little);
          bits = bd.getUint16(off + 22, Endian.little);
        } else if (id == 'data') {
          dataOffset = off + 8;
          dataSize = size;
          break;
        }
        off += 8 + size + (size.isOdd ? 1 : 0);
      }
      if (bits != 16 || channels == null || channels < 1 || dataOffset == null) {
        throw const FormatException('unsupported wav');
      }
      final frameBytes = 2 * channels;
      final available = raf.lengthSync() - dataOffset;
      final frames = min(dataSize!, available) ~/ frameBytes;
      if (frames <= 0) throw const FormatException('empty');

      final levels = List<double>.filled(bars, 0);
      for (var b = 0; b < bars; b++) {
        final barStart = b * frames ~/ bars;
        final barLen = max(1, (b + 1) * frames ~/ bars - barStart);
        final step = barLen / _windowsPerBar;
        final take = min(_framesPerWindow, max(1, step.floor()));
        var sum = 0.0;
        var count = 0;
        for (var w = 0; w < _windowsPerBar; w++) {
          final frame = barStart + (w * step).floor();
          raf.setPositionSync(dataOffset + frame * frameBytes);
          final bytes = raf.readSync(take * frameBytes);
          final view = ByteData.sublistView(bytes);
          for (var i = 0; i + 1 < bytes.length; i += frameBytes) {
            final s = view.getInt16(i, Endian.little) / 32768.0;
            sum += s * s;
            count++;
          }
        }
        levels[b] = count == 0 ? 0 : sqrt(sum / count);
      }
      final loudest = levels.reduce(max);
      if (loudest <= 0) return levels; // silence draws as a flat line
      // A gentle curve lifts quiet passages so speech stays readable.
      return [for (final l in levels) pow(l / loudest, 0.7).toDouble()];
    } finally {
      raf.closeSync();
    }
  }
}
