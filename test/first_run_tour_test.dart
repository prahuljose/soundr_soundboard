import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/widgets/first_run_tour.dart';

Widget _host({required bool tabs}) => MaterialApp(
      theme: buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF)),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showFirstRunTour(context, tabs: tabs),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

// The illustrations loop forever, so pumpAndSettle would never return.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _open(WidgetTester t, {required bool tabs}) async {
  await t.pumpWidget(_host(tabs: tabs));
  await t.tap(find.text('open'));
  await _settle(t);
}

const _titles = [
  'Tap to play',
  'Long-press for more',
  'Make your own',
  'Tools & games',
];

void main() {
  testWidgets('walks through four steps and closes on "Let’s go"', (t) async {
    final semantics = t.ensureSemantics();
    await _open(t, tabs: true);

    for (var i = 0; i < _titles.length; i++) {
      expect(find.text(_titles[i]), findsOneWidget, reason: 'step ${i + 1}');
      expect(find.bySemanticsLabel('Step ${i + 1} of ${_titles.length}'),
          findsOneWidget);
      if (i < _titles.length - 1) {
        expect(find.text('Next'), findsOneWidget);
        expect(find.text('Let’s go'), findsNothing);
        await t.tap(find.text('Next'));
        await _settle(t);
      }
    }

    // Last step: no more Next, and Skip is switched off.
    expect(find.text('Next'), findsNothing);
    expect(
      t.widget<TextButton>(find.widgetWithText(TextButton, 'Skip')).onPressed,
      isNull,
    );
    await t.tap(find.text('Let’s go'));
    await _settle(t);
    expect(find.text('Tools & games'), findsNothing);
    expect(find.text('open'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('Skip closes the tour from any earlier step', (t) async {
    await _open(t, tabs: true);
    await t.tap(find.text('Next'));
    await _settle(t);
    expect(find.text('Long-press for more'), findsOneWidget);

    await t.tap(find.text('Skip'));
    await _settle(t);
    expect(find.text('Long-press for more'), findsNothing);
    expect(find.text('Skip'), findsNothing);
  });

  testWidgets('long-press step mentions loop, speed, share and widget',
      (t) async {
    await _open(t, tabs: true);
    await t.tap(find.text('Next'));
    await _settle(t);
    final body = find.textContaining('home-screen widget');
    expect(body, findsOneWidget);
    final text = t.widget<Text>(body).data!;
    for (final word in ['Loop', 'speed', 'share', 'pin']) {
      expect(text, contains(word));
    }
  });

  for (final tabs in [true, false]) {
    testWidgets('last step describes the ${tabs ? 'tabs' : 'drawer'} layout',
        (t) async {
      await _open(t, tabs: tabs);
      for (var i = 0; i < _titles.length - 1; i++) {
        await t.tap(find.text('Next'));
        await _settle(t);
      }
      expect(find.textContaining('tabs at the bottom'),
          tabs ? findsOneWidget : findsNothing);
      expect(find.textContaining('Swipe in from the left edge'),
          tabs ? findsNothing : findsOneWidget);
      expect(find.text('Let’s go'), findsOneWidget);
    });
  }

  testWidgets('fits a small phone without overflowing', (t) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await _open(t, tabs: false);
    for (var i = 0; i < _titles.length - 1; i++) {
      expect(t.takeException(), isNull);
      await t.tap(find.text('Next'));
      await _settle(t);
    }
    expect(t.takeException(), isNull);
  });
}
