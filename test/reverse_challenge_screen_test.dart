import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/screens/reverse_challenge_screen.dart';
import 'package:soundr_soundboard/services/clip_player.dart';
import 'package:soundr_soundboard/services/reverse_score.dart';

import 'reverse_score_test.dart' show speechLike, whiteNoise, bananaPancakes;
import 'support/tuner_feed.dart';

/// Lets a recording finish stopping. Cancelling a stream subscription
/// completes on the real event loop, not the test's fake clock.
Future<void> settleStop(WidgetTester t) async {
  await t.pump();
  await t.runAsync(() => Future<void>.delayed(Duration.zero));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  late StreamController<Uint8List> mic;
  final phrase = speechLike(bananaPancakes);

  Future<void> open(WidgetTester t, {Brightness b = Brightness.dark}) async {
    mic = StreamController<Uint8List>();
    t.view.physicalSize = const Size(390, 844) * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildSoundrTheme(b, const Color(0xFF6C63FF)),
      home: ReverseChallengeScreen(
        // A fresh mic stream for each recording.
        debugMic: () {
          unawaited(mic.close());
          mic = StreamController<Uint8List>();
          return mic.stream;
        },
        debugPhrase: 0,
        debugPlayer: SilentClipPlayer(),
      ),
    ));
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    unawaited(mic.close()); // awaiting would wait on the fake clock
  }

  Finder sem(String label) => find.bySemanticsLabel(label);

  /// Taps the record button, feeds [samples] like a live mic, then taps
  /// stop (unless it stopped by itself).
  Future<void> record(WidgetTester t, String idleLabel, List<double> samples) async {
    await t.tap(sem(idleLabel));
    await t.pump();
    expect(find.textContaining('tap to stop'), findsOneWidget);
    await feed(t, mic, samples);
    if (sem('Stop recording').evaluate().isNotEmpty) {
      await t.tap(sem('Stop recording'));
    }
    await settleStop(t);
  }

  int shownScore(WidgetTester t) {
    final label = t.getSemantics(find.bySemanticsLabel(RegExp(r'^Match score'))).label;
    return int.parse(RegExp(r'Match score (\d+)').firstMatch(label)!.group(1)!);
  }

  testWidgets('full round: record, copy backwards, reveal, try again, new phrase',
      (t) async {
    final semantics = t.ensureSemantics();
    await open(t);

    // Step 1.
    expect(find.text('Say something'), findsOneWidget);
    expect(find.text('“Banana pancakes”'), findsOneWidget);
    expect(sem('Step 1 of 3: Record'), findsOneWidget);
    expect(find.text('Tap to record · up to 6 s'), findsOneWidget);

    // Shuffle changes the suggestion.
    await t.tap(find.byTooltip('Another phrase'));
    await t.pumpAndSettle();
    expect(find.text('“Banana pancakes”'), findsNothing);
    final suggested = t.widget<Text>(find.textContaining('“')).data;

    await record(t, 'Tap to record', phrase);

    // Step 2, with the reversed phrase playing by itself.
    expect(sem('Step 2 of 3: Copy it backwards'), findsOneWidget);
    expect(find.text('Listen a few times, then copy the sounds.'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 300));
    expect(sem('Stop Your phrase, backwards'), findsOneWidget);
    await t.pump(const Duration(seconds: 3)); // let it finish (timer-driven)
    await t.pump();
    expect(sem('Play Your phrase, backwards'), findsOneWidget);

    // A good copy: the phrase said backwards, a bit slower, in a noisy room.
    final copy = ReverseScore.reverse(
        speechLike(bananaPancakes, stretch: 1.1, noise: 0.01, seed: 2));
    await record(t, 'Record your copy', copy);

    // Step 3.
    expect(sem('Step 3 of 3: Reveal'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 400));
    expect(sem('Stop Your attempt, reversed'), findsOneWidget); // auto-plays
    await t.pump(const Duration(seconds: 3));
    await t.pumpAndSettle();
    expect(sem('Play Your attempt, reversed'), findsOneWidget);
    final good = shownScore(t);
    expect(good, greaterThanOrEqualTo(70));
    expect(find.text('$good'), findsOneWidget); // count-up finished
    expect(find.text('New personal best!'), findsOneWidget);
    expect(find.text(ReverseScore.message(good)), findsOneWidget);

    // Compare buttons play each clip.
    await t.tap(sem('Play Original'));
    await t.pump(const Duration(milliseconds: 100));
    expect(sem('Stop Original'), findsOneWidget);
    await t.tap(sem('Play Your attempt as recorded'));
    await t.pump(const Duration(milliseconds: 100));
    expect(sem('Stop Your attempt as recorded'), findsOneWidget);
    expect(sem('Play Original'), findsOneWidget);
    await t.tap(sem('Stop Your attempt as recorded'));
    await t.pump();
    expect(sem('Play Your attempt as recorded'), findsOneWidget);

    // Try again keeps the phrase and goes back to step 2.
    await t.tap(find.text('Try again'));
    await t.pumpAndSettle();
    expect(sem('Step 2 of 3: Copy it backwards'), findsOneWidget);
    expect(find.text('Your phrase, backwards'), findsOneWidget);

    // A bad copy (just noise) scores low and keeps the earlier best.
    await record(t, 'Record your copy', whiteNoise(1.5));
    await t.pumpAndSettle();
    expect(shownScore(t), lessThanOrEqualTo(40));
    expect(find.text('Personal best  $good'), findsOneWidget);

    // New phrase goes back to step 1 with another suggestion.
    await t.tap(find.text('New phrase'));
    await t.pumpAndSettle();
    expect(sem('Step 1 of 3: Record'), findsOneWidget);
    expect(find.text('Say something'), findsOneWidget);
    expect(find.textContaining('“'), findsOneWidget);
    expect(t.widget<Text>(find.textContaining('“')).data, isNot(suggested));

    await close(t);
    semantics.dispose();
  });

  testWidgets('the phrase stops by itself at 6 s', (t) async {
    final semantics = t.ensureSemantics();
    await open(t);
    await t.tap(sem('Tap to record'));
    await t.pump();
    // 7.5 s of talking: recording should stop at 6 s and move on.
    await feed(t, mic, [...phrase, ...phrase, ...phrase, ...phrase]..length = 44100 * 15 ~/ 2);
    await settleStop(t);
    expect(sem('Step 2 of 3: Copy it backwards'), findsOneWidget);
    final len = RegExp(r'^(\d+\.\d) s$');
    final shown = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .whereType<String>()
        .map(len.firstMatch)
        .whereType<RegExpMatch>()
        .map((m) => double.parse(m.group(1)!))
        .single;
    expect(shown, lessThanOrEqualTo(6.1));
    expect(shown, greaterThan(5));
    await close(t);
    semantics.dispose();
  });

  testWidgets('silence is rejected with a hint, staying on step 1', (t) async {
    final semantics = t.ensureSemantics();
    await open(t);
    await record(t, 'Tap to record', silence(1.5));
    expect(find.textContaining('Didn’t catch that'), findsOneWidget);
    expect(sem('Step 1 of 3: Record'), findsOneWidget);
    expect(find.text('Tap to record · up to 6 s'), findsOneWidget);
    await close(t);
    semantics.dispose();
  });

  testWidgets('re-record phrase goes back to step 1', (t) async {
    final semantics = t.ensureSemantics();
    await open(t, b: Brightness.light);
    await record(t, 'Tap to record', phrase);
    expect(sem('Step 2 of 3: Copy it backwards'), findsOneWidget);
    await t.tap(find.text('Re-record phrase'));
    await t.pumpAndSettle();
    expect(sem('Step 1 of 3: Record'), findsOneWidget);
    expect(find.text('“Banana pancakes”'), findsOneWidget); // same suggestion
    await close(t);
    semantics.dispose();
  });
}

/// A [ClipPlayer] without the audio engine (SoLoud's native library isn't
/// loaded in tests): just the playhead, advanced by a timer.
class SilentClipPlayer extends ClipPlayer {
  Timer? _ticker;

  @override
  Future<void> play(Float64List samples, {Object tag = true, int sampleRate = 44100}) async {
    await stop();
    final totalMs = samples.length * 1000 ~/ sampleRate;
    if (totalMs == 0) return;
    playing.value = tag;
    progress.value = 0;
    var ms = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 30), (_) {
      ms += 30;
      if (ms >= totalMs) {
        stop();
      } else {
        progress.value = ms / totalMs;
      }
    });
  }

  @override
  Future<void> stop() async {
    _ticker?.cancel();
    _ticker = null;
    progress.value = null;
    playing.value = null;
  }
}
