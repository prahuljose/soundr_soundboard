import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/wav.dart';

void main() {
  test('encode → decode round trip', () {
    final s = Float64List.fromList(
        List.generate(4410, (i) => 0.6 * sin(2 * pi * 440 * i / 44100)));
    final back = Wav.decode(Wav.encode(s, sampleRate: 22050));
    expect(back.sampleRate, 22050);
    expect(back.samples.length, s.length);
    for (var i = 0; i < s.length; i += 37) {
      expect(back.samples[i], closeTo(s[i], 1 / 16000));
    }
    expect(back.duration, const Duration(milliseconds: 200));
  });

  test('clips instead of wrapping', () {
    final back = Wav.decode(Wav.encode([1.5, -1.5]));
    expect(back.samples[0], closeTo(1, 1e-3));
    expect(back.samples[1], closeTo(-1, 1e-3));
  });

  test('rejects non-WAV', () {
    expect(() => Wav.decode(Uint8List.fromList(List.filled(64, 1))),
        throwsFormatException);
  });
}
