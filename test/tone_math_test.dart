import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/services/tone_math.dart';

void main() {
  group('log slider', () {
    test('ends and middle', () {
      expect(sliderToHz(0), kMinHz);
      expect(sliderToHz(1), kMaxHz);
      // 3 decades: a third of the way is 200 Hz, two thirds 2 kHz.
      expect(sliderToHz(1 / 3), closeTo(200, 1e-9));
      expect(sliderToHz(2 / 3), closeTo(2000, 1e-9));
      expect(hzToSlider(20), 0);
      expect(hzToSlider(20000), 1);
      expect(hzToSlider(2000), closeTo(2 / 3, 1e-12));
    });

    test('round trips', () {
      for (final hz in [20.0, 27.5, 100, 440, 997.3, 1000, 12345, 19999.9, 20000]) {
        expect(sliderToHz(hzToSlider(hz.toDouble())), closeTo(hz, 1e-9 * hz));
      }
      for (var i = 0; i <= 100; i++) {
        final t = i / 100;
        expect(hzToSlider(sliderToHz(t)), closeTo(t, 1e-12));
      }
    });

    test('clamps out of range and NaN', () {
      expect(sliderToHz(-0.5), kMinHz);
      expect(sliderToHz(1.5), kMaxHz);
      expect(sliderToHz(double.nan), kMinHz);
      expect(hzToSlider(5), 0);
      expect(hzToSlider(50000), 1);
      expect(clampHz(-3), kMinHz);
      expect(clampHz(1e9), kMaxHz);
      expect(clampHz(double.nan), kMinHz);
    });
  });

  group('fine steps', () {
    test('step size by range', () {
      expect(fineStep(20), 1);
      expect(fineStep(999), 1);
      expect(fineStep(1000), 10);
      expect(fineStep(9990), 10);
      expect(fineStep(10000), 100);
    });

    test('nudge lands on the grid', () {
      expect(nudgeHz(440, up: true), 441);
      expect(nudgeHz(440, up: false), 439);
      expect(nudgeHz(440.4, up: true), 441);
      expect(nudgeHz(440.4, up: false), 440);
      expect(nudgeHz(999, up: true), 1000);
      expect(nudgeHz(1000, up: true), 1010);
      expect(nudgeHz(1000, up: false), 999);
      expect(nudgeHz(1234, up: true), 1240);
      expect(nudgeHz(1234, up: false), 1230);
      expect(nudgeHz(10000, up: false), 9990);
      expect(nudgeHz(10000, up: true), 10100);
      expect(nudgeHz(440, up: true, multiplier: 10), 450);
    });

    test('nudge clamps at the ends', () {
      expect(nudgeHz(20, up: false), 20);
      expect(nudgeHz(20000, up: true), 20000);
      expect(nudgeHz(19950, up: true), 20000);
    });

    test('snap', () {
      expect(snapHz(440.4), 440);
      expect(snapHz(57.6), 58);
      expect(snapHz(1234.5), 1230);
      expect(snapHz(12345), 12300);
      expect(snapHz(19.2), 20);
      expect(snapHz(25000), 20000);
    });
  });

  group('format', () {
    test('Hz and kHz', () {
      expect(formatHz(440), '440 Hz');
      expect(formatHz(440.5), '440.5 Hz');
      expect(formatHz(440.04), '440 Hz');
      expect(formatHz(20), '20 Hz');
      expect(formatHz(1000), '1 kHz');
      expect(formatHz(1250), '1.25 kHz');
      expect(formatHz(1010), '1.01 kHz');
      expect(formatHz(12345), '12.345 kHz');
      expect(formatHz(15000), '15 kHz');
      expect(formatHz(20000), '20 kHz');
      expect(formatHz(999.97), '1 kHz');
      expect(formatHzParts(1500), ('1.5', 'kHz'));
      expect(formatHzParts(100), ('100', 'Hz'));
    });

    test('cents', () {
      expect(formatCents(0), '+0 cents');
      expect(formatCents(7), '+7 cents');
      expect(formatCents(-12), '−12 cents');
    });
  });

  group('nearest note', () {
    test('exact and off', () {
      expect(nearestNote(440).label, 'A4 · +0 cents');
      expect(nearestNote(261.63).name, 'C4');
      expect(nearestNote(261.63).cents, 0);
      expect(nearestNote(1000).name, 'B5');
      expect(nearestNote(1000).cents, 21);
      expect(nearestNote(100).name, 'G2');
      expect(nearestNote(100).cents, 35);
      expect(nearestNote(450).label, 'A4 · +39 cents');
      expect(nearestNote(20).name, 'D#0');
    });

    test('calibrated A4', () {
      expect(nearestNote(442, a4: 442).label, 'A4 · +0 cents');
      expect(nearestNote(440, a4: 442).cents, -8);
    });

    test('cents stay within ±50', () {
      for (var hz = 20.0; hz < 20000; hz *= 1.013) {
        final n = nearestNote(hz);
        expect(n.cents, inInclusiveRange(-50, 50));
      }
    });
  });

  group('sweep', () {
    test('log sweep', () {
      expect(sweepHz(0), 20);
      expect(sweepHz(10), 20000);
      expect(sweepHz(5), closeTo(632.456, 0.001)); // geometric mean
      expect(sweepHz(10 / 3), closeTo(200, 1e-9));
      expect(sweepHz(-1), 20);
      expect(sweepHz(99), 20000);
      expect(sweepHz(1, from: 100, to: 200, seconds: 2), closeTo(141.421, 0.001));
      expect(sweepHz(1, seconds: 0), 20000);
    });

    test('rises steadily', () {
      var last = 0.0;
      for (var t = 0.0; t <= 10; t += 0.1) {
        final f = sweepHz(t);
        expect(f, greaterThan(last));
        last = f;
      }
    });
  });

  group('parse', () {
    test('accepts common forms', () {
      expect(parseHz('440'), 440);
      expect(parseHz(' 440.5 '), 440.5);
      expect(parseHz('440Hz'), 440);
      expect(parseHz('440 hz'), 440);
      expect(parseHz('1k'), 1000);
      expect(parseHz('1.5k'), 1500);
      expect(parseHz('1.5 kHz'), 1500);
      expect(parseHz('2KHZ'), 2000);
      expect(parseHz('1,000'), 1000);
      expect(parseHz('.5k'), 500);
      expect(parseHz('12.345k'), 12345);
      expect(parseHz('440.'), 440);
    });

    test('rejects nonsense', () {
      for (final s in ['', ' ', 'abc', '-440', '0', '1.2.3', 'k', 'hz', '4 4 0x', '1e3']) {
        expect(parseHz(s), isNull, reason: s);
      }
    });

    test('range check is separate', () {
      expect(parseHz('25k'), 25000);
      expect(inAudibleRange(25000), isFalse);
      expect(inAudibleRange(19.9), isFalse);
      expect(inAudibleRange(20), isTrue);
      expect(inAudibleRange(20000), isTrue);
    });
  });

  group('loudness', () {
    test('gain curve and shapes', () {
      expect(toneGain(0, ToneWave.sine), 0);
      expect(toneGain(1, ToneWave.sine), 1);
      expect(toneGain(0.5, ToneWave.sine), 0.25);
      expect(toneGain(1, ToneWave.square), lessThan(toneGain(1, ToneWave.saw)));
      expect(toneGain(1, ToneWave.saw), lessThan(toneGain(1, ToneWave.sine)));
      expect(toneGain(2, ToneWave.sine), 1);
      expect(toneGain(-1, ToneWave.sine), 0);
    });

    test('caution', () {
      expect(showCaution(440, 0.5), isFalse);
      expect(showCaution(15000, 0.5), isFalse);
      expect(showCaution(15001, 0.5), isTrue);
      expect(showCaution(440, 0.81), isTrue);
    });
  });

  group('wave shapes', () {
    test('samples', () {
      for (final w in ToneWave.values) {
        for (var p = -1.0; p < 2; p += 0.01) {
          expect(waveSample(w, p), inInclusiveRange(-1, 1), reason: '$w $p');
        }
      }
      expect(waveSample(ToneWave.sine, 0.25), closeTo(1, 1e-12));
      expect(waveSample(ToneWave.square, 0.1), 1);
      expect(waveSample(ToneWave.square, 0.6), -1);
      expect(waveSample(ToneWave.triangle, 0.25), 1);
      expect(waveSample(ToneWave.triangle, 0.75), -1);
      expect(waveSample(ToneWave.triangle, 0.5), 0);
      expect(waveSample(ToneWave.saw, 0.25), 0.5);
      expect(waveSample(ToneWave.saw, 0.75), -0.5);
      // Periodic.
      expect(waveSample(ToneWave.saw, 1.25), waveSample(ToneWave.saw, 0.25));
    });

    test('labels', () {
      expect(ToneWave.values.map((w) => w.label), ['Sine', 'Square', 'Triangle', 'Saw']);
    });
  });

  group('pitch pipe', () {
    test('midi per octave', () {
      expect(pipeMidi(9, 4), 69); // A4
      expect(pipeMidi(0, 4), 60); // C4
      expect(pipeMidi(0, 2), 36);
      expect(pipeMidi(11, 6), 95);
    });

    test('A4 calibration', () {
      expect(parseA4(null), 440);
      expect(parseA4(''), 440);
      expect(parseA4('442'), 442);
      expect(parseA4('429'), 440);
      expect(parseA4('451'), 440);
      expect(parseA4('abc'), 440);
    });
  });
}
