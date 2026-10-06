import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/guitar_tuning.dart';
import 'package:soundr_soundboard/services/pitch_detector.dart';
import 'package:soundr_soundboard/services/reference_tone.dart';

void main() {
  test('reference tones are exactly in tune for every string', () {
    for (final t in guitarTunings) {
      for (final m in t.strings) {
        final hz = midiToHz(m);
        final out = <PitchReading?>[];
        PitchDetector(onReading: out.add).addSamples(ReferenceTone.samples(hz));
        final got = out.whereType<PitchReading>().map((r) => r.hz).toList()..sort();
        expect(got, isNotEmpty);
        final c = 1200 * log(got[got.length ~/ 2] / hz) / ln2;
        expect(c.abs(), lessThan(0.5), reason: '${t.name} midi $m');
      }
    }
  });

  test('wav is well formed, peaks below full scale and fades out', () {
    final w = ReferenceTone.wav(82.41);
    final b = ByteData.sublistView(w);
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
    expect(b.getUint32(24, Endian.little), 44100);
    final n = b.getUint32(40, Endian.little) ~/ 2;
    expect(n, 44100 * 2400 ~/ 1000);
    var peak = 0;
    for (var i = 0; i < n; i++) {
      peak = max(peak, b.getInt16(44 + i * 2, Endian.little).abs());
    }
    expect(peak, inInclusiveRange(20000, 27000));
    expect(b.getInt16(44 + (n - 1) * 2, Endian.little).abs(), lessThan(50));
    expect(b.getInt16(44, Endian.little), 0);
  });
}
