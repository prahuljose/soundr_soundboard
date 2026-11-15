import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/screens/sing_note_screen.dart';
import 'package:soundr_soundboard/theme/app_colors.dart';
import 'package:soundr_soundboard/widgets/sing_note_widgets.dart';

import 'sing_note_game_test.dart' show hz, voice;
import 'support/tuner_feed.dart';

void main() {
  late StreamController<Uint8List> mic;

  Future<void> open(
    WidgetTester t, {
    List<int> notes = const [57, 60, 64],
    int? best,
    Size size = const Size(390, 844),
  }) async {
    // Broadcast, so "Play again" can listen a second time.
    mic = StreamController<Uint8List>.broadcast();
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      // Not buildSoundrTheme: importing main.dart pulls in every screen.
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'Outfit',
        extensions: const [AppColors.dark],
      ),
      home: SingNoteScreen(debugAudio: mic.stream, debugNotes: notes, debugBest: best),
    ));
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    unawaited(mic.close()); // awaiting would wait on the fake clock
  }

  Future<void> start(WidgetTester t) async {
    await t.tap(find.text('Start'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  /// Sits through the reference tone until it's time to sing.
  Future<void> listenThrough(WidgetTester t) async {
    expect(find.text('Listen…'), findsOneWidget);
    await feed(t, mic, silence(2.2));
    expect(find.text('Now sing or hum it'), findsOneWidget);
  }

  Future<void> singIt(WidgetTester t, double f, {double seconds = 1.6, int seed = 1}) =>
      feed(t, mic, voice(f, seconds: seconds, seed: seed));

  SingStage stage(WidgetTester t) => t.widget<SingStage>(find.byType(SingStage));

  testWidgets('start screen explains the game and shows the best', (t) async {
    await open(t, best: 72);
    expect(find.text('Sing the Note'), findsNWidgets(2)); // app bar + heading
    expect(find.text('Listen to a note, then sing or hum it back.'), findsOneWidget);
    expect(find.text('Personal best  72'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    await t.pumpAndSettle(); // nothing animating while idle
    await close(t);
  });

  testWidgets('listen → sing the note → tick → next note', (t) async {
    await open(t);
    expect(find.text('No best yet'), findsOneWidget);
    await start(t);
    expect(find.bySemanticsLabel('Note 1 of 3'), findsOneWidget);
    expect(stage(t).note, 'A');
    expect(stage(t).mode, SingStageMode.listen);
    // Can't replay the tone while it's playing.
    expect(
      t.widget<OutlinedButton>(find.ancestor(of: find.text('Hear it again'), matching: find.bySubtype<OutlinedButton>())).onPressed,
      isNull,
    );
    await listenThrough(t);

    await singIt(t, hz(57, 6), seconds: 0.6);
    expect(find.text('Hold it…'), findsOneWidget);
    expect(stage(t).progress, inExclusiveRange(0.1, 0.8));
    await singIt(t, hz(57, 6), seconds: 1.0, seed: 2);
    expect(find.textContaining(RegExp(r'^(Nice!|Spot on!)$')), findsOneWidget);
    expect(stage(t).mode, SingStageMode.hit);

    await feed(t, mic, silence(1.3));
    expect(find.bySemanticsLabel('Note 2 of 3'), findsOneWidget);
    expect(stage(t).note, 'C');
    expect(find.text('Listen…'), findsOneWidget);
    await close(t);
  });

  testWidgets('an octave lower counts too', (t) async {
    await open(t);
    await start(t);
    await listenThrough(t);
    await singIt(t, hz(45, -4), seconds: 1.7);
    expect(stage(t).mode, SingStageMode.hit);
    await close(t);
  });

  testWidgets('a wrong note gets pointed the right way', (t) async {
    await open(t);
    await start(t);
    await listenThrough(t);

    await singIt(t, hz(55), seconds: 0.8); // G under A
    expect(find.text('Too low'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    expect(stage(t).cents, closeTo(-200, 25));
    expect(stage(t).progress, 0);

    await singIt(t, hz(46, 20), seconds: 0.8, seed: 3); // A#, an octave down
    expect(find.text('Too high'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);

    await feed(t, mic, silence(0.5));
    expect(find.text('Now sing or hum it'), findsOneWidget);
    await close(t);
  });

  testWidgets('the reference tone reaching the mic is ignored', (t) async {
    await open(t);
    await start(t);
    // The tone, then its tail, arriving at the mic.
    await feed(t, mic, voice(hz(57), seconds: 1.4, vibratoCents: 0));
    expect(find.text('Listen…'), findsOneWidget);
    await feed(t, mic, voice(hz(57), seconds: 0.3, vibratoCents: 0));
    await feed(t, mic, silence(0.3));
    expect(find.text('Now sing or hum it'), findsOneWidget);
    expect(stage(t).progress, 0);
    await close(t);
  });

  testWidgets('hear it again replays the tone and keeps progress', (t) async {
    await open(t);
    await start(t);
    await listenThrough(t);
    await singIt(t, hz(57), seconds: 0.7);
    final progress = stage(t).progress;
    expect(progress, greaterThan(0.2));

    await t.tap(find.text('Hear it again'));
    await t.pump();
    expect(find.text('Listen…'), findsOneWidget);
    expect(stage(t).mode, SingStageMode.listen);
    await feed(t, mic, silence(2.2));
    expect(find.text('Now sing or hum it'), findsOneWidget);
    expect(stage(t).progress, progress);
    await close(t);
  });

  testWidgets('running out of time moves on', (t) async {
    await open(t);
    await start(t);
    await listenThrough(t);
    await singIt(t, hz(57, 70), seconds: 6.0);
    expect(find.text('So close!'), findsOneWidget);
    expect(stage(t).mode, SingStageMode.missed);
    await feed(t, mic, silence(1.3));
    expect(find.bySemanticsLabel('Note 2 of 3'), findsOneWidget);

    await listenThrough(t);
    await feed(t, mic, silence(6.1));
    expect(find.text('Time’s up'), findsOneWidget);
    await close(t);
  });

  testWidgets('a short round ends on the score; play again restarts', (t) async {
    await open(t, notes: const [57, 61], best: 40);
    await start(t);
    await listenThrough(t);
    await singIt(t, hz(57, 3));
    await feed(t, mic, silence(1.3));

    expect(stage(t).note, 'C#');
    await listenThrough(t);
    await t.tap(find.text('Skip'));
    await t.pump();
    expect(find.text('Skipped'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 600));
    await t.pumpAndSettle();

    // One of two notes: 50 at best.
    expect(find.byType(SingScoreCard), findsOneWidget);
    final card = t.widget<SingScoreCard>(find.byType(SingScoreCard));
    expect(card.score, inInclusiveRange(40, 50));
    expect(card.stars, 1);
    expect(card.newBest, isTrue);
    expect(find.text('${card.score}'), findsOneWidget);
    expect(find.text('New personal best!'), findsOneWidget);
    expect(find.text('Getting there'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^1 of 2 notes hit\. A hit, C# missed')), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);

    await t.tap(find.text('Play again'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.bySemanticsLabel('Note 1 of 2'), findsOneWidget);
    await listenThrough(t);
    await singIt(t, hz(69, -3));
    expect(stage(t).mode, SingStageMode.hit);
    await close(t);
  });

  testWidgets('a perfect round scores near 100 with three stars', (t) async {
    await open(t, notes: const [60, 62], best: 99);
    await start(t);
    for (final m in [60, 62]) {
      await listenThrough(t);
      await singIt(t, hz(m - 12, 2), seconds: 1.5);
      await feed(t, mic, silence(1.3));
    }
    await t.pumpAndSettle();
    final card = t.widget<SingScoreCard>(find.byType(SingScoreCard));
    expect(card.score, greaterThanOrEqualTo(95));
    expect(card.stars, 3);
    expect(find.text('Pitch perfect!'), findsOneWidget);
    expect(find.text(card.score > 99 ? 'New personal best!' : 'Personal best  99'), findsOneWidget);
    await close(t);
  });

  testWidgets('leaving mid-note leaves no timers behind', (t) async {
    await open(t, size: const Size(360, 640));
    await start(t);
    await close(t); // while the tone plays
    await open(t, size: const Size(360, 640));
    await start(t);
    await listenThrough(t);
    await singIt(t, hz(57), seconds: 0.5);
    await close(t); // mid-hold
  });
}
