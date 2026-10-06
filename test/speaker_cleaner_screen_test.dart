import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/screens/speaker_cleaner_screen.dart';

void main() {
  Future<void> open(WidgetTester t, {bool pushed = false}) async {
    t.view.physicalSize = const Size(390, 844) * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF)),
      home: pushed
          ? Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SpeakerCleanerScreen(),
                      ),
                    ),
                    child: const Text('Open cleaner'),
                  ),
                ),
              ),
            )
          : const SpeakerCleanerScreen(),
    ));
    if (pushed) {
      await t.tap(find.text('Open cleaner'));
      await t.pumpAndSettle();
    }
    await t.pump();
  }

  /// Taps Start and lets the controls cross-fade (the countdown keeps going).
  Future<void> start(WidgetTester t) async {
    await t.tap(find.text('Start'));
    await t.pump();
    await t.pump();
  }

  Future<void> crossFade(WidgetTester t) =>
      t.pump(const Duration(milliseconds: 300));

  testWidgets('idle screen settles and switches modes', (t) async {
    await open(t);
    await t.pumpAndSettle(); // nothing animates while idle
    expect(find.text('Speaker Cleaner'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('30 seconds'), findsOneWidget);
    expect(find.textContaining('165 Hz'), findsOneWidget);
    expect(find.text('Turn the volume all the way up'), findsOneWidget);
    expect(find.text('Point the speaker down'), findsOneWidget);

    await t.tap(find.text('Dust'));
    await t.pumpAndSettle();
    expect(find.textContaining('200–1500 Hz'), findsOneWidget);
    expect(find.text('20 seconds'), findsOneWidget);
    expect(find.text('10 s'), findsOneWidget);
    expect(find.text('40 s'), findsOneWidget);

    await t.tap(find.text('Deep'));
    await t.pumpAndSettle();
    expect(find.text('40 seconds'), findsOneWidget);

    // Each mode remembers its own length.
    await t.tap(find.text('Water'));
    await t.pumpAndSettle();
    expect(find.text('30 seconds'), findsOneWidget);
    await t.tap(find.text('Quick'));
    await t.pumpAndSettle();
    expect(find.text('15 seconds'), findsOneWidget);
  });

  testWidgets('start counts down, Stop returns to idle', (t) async {
    await open(t);
    await start(t);
    expect(find.text('0:30'), findsOneWidget);
    expect(find.text('Ejecting water'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await crossFade(t);
    expect(find.text('Quick'), findsNothing); // chips hidden while running

    await t.pump(const Duration(milliseconds: 4700));
    expect(find.text('0:25'), findsOneWidget);

    // Mode is locked while running.
    await t.tap(find.text('Dust'), warnIfMissed: false);
    await t.pump();
    expect(find.text('Ejecting water'), findsOneWidget);

    await t.tap(find.text('Stop'));
    await t.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    expect(find.text('Normal'), findsOneWidget);
  });

  testWidgets('runs to Done, then Run again', (t) async {
    await open(t);
    await t.tap(find.text('Dust'));
    await t.pumpAndSettle();
    await start(t);
    expect(find.text('0:20'), findsOneWidget);
    expect(find.text('Clearing dust'), findsOneWidget);

    await t.pump(const Duration(seconds: 10));
    expect(find.text('0:10'), findsOneWidget);
    await t.pump(const Duration(seconds: 10));
    await t.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Still crackly? Run it once more.'), findsOneWidget);
    expect(find.text('Run again'), findsOneWidget);

    await t.tap(find.text('Run again'));
    await t.pump();
    await t.pump();
    expect(find.text('0:20'), findsOneWidget);
    await crossFade(t);
    expect(find.text('Done'), findsNothing);
    await t.pump(const Duration(milliseconds: 2700));
    expect(find.text('0:17'), findsOneWidget);

    await t.pumpWidget(const SizedBox()); // leave mid-run
  });

  testWidgets('water done tip', (t) async {
    await open(t);
    await start(t);
    await t.pump(const Duration(seconds: 30));
    await t.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Still muffled? Run it once more.'), findsOneWidget);

    // Tapping the done dial goes back to the Start button and length chips.
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Deep'), findsOneWidget);

    // So does tapping the current mode once done.
    await start(t);
    await t.pump(const Duration(seconds: 30));
    await t.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);
    await t.tap(find.text('Water'));
    await t.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
  });

  testWidgets('leaving the screen mid-run stops cleanly', (t) async {
    await open(t, pushed: true);
    await start(t);
    await t.pump(const Duration(seconds: 3));
    expect(find.text('0:27'), findsOneWidget);
    await t.pageBack();
    await t.pumpAndSettle();
    expect(find.text('Open cleaner'), findsOneWidget);
    expect(find.byType(SpeakerCleanerScreen), findsNothing);
  });

  testWidgets('backgrounding the app stops the run', (t) async {
    await open(t);
    await start(t);
    await t.pump(const Duration(seconds: 2));
    expect(find.text('Stop'), findsOneWidget);

    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pump(const Duration(seconds: 1));
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pumpAndSettle(); // settles: nothing left running
    expect(find.text('Start'), findsOneWidget); // stopped, not restarted
    expect(find.text('Stop'), findsNothing);
    expect(find.text('Done'), findsNothing);
  });
}
