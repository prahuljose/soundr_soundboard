import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Mono audio as samples in -1..1.
class WavAudio {
  final Float64List samples;
  final int sampleRate;

  const WavAudio(this.samples, this.sampleRate);

  Duration get duration =>
      Duration(microseconds: samples.length * 1000000 ~/ sampleRate);
}

/// 16-bit mono WAV encoding and decoding, plus temp files for sharing or
/// handing a clip to the soundboard's clip editor.
class Wav {
  Wav._();

  static Uint8List encode(List<double> samples, {int sampleRate = 44100}) {
    final data = samples.length * 2;
    final b = ByteData(44 + data);
    void str(int o, String v) {
      for (var i = 0; i < v.length; i++) {
        b.setUint8(o + i, v.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + data, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, 1, Endian.little); // mono
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, sampleRate * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, data, Endian.little);
    for (var i = 0; i < samples.length; i++) {
      final v = (samples[i] * 32767).round().clamp(-32768, 32767);
      b.setInt16(44 + i * 2, v, Endian.little);
    }
    return b.buffer.asUint8List();
  }

  /// Reads 16-bit PCM WAV (mono, or stereo mixed down). Throws
  /// [FormatException] for anything else.
  static WavAudio decode(Uint8List bytes) {
    final b = ByteData.sublistView(bytes);
    String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
    if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException('Not a WAV file');
    }
    var channels = 1, rate = 44100, bits = 16;
    var o = 12;
    while (o + 8 <= bytes.length) {
      final id = tag(o);
      final size = b.getUint32(o + 4, Endian.little);
      final body = o + 8;
      if (id == 'fmt ') {
        channels = b.getUint16(body + 2, Endian.little);
        rate = b.getUint32(body + 4, Endian.little);
        bits = b.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        if (bits != 16) throw const FormatException('Only 16-bit WAV');
        final end = (body + size).clamp(0, bytes.length);
        final frames = (end - body) ~/ (2 * channels);
        final out = Float64List(frames);
        for (var f = 0; f < frames; f++) {
          var sum = 0.0;
          for (var ch = 0; ch < channels; ch++) {
            sum += b.getInt16(body + (f * channels + ch) * 2, Endian.little);
          }
          out[f] = sum / channels / 32768.0;
        }
        return WavAudio(out, rate);
      }
      o = body + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('No audio data');
  }

  /// Writes [samples] to a WAV in the temp folder and returns its path.
  static Future<String> writeTemp(
    List<double> samples, {
    required String name,
    int sampleRate = 44100,
  }) async {
    final dir = await getTemporaryDirectory();
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final file = File('${dir.path}/$safe.wav');
    await file.writeAsBytes(encode(samples, sampleRate: sampleRate), flush: true);
    return file.path;
  }
}
