import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/screens/tone_generator_screen.dart';
import 'package:soundr_soundboard/services/tone_math.dart';

/// Records what the screen asks the audio engine to do.
class FakeToneOutput implements ToneOutput {
  final List<String> log = [];
  bool playing = false;
  bool disposed = false;
  ToneWave? wave;
  double? hz;
  double? gain;

  @override
  void play(ToneWave wave, double hz, double gain) {
    log.add('play ${wave.name} ${hz.toStringAsFixed(1)}');
    playing = true;
    this.wave = wave;
    this.hz = hz;
    this.gain = gain;
  }

  @override
  void setFreq(double hz) {
    log.add('freq ${hz.toStringAsFixed(1)}');
    this.hz = hz;
  }

  @override
  void setWave(ToneWave wave, double gain) {
    log.add('wave ${wave.name}');
    this.wave = wave;
    this.gain = gain;
  }

  @override
  void setGain(double gain) {
    log.add('gain');
    this.gain = gain;
  }

  @override
  void stop() {
    log.add('stop');
    playing = false;
  }

  @override
  void dispose() {
    log.add('dispose');
    disposed = true;
  }
}

void main() {
  late FakeToneOutput out;

  Future<void> open(WidgetTester t, {Size size = const Size(390, 844)}) async {
    out = FakeToneOutput();
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF)),
      home: ToneGeneratorScreen(debugOutput: out),
    ));
    await t.pump();
  }

  String readout(WidgetTester t) => t
      .widget<Semantics>(find
          .ancestor(
            of: find.byKey(const ValueKey('tone-readout')),
            matching: find.byType(Semantics),
          )
          .first)
      .properties
      .label!;

  testWidgets('starts at 440 Hz, A4, play and stop', (t) async {
    await open(t);
    expect(find.text('440'), findsOneWidget);
    expect(find.text('A4 · +0 cents'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pump();
    expect(out.playing, isTrue);
    expect(out.log.last, 'play sine 440.0');
    expect(out.gain, closeTo(0.25, 1e-9)); // 50% volume, squared
    expect(find.text('Stop'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pumpAndSettle();
    expect(out.playing, isFalse);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('waveform changes live', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pump();
    await t.tap(find.bySemanticsLabel('Square wave'));
    await t.pump();
    expect(out.wave, ToneWave.square);
    expect(out.log.last, 'wave square');
    expect(out.gain, closeTo(toneGain(0.5, ToneWave.square), 1e-9));
    await t.tap(find.bySemanticsLabel('Saw wave'));
    await t.pump();
    expect(out.wave, ToneWave.saw);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pumpAndSettle();
  });

  testWidgets('dragging the dial changes frequency, log scale', (t) async {
    await open(t);
    // Left drag = higher. ~150 px is one decade.
    await t.timedDrag(find.byKey(const ValueKey('tone-dial')),
        const Offset(-150, 0), const Duration(milliseconds: 900));
    await t.pumpAndSettle();
    expect(readout(t), contains('kHz'));
    final up = parseHz(readout(t).split(',').first.replaceFirst('Frequency ', ''))!;
    expect(up, inInclusiveRange(3000, 6000));

    // Back down past the bottom: clamps at 20 Hz.
    await t.timedDrag(find.byKey(const ValueKey('tone-dial')),
        const Offset(400, 0), const Duration(milliseconds: 900));
    await t.timedDrag(find.byKey(const ValueKey('tone-dial')),
        const Offset(400, 0), const Duration(milliseconds: 900));
    await t.pumpAndSettle();
    expect(readout(t), startsWith('Frequency 20 Hz'));

    // While playing, the engine follows the dial. (The scope animates
    // while playing, so pump fixed times rather than settling.)
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pump();
    await t.fling(find.byKey(const ValueKey('tone-dial')),
        const Offset(-120, 0), 1500);
    for (var i = 0; i < 120; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(out.log.last, startsWith('freq'));
    expect(out.hz!, greaterThan(200));
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pumpAndSettle();
  });

  testWidgets('− and + step, and holding repeats', (t) async {
    await open(t);
    await t.tap(find.byTooltip('Raise frequency'));
    await t.pump();
    expect(find.text('441'), findsOneWidget);
    await t.tap(find.byTooltip('Lower frequency'));
    await t.tap(find.byTooltip('Lower frequency'));
    await t.pump();
    expect(find.text('439'), findsOneWidget);

    final g = await t.startGesture(t.getCenter(find.byTooltip('Raise frequency')));
    await t.pump(const Duration(milliseconds: 900)); // repeats at 400, 510 … 840
    await g.up();
    await t.pumpAndSettle();
    expect(find.text('445'), findsOneWidget); // 1 tap + 5 repeats
  });

  testWidgets('preset chips', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pump();
    await t.tap(find.text('1 kHz'));
    await t.pump();
    expect(find.text('1'), findsOneWidget);
    expect(find.text('kHz'), findsOneWidget);
    expect(out.log.last, 'freq 1000.0');
    await t.tap(find.text('10 kHz'));
    await t.pump();
    expect(out.hz, 10000);
    await t.tap(find.text('100 Hz'));
    await t.pump();
    expect(find.text('G2 · +35 cents'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pumpAndSettle();
  });

  testWidgets('typed frequency, with validation', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('tone-readout')));
    await t.pumpAndSettle();
    expect(find.text('Set frequency'), findsOneWidget);

    await t.enterText(find.byKey(const ValueKey('tone-hz-field')), 'abc');
    await t.tap(find.text('Set'));
    await t.pump();
    expect(find.text('Enter a number, like 440 or 1.5k'), findsOneWidget);

    await t.enterText(find.byKey(const ValueKey('tone-hz-field')), '30000');
    await t.tap(find.text('Set'));
    await t.pump();
    expect(find.text('Choose between 20 Hz and 20 kHz'), findsOneWidget);

    await t.enterText(find.byKey(const ValueKey('tone-hz-field')), '1.5k');
    await t.tap(find.text('Set'));
    await t.pumpAndSettle();
    expect(find.text('Set frequency'), findsNothing);
    expect(find.text('1.5'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('tone-readout')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('tone-hz-field')), '432.5');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pumpAndSettle();
    expect(find.text('432.5'), findsOneWidget);

    // Cancel keeps the value.
    await t.tap(find.byKey(const ValueKey('tone-readout')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('tone-hz-field')), '99');
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(find.text('432.5'), findsOneWidget);
  });

  testWidgets('high frequency and loud volume show a caution', (t) async {
    await open(t);
    expect(find.textContaining('keep the volume moderate'), findsNothing);
    await t.tap(find.text('10 kHz'));
    await t.pump();
    expect(find.textContaining('keep the volume moderate'), findsNothing);
    await t.tap(find.byKey(const ValueKey('tone-readout')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('tone-hz-field')), '16000');
    await t.tap(find.text('Set'));
    await t.pumpAndSettle();
    expect(find.text('High tones can be hard to hear — keep the volume moderate.'),
        findsOneWidget);
  });

  testWidgets('volume slider updates the playing level', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pump();
    final slider = find.byType(Slider);
    // Tap near the right end of the track.
    final r = t.getRect(slider);
    await t.tapAt(Offset(r.right - 30, r.center.dy));
    await t.pump();
    expect(out.log.last, 'gain');
    expect(out.gain!, greaterThan(0.6));
    expect(find.textContaining('That’s loud'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pumpAndSettle();
  });

  testWidgets('sweep runs 20 Hz → 20 kHz then stops and restores', (t) async {
    await open(t);
    await t.tap(find.text('Sweep'));
    await t.pump();
    expect(out.log, contains('play sine 20.0'));
    expect(find.text('Stop sweep'), findsOneWidget);
    expect(find.text('Sweeping'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await t.pump(const Duration(milliseconds: 16));
    expect(out.hz!, inInclusiveRange(550, 720)); // geometric middle ≈ 632
    await t.pump(const Duration(seconds: 6));
    await t.pump(const Duration(milliseconds: 16));
    expect(out.playing, isFalse);
    expect(find.text('Sweep'), findsOneWidget);
    expect(find.text('440'), findsOneWidget);
    await t.pumpAndSettle();
  });

  testWidgets('stopping a sweep early', (t) async {
    await open(t);
    await t.tap(find.text('Sweep'));
    await t.pump();
    await t.pump(const Duration(seconds: 2));
    await t.tap(find.text('Stop sweep'));
    await t.pump();
    expect(out.playing, isFalse);
    expect(find.text('440'), findsOneWidget);
    await t.pumpAndSettle();
  });

  testWidgets('pitch pipe: play a note, change octave, stop', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pump();
    await t.tap(find.text('Pitch pipe'));
    await t.pumpAndSettle();
    // Switching tabs stops the tone.
    expect(out.playing, isFalse);
    expect(find.text('Tap a note to hear it'), findsOneWidget);
    expect(find.text('A4 = 440 Hz'), findsOneWidget);

    await t.tap(find.bySemanticsLabel(RegExp(r'^C4, ')));
    await t.pumpAndSettle();
    expect(out.playing, isTrue);
    expect(out.wave, ToneWave.triangle);
    expect(out.hz, closeTo(261.6, 0.1));
    expect(find.text('261.6 Hz'), findsOneWidget);
    expect(find.text('Tap to stop'), findsOneWidget);

    await t.tap(find.bySemanticsLabel(RegExp(r'^F# or Gb4, ')));
    await t.pumpAndSettle();
    expect(out.log.last, 'play triangle 370.0');
    expect(find.text('370.0 Hz'), findsOneWidget);

    await t.tap(find.byTooltip('Higher octave'));
    await t.pumpAndSettle();
    expect(out.log.last, 'freq 740.0');
    expect(find.text('740.0 Hz'), findsOneWidget);
    expect(find.text('5'), findsWidgets);

    for (var i = 0; i < 5; i++) {
      await t.tap(find.byTooltip('Lower octave'));
      await t.pump();
    }
    await t.pumpAndSettle();
    expect(find.text('92.5 Hz'), findsOneWidget); // F#2, clamped at 2

    // Tap the same note again to stop.
    await t.tap(find.bySemanticsLabel(RegExp(r'^F# or Gb2, ')));
    await t.pumpAndSettle();
    expect(out.playing, isFalse);
    expect(find.text('Tap to play'), findsOneWidget);

    // The centre replays it, and stops it.
    await t.tap(find.text('Tap to play'));
    await t.pumpAndSettle();
    expect(out.playing, isTrue);
    expect(out.hz, closeTo(92.5, 0.05));
    await t.tap(find.text('Tap to stop'));
    await t.pumpAndSettle();
    expect(out.playing, isFalse);
  });

  testWidgets('leaving while playing stops and frees the engine', (t) async {
    await open(t);
    await t.tap(find.text('Sweep'));
    await t.pump(const Duration(seconds: 1));
    expect(out.playing, isTrue);
    await t.pumpWidget(const SizedBox());
    expect(out.playing, isFalse);
    expect(out.disposed, isTrue);
  });

  testWidgets('leaving while the pipe plays', (t) async {
    await open(t);
    await t.tap(find.text('Pitch pipe'));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel(RegExp(r'^A4, ')));
    await t.pump();
    expect(out.playing, isTrue);
    await t.pumpWidget(const SizedBox());
    expect(out.playing, isFalse);
    expect(out.disposed, isTrue);
  });

  testWidgets('going to the background stops the tone', (t) async {
    await open(t);
    await t.tap(find.byKey(const ValueKey('tone-play')));
    await t.pump();
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await t.pumpAndSettle();
    expect(out.playing, isFalse);
    expect(find.text('Play'), findsOneWidget);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
  });

  testWidgets('small phone fits without overflow', (t) async {
    await open(t, size: const Size(360, 640));
    await t.tap(find.text('16 kHz').hitTestable().evaluate().isEmpty
        ? find.text('10 kHz')
        : find.text('16 kHz'));
    await t.pump();
    await t.tap(find.text('Pitch pipe'));
    await t.pumpAndSettle();
    await t.tap(find.bySemanticsLabel(RegExp(r'^B4, ')));
    await t.pumpAndSettle();
    expect(find.text('493.9 Hz'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
