import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/screens/voice_changer_screen.dart';

import 'support/tuner_feed.dart';

/// A vowel-ish voice: a ~140 Hz buzz with a syllable-like envelope.
List<double> voice(double seconds) {
  const sr = 44100;
  final n = (seconds * sr).round();
  var phase = 0.0;
  return List.generate(n, (i) {
    final t = i / sr;
    phase += 2 * pi * 140 * (1 + 0.04 * sin(2 * pi * 0.8 * t)) / sr;
    var v = 0.0;
    for (var k = 1; k <= 12; k++) {
      v += sin(k * phase) / k;
    }
    return 0.25 * v * (0.4 + 0.6 * sin(2 * pi * 2 * t).abs());
  });
}

void main() {
  late List<StreamController<Uint8List>> mics;
  StreamController<Uint8List> mic() => mics.last;

  Stream<Uint8List> nextMic() {
    final c = StreamController<Uint8List>();
    mics.add(c);
    return c.stream;
  }

  Future<void> open(WidgetTester t, {Size size = const Size(390, 844)}) async {
    mics = [];
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF)),
        home: VoiceChangerScreen(debugMic: nextMic),
      ),
    );
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    for (final m in mics) {
      unawaited(m.close()); // awaiting would wait on the fake clock
    }
  }

  Finder tile(String name) => find.bySemanticsLabel(RegExp('^$name voice'));

  bool isSelected(WidgetTester t, String name) =>
      t.getSemantics(tile(name)).flagsCollection.isSelected == Tristate.isTrue;

  String tileLabel(WidgetTester t, String name) =>
      t.getSemantics(tile(name)).label;

  /// MicClipRecorder.stop awaits a subscription cancel that completes in
  /// the root zone, so give it a moment of real time.
  Future<void> settleStop(WidgetTester t) async {
    await t.pump();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> stopRecording(WidgetTester t) async {
    await t.tap(find.bySemanticsLabel('Stop recording'));
    await settleStop(t);
  }

  Future<void> record(WidgetTester t, double seconds) async {
    await t.tap(find.bySemanticsLabel('Record'));
    await t.pump();
    expect(find.textContaining('Tap to stop'), findsOneWidget);
    await feed(t, mic(), voice(seconds));
    await stopRecording(t);
  }

  /// Lets the render isolate finish (real time), then pumps its result in.
  Future<void> waitForRender(WidgetTester t, String name) async {
    for (
      var i = 0;
      i < 100 && tileLabel(t, name).contains('getting ready');
      i++
    ) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await t.pump();
    }
    expect(tileLabel(t, name), isNot(contains('getting ready')));
    await t.pump();
  }

  testWidgets('record, try voices, stop, record again', (t) async {
    await open(t);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.text('Pick a voice'), findsNothing);

    // Recording: timer and stop button.
    await t.tap(find.bySemanticsLabel('Record'));
    await t.pump();
    await feed(t, mic(), voice(1.3));
    expect(find.text('0:01'), findsOneWidget);
    expect(find.bySemanticsLabel('Stop recording'), findsOneWidget);
    await stopRecording(t);

    // The grid of voices, Normal selected, nothing playing.
    expect(find.text('Pick a voice'), findsOneWidget);
    expect(find.text('Your recording'), findsOneWidget);
    for (final name in [
      'Normal',
      'Chipmunk',
      'Helium',
      'Deep',
      'Monster',
      'Robot',
      'Alien',
      'Echo',
      'Stadium',
      'Radio',
      'Underwater',
      'Backwards',
    ]) {
      expect(tile(name), findsOneWidget, reason: name);
    }
    expect(isSelected(t, 'Normal'), isTrue);

    // Tap Chipmunk: spinner while it renders, then it plays.
    await t.tap(tile('Chipmunk'));
    await t.pump();
    expect(tileLabel(t, 'Chipmunk'), contains('getting ready'));
    expect(isSelected(t, 'Chipmunk'), isTrue);
    expect(isSelected(t, 'Normal'), isFalse);
    await waitForRender(t, 'Chipmunk');
    expect(tileLabel(t, 'Chipmunk'), contains('playing'));
    expect(find.text('Chipmunk voice'), findsOneWidget);
    expect(find.text('Tap again to stop'), findsOneWidget);

    // Tapping the playing tile stops it.
    await t.tap(tile('Chipmunk'));
    await t.pump();
    expect(tileLabel(t, 'Chipmunk'), isNot(contains('playing')));

    // Tapping it again plays straight from the cache — no render.
    await t.tap(tile('Chipmunk'));
    await t.pump();
    await t.pump();
    expect(tileLabel(t, 'Chipmunk'), contains('playing'));

    // Another voice takes over; playback ends on its own.
    await t.tap(tile('Echo'));
    await t.pump();
    expect(tileLabel(t, 'Chipmunk'), isNot(contains('playing')));
    await waitForRender(t, 'Echo');
    expect(tileLabel(t, 'Echo'), contains('playing'));
    await t.pump(const Duration(seconds: 1));
    expect(tileLabel(t, 'Echo'), contains('playing')); // tail makes it longer
    await t.pump(const Duration(seconds: 4));
    expect(tileLabel(t, 'Echo'), isNot(contains('playing')));
    expect(find.text('Tap to play'), findsOneWidget);

    // Every voice renders.
    for (final name in [
      'Helium',
      'Deep',
      'Monster',
      'Robot',
      'Alien',
      'Stadium',
      'Radio',
      'Underwater',
      'Backwards',
      'Normal',
    ]) {
      await t.tap(tile(name));
      await t.pump();
      await waitForRender(t, name);
      expect(tileLabel(t, name), contains('playing'), reason: name);
    }

    // Record again: straight into a new recording, cache cleared.
    await t.tap(find.text('Record again'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Tap to stop'), findsOneWidget);
    expect(mics, hasLength(2));
    await feed(t, mic(), voice(0.8));
    await stopRecording(t);
    expect(find.text('Your recording'), findsOneWidget);
    expect(isSelected(t, 'Normal'), isTrue);
    await t.tap(tile('Chipmunk'));
    await t.pump();
    expect(tileLabel(t, 'Chipmunk'), contains('getting ready'));
    await waitForRender(t, 'Chipmunk');
    await close(t);
  });

  testWidgets('a very short recording goes back to the start', (t) async {
    await open(t);
    await record(t, 0.2);
    expect(find.text('Tap to record'), findsOneWidget);
    expect(find.textContaining('too short'), findsOneWidget);
    await close(t);
  });

  testWidgets('silence is not accepted', (t) async {
    await open(t);
    await record(t, 0); // nothing fed
    expect(find.text('Tap to record'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // let the snackbar go
    await t.tap(find.bySemanticsLabel('Record'));
    await t.pump();
    await feed(t, mic(), silence(1));
    await stopRecording(t);
    expect(find.textContaining('didn’t hear anything'), findsOneWidget);
    await close(t);
  });

  testWidgets('stops by itself at 15 seconds', (t) async {
    await open(t);
    await t.tap(find.bySemanticsLabel('Record'));
    await t.pump();
    await feed(t, mic(), voice(15.4));
    await settleStop(t);
    expect(find.text('Pick a voice'), findsOneWidget);
    expect(find.text('0:15'), findsOneWidget);
    await close(t);
  });

  testWidgets('fits a small phone without overflow', (t) async {
    await open(t, size: const Size(360, 640));
    expect(t.takeException(), isNull);
    await t.tap(find.bySemanticsLabel('Record'));
    await t.pump();
    await feed(t, mic(), voice(1));
    await stopRecording(t);
    expect(t.takeException(), isNull);
    expect(find.text("Add to soundboard"), findsOneWidget);
    await close(t);
  });
}
