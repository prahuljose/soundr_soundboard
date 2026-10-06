import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/screens/guitar_tuner_screen.dart';
import 'package:soundr_soundboard/services/guitar_tuning.dart';

import 'support/guitar_synth.dart';
import 'support/tuner_feed.dart';

/// The cents figure on screen, e.g. "−18 cents · 107.9 Hz" → -18.
double shownCents(WidgetTester t) {
  final text = t
      .widgetList<Text>(find.textContaining(' cents'))
      .map((w) => w.data!)
      .single;
  final m = RegExp(r'([+−])([0-9.]+) cents').firstMatch(text)!;
  return (m.group(1) == '−' ? -1 : 1) * double.parse(m.group(2)!);
}

double hz(int midi, double cents) => midiToHz(midi) * pow(2, cents / 1200).toDouble();

void main() {
  late StreamController<Uint8List> mic;

  Future<void> open(WidgetTester t) async {
    mic = StreamController<Uint8List>();
    t.view.physicalSize = const Size(390, 844) * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF)),
      home: GuitarTunerScreen(debugAudio: mic.stream),
    ));
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    unawaited(mic.close()); // awaiting would wait on the fake clock
  }

  testWidgets('waits for a note, then guides a flat A string up', (t) async {
    await open(t);
    expect(find.text('Pluck any string'), findsOneWidget);
    expect(find.text('E A D G B E'), findsOneWidget);

    await feed(t, mic, pluckedString(hz(45, -18), seconds: 0.9));
    expect(find.text('Tune up'), findsOneWidget);
    expect(find.text('A'), findsWidgets); // big note + its peg
    expect(shownCents(t), closeTo(-18, 2));

    await feed(t, mic, pluckedString(hz(45, 14), seconds: 0.9, seed: 9));
    expect(find.text('Tune down'), findsOneWidget);
    await close(t);
  });

  testWidgets('in tune: tick on the peg, and all six → done banner', (t) async {
    await open(t);
    await feed(t, mic, pluckedString(hz(50, 1), seconds: 1.4));
    expect(find.text('In tune'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'String 4, D, in tune')), findsOneWidget);

    for (final m in [40, 45, 55, 59, 64]) {
      await feed(t, mic, [...pluckedString(hz(m, -2), seconds: 1.4), ...silence(0.3)]);
    }
    expect(find.text('All six strings in tune'), findsOneWidget);
    await t.tap(find.text('Start over'));
    await t.pumpAndSettle();
    expect(find.text('All six strings in tune'), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'in tune$')), findsNothing);
    await close(t);
  });

  testWidgets('tapping a peg locks to that string and ignores the tone', (t) async {
    await open(t);
    await t.tap(find.bySemanticsLabel(RegExp(r'^String 6, E')));
    await t.pump();
    expect(find.text('Listen, then play the string'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);

    // The reference tone reaching the mic must not count as tuning.
    await feed(t, mic, pluckedString(hz(40, 0), seconds: 1.5));
    expect(find.bySemanticsLabel(RegExp(r'in tune$')), findsNothing);

    await feed(t, mic, silence(1.4));
    expect(find.text('Play the E string'), findsOneWidget);
    expect(find.text('Play E again'), findsOneWidget);

    // Way flat (a whole tone) still reads against the chosen string.
    await feed(t, mic, pluckedString(hz(38, 0), seconds: 0.9));
    expect(find.text('Tune up'), findsOneWidget);
    expect(shownCents(t), closeTo(-200, 3));

    // Back to auto.
    await t.tap(find.text('Auto'));
    await t.pump();
    expect(find.text('Pluck any string'), findsOneWidget);
    await close(t);
  });

  testWidgets('changing tuning and chromatic mode', (t) async {
    await open(t);
    await t.tap(find.text('Standard'));
    await t.pumpAndSettle();
    await t.tap(find.text('Drop D'));
    await t.pumpAndSettle();
    expect(find.text('D A D G B E'), findsOneWidget);

    await feed(t, mic, pluckedString(hz(38, 0), seconds: 1.4));
    expect(find.text('In tune'), findsOneWidget);

    await t.tap(find.text('Drop D'));
    await t.pumpAndSettle();
    await t.tap(find.text('Chromatic'));
    await t.pumpAndSettle();
    expect(find.text('Auto'), findsNothing);
    await feed(t, mic, pluckedString(hz(61, 9), seconds: 0.9));
    expect(find.text('C#'), findsOneWidget);
    expect(find.text('Tune down'), findsOneWidget);
    await close(t);
  });

  testWidgets('A4 calibration from the sheet', (t) async {
    await open(t);
    await t.tap(find.text('Standard'));
    await t.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await t.tap(find.byTooltip('Lower'));
      await t.pump();
    }
    expect(find.text('A4 = 432 Hz'), findsOneWidget);
    await t.tapAt(const Offset(195, 40)); // dismiss
    await t.pumpAndSettle();
    expect(find.textContaining('A4 432 Hz'), findsOneWidget);
    // 110 Hz is +32 cents against A4 = 432.
    await feed(t, mic, pluckedString(110, seconds: 0.9));
    expect(find.text('Tune down'), findsOneWidget);
    expect(shownCents(t), closeTo(31.8, 2));
    await close(t);
  });
}
