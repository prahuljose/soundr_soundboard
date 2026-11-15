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

  Future<void> open(WidgetTester t,
      {Map<String, String>? prefs, Size size = const Size(390, 844)}) async {
    mic = StreamController<Uint8List>();
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF)),
      home: GuitarTunerScreen(debugAudio: mic.stream, debugPrefs: prefs),
    ));
    await t.pump();
    await t.pump();
  }

  /// Opens the sheet from the tuning button (found by its current title)
  /// and picks an instrument.
  Future<void> pickInstrument(WidgetTester t, String button, String name) async {
    await t.tap(find.text(button));
    await t.pumpAndSettle();
    await t.tap(find.text(name));
    await t.pumpAndSettle();
  }

  Future<void> dismissSheet(WidgetTester t) async {
    await t.tapAt(const Offset(195, 40));
    await t.pumpAndSettle();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    unawaited(mic.close()); // awaiting would wait on the fake clock
  }

  testWidgets('waits for a note, then guides a flat A string up', (t) async {
    await open(t);
    expect(find.text('Tuner'), findsOneWidget);
    expect(find.text('Guitar · Standard'), findsOneWidget);
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
    expect(find.text('All 6 strings in tune'), findsOneWidget);
    await t.tap(find.text('Start over'));
    await t.pumpAndSettle();
    expect(find.text('All 6 strings in tune'), findsNothing);
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
    await t.tap(find.text('Guitar · Standard'));
    await t.pumpAndSettle();
    await t.tap(find.text('Drop D'));
    await t.pumpAndSettle();
    expect(find.text('D A D G B E'), findsOneWidget);

    await feed(t, mic, pluckedString(hz(38, 0), seconds: 1.4));
    expect(find.text('In tune'), findsOneWidget);

    await t.tap(find.text('Guitar · Drop D'));
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
    await t.tap(find.text('Guitar · Standard'));
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

  // ── Other instruments ────────────────────────────────────────────────────

  testWidgets('ukulele: pick it, four pegs in G C E A order, tune the high G', (t) async {
    await open(t);
    await pickInstrument(t, 'Guitar · Standard', 'Ukulele');
    // The sheet stays open on the ukulele's tunings.
    expect(find.text('Low G'), findsOneWidget);
    expect(find.text('Baritone'), findsOneWidget);
    expect(find.text('Drop D'), findsNothing);
    await dismissSheet(t);

    expect(find.text('Ukulele · Standard'), findsOneWidget);
    expect(find.text('G C E A'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^String \d')), findsNWidgets(4));
    for (final label in ['String 4, G', 'String 3, C', 'String 2, E', 'String 1, A']) {
      expect(find.bySemanticsLabel(label), findsOneWidget);
    }
    // As on the instrument: G below C on the left, E above A on the right.
    Offset at(String l) => t.getCenter(find.bySemanticsLabel(l));
    expect(at('String 4, G').dx, lessThan(195));
    expect(at('String 3, C').dx, at('String 4, G').dx);
    expect(at('String 4, G').dy, greaterThan(at('String 3, C').dy));
    expect(at('String 1, A').dx, greaterThan(195));
    expect(at('String 2, E').dx, at('String 1, A').dx);
    expect(at('String 1, A').dy, greaterThan(at('String 2, E').dy));
    for (final l in ['String 4, G', 'String 3, C', 'String 2, E', 'String 1, A']) {
      final size = t.getSize(find.bySemanticsLabel(l));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }

    // G4 (392 Hz) is string 4 even though it's higher than strings 3 and 2.
    await feed(t, mic, pluckedString(hz(67, -14), seconds: 0.9));
    expect(find.text('Tune up'), findsOneWidget);
    expect(shownCents(t), closeTo(-14, 2));
    expect(
      t.getSemantics(find.bySemanticsLabel('String 4, G')),
      isSemantics(isSelected: true, isButton: true, hasSelectedState: true, hasTapAction: true, label: 'String 4, G'),
    );
    await feed(t, mic, [...silence(0.3), ...pluckedString(hz(67, 1), seconds: 1.4, seed: 5)]);
    expect(find.text('In tune'), findsOneWidget);
    expect(find.bySemanticsLabel('String 4, G, in tune'), findsOneWidget);

    for (final m in [60, 64, 69]) {
      await feed(t, mic, [...silence(0.3), ...pluckedString(hz(m, -1), seconds: 1.4)]);
    }
    expect(find.text('All 4 strings in tune'), findsOneWidget);
    await close(t);
  });

  testWidgets('ukulele low G, and the tuning is remembered per instrument', (t) async {
    final prefs = <String, String>{};
    await open(t, prefs: prefs);
    await pickInstrument(t, 'Guitar · Standard', 'Ukulele');
    await t.tap(find.text('Low G'));
    await t.pumpAndSettle();
    expect(find.text('Ukulele · Low G'), findsOneWidget);
    await feed(t, mic, pluckedString(hz(55, 0), seconds: 1.4));
    expect(find.bySemanticsLabel('String 4, G, in tune'), findsOneWidget);

    // Over to guitar (ticks cleared), then back: still Low G.
    await pickInstrument(t, 'Ukulele · Low G', 'Guitar');
    await dismissSheet(t);
    expect(find.text('Guitar · Standard'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^String \d')), findsNWidgets(6));
    expect(find.bySemanticsLabel(RegExp(r'in tune$')), findsNothing);
    await pickInstrument(t, 'Guitar · Standard', 'Ukulele');
    await dismissSheet(t);
    expect(find.text('Ukulele · Low G'), findsOneWidget);
    expect(prefs['tuner_instrument'], 'ukulele');
    expect(prefs['tuner_tuning_ukulele'], 'uke_low_g');
    expect(prefs['tuner_tuning'], 'standard');
    await close(t);
  });

  testWidgets('bass: E1 through a phone mic, 5-string, octave-up reference', (t) async {
    await open(t);
    await pickInstrument(t, 'Guitar · Standard', 'Bass');
    await dismissSheet(t);
    expect(find.text('Bass · Standard'), findsOneWidget);
    expect(find.text('E A D G'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^String \d')), findsNWidgets(4));

    // 41.2 Hz with a tenth of its fundamental, ringing on as a bass does.
    List<double> low(int m, double c, {double seconds = 1.0}) => pluckedString(
        hz(m, c), seconds: seconds, fundamentalGain: 0.1, sustain: 2);
    await feed(t, mic, low(28, -20));
    expect(find.text('Tune up'), findsOneWidget);
    expect(find.text('E'), findsWidgets);
    expect(find.text('1'), findsOneWidget); // E1, not E2
    expect(shownCents(t), closeTo(-20, 2));
    await feed(t, mic, [...silence(0.3), ...low(28, 0, seconds: 1.5)]);
    expect(find.bySemanticsLabel('String 4, E, in tune'), findsOneWidget);
    for (final m in [33, 38, 43]) {
      await feed(t, mic, [...silence(0.3), ...low(m, 1, seconds: 1.5)]);
    }
    expect(find.text('All 4 strings in tune'), findsOneWidget);
    await t.tap(find.text('Start over'));
    await t.pumpAndSettle();

    // A short, dull note fades before it has been in tune long enough;
    // a second pluck finishes the job.
    List<double> dull(int m) =>
        pluckedString(hz(m, 0), seconds: 0.9, fundamentalGain: 0.1);
    await feed(t, mic, dull(38));
    expect(find.text('In tune'), findsOneWidget);
    expect(find.bySemanticsLabel('String 2, D, in tune'), findsNothing);
    await feed(t, mic, dull(38));
    expect(find.bySemanticsLabel('String 2, D, in tune'), findsOneWidget);

    // Five strings: the low B (30.9 Hz).
    await t.tap(find.text('Bass · Standard'));
    await t.pumpAndSettle();
    await t.tap(find.text('5-string'));
    await t.pumpAndSettle();
    expect(find.text('Bass · 5-string'), findsOneWidget);
    expect(find.text('All 4 strings in tune'), findsNothing);
    expect(find.bySemanticsLabel(RegExp(r'^String \d')), findsNWidgets(5));
    for (var n = 1; n <= 5; n++) {
      final size = t.getSize(find.bySemanticsLabel(RegExp('^String $n,')));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
    await feed(t, mic, low(23, 12));
    expect(find.text('B'), findsWidgets);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('Tune down'), findsOneWidget);
    expect(shownCents(t), closeTo(12, 2));

    // Picking a peg plays (an octave up) and says so; the mic is ignored
    // while it sounds.
    await t.tap(find.bySemanticsLabel(RegExp(r'^String 5, B')));
    await t.pump();
    expect(find.text('Listen, then play the string'), findsOneWidget);
    expect(find.textContaining('octave higher'), findsOneWidget);
    await feed(t, mic, low(23, 0, seconds: 1.5));
    expect(find.bySemanticsLabel(RegExp(r'in tune$')), findsNothing);
    await feed(t, mic, silence(1.4));
    expect(find.text('Play the B string'), findsOneWidget);
    await feed(t, mic, low(23, 0, seconds: 1.5));
    expect(find.bySemanticsLabel('String 5, B, in tune'), findsOneWidget);
    expect(find.textContaining('octave higher'), findsNothing);
    await close(t);
  });

  testWidgets('violin: bowed strings up to E5; viola and cello', (t) async {
    await open(t);
    await pickInstrument(t, 'Guitar · Standard', 'Violin');
    expect(find.text('Viola'), findsOneWidget);
    expect(find.text('Cello'), findsOneWidget);
    await dismissSheet(t);
    expect(find.text('Violin'), findsOneWidget); // not "Violin · Violin"
    expect(find.text('G D A E'), findsOneWidget);
    expect(find.text('Play any string'), findsOneWidget);
    // Pegs: G below D on the left, A above E on the right.
    Offset at(String l) => t.getCenter(find.bySemanticsLabel(l));
    expect(at('String 4, G').dx, lessThan(at('String 1, E').dx));
    expect(at('String 4, G').dy, greaterThan(at('String 3, D').dy));
    expect(at('String 1, E').dy, greaterThan(at('String 2, A').dy));

    await feed(t, mic, bowedString(hz(76, 9), seconds: 0.9));
    expect(find.text('Tune down'), findsOneWidget);
    expect(find.text('5'), findsOneWidget); // E5
    expect(shownCents(t), closeTo(9, 2));
    for (final m in [55, 62, 69, 76]) {
      await feed(t, mic, [...silence(0.4), ...bowedString(hz(m, 0), seconds: 1.3)]);
    }
    expect(find.text('All 4 strings in tune'), findsOneWidget);

    // Cello needs the detector to listen lower (C2 = 65 Hz).
    await t.tap(find.text('Violin'));
    await t.pumpAndSettle();
    await t.tap(find.text('Cello'));
    await t.pumpAndSettle();
    expect(find.text('C G D A'), findsOneWidget);
    await feed(t, mic, bowedString(hz(36, -11), seconds: 0.9));
    expect(find.text('Tune up'), findsOneWidget);
    expect(find.bySemanticsLabel('String 4, C'), findsOneWidget);
    expect(shownCents(t), closeTo(-11, 2));
    await close(t);
  });

  testWidgets('chromatic follows the instrument; picking one leaves chromatic', (t) async {
    await open(t);
    await pickInstrument(t, 'Guitar · Standard', 'Bass');
    await t.tap(find.text('Chromatic'));
    await t.pumpAndSettle();
    expect(find.text('Any note in bass range'), findsOneWidget);
    // F1 (43.65 Hz): not an open string.
    await feed(t, mic, pluckedString(hz(29, -6), seconds: 1.0, fundamentalGain: 0.1));
    expect(find.text('F'), findsOneWidget);
    expect(shownCents(t), closeTo(-6, 2));

    await pickInstrument(t, 'Chromatic', 'Ukulele');
    await dismissSheet(t);
    expect(find.text('Ukulele · Standard'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    await close(t);
  });

  testWidgets('every peg is a 44 px tap target on a small phone', (t) async {
    for (final (instrument, tuning, count) in [
      ('guitar', 'standard', 6),
      ('ukulele', 'uke_standard', 4),
      ('bass', 'bass_5', 5),
      ('violin', 'cello', 4),
    ]) {
      await open(t,
          size: const Size(360, 640),
          prefs: {
            'tuner_instrument': instrument,
            'tuner_tuning${instrument == 'guitar' ? '' : '_$instrument'}': tuning,
          });
      final pegs = find.bySemanticsLabel(RegExp(r'^String \d'));
      expect(pegs, findsNWidgets(count), reason: instrument);
      final rects = [for (final e in pegs.evaluate()) t.getRect(find.byWidget(e.widget))];
      for (final r in rects) {
        expect(r.width, greaterThanOrEqualTo(44), reason: instrument);
        expect(r.height, greaterThanOrEqualTo(44), reason: instrument);
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(360));
      }
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          // Neighbours may touch, not overlap.
          expect(rects[i].deflate(0.01).overlaps(rects[j]), isFalse,
              reason: '$instrument $i/$j ${rects[i]} ${rects[j]}');
        }
      }
      await close(t);
    }
  });

  // ── Saved settings ───────────────────────────────────────────────────────

  testWidgets('settings saved by the guitar-only tuner still load', (t) async {
    // No tuner_instrument key back then.
    await open(t, prefs: {'tuner_tuning': 'dadgad', 'tuner_a4': '442'});
    expect(find.text('Guitar · DADGAD'), findsOneWidget);
    expect(find.textContaining('A4 442 Hz'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^String \d')), findsNWidgets(6));
    await close(t);
  });

  testWidgets('a saved instrument opens with its own tuning and detector', (t) async {
    await open(t, prefs: {
      'tuner_instrument': 'bass',
      'tuner_tuning': 'drop_d',
      'tuner_tuning_bass': 'bass_5',
      'tuner_tuning_ukulele': 'uke_baritone',
    });
    expect(find.text('Bass · 5-string'), findsOneWidget);
    expect(find.text('B E A D G'), findsOneWidget);
    await feed(t, mic, pluckedString(hz(23, 0), seconds: 1.5, fundamentalGain: 0.1));
    expect(find.bySemanticsLabel('String 5, B, in tune'), findsOneWidget);

    await pickInstrument(t, 'Bass · 5-string', 'Ukulele');
    await dismissSheet(t);
    expect(find.text('Ukulele · Baritone'), findsOneWidget);
    await pickInstrument(t, 'Ukulele · Baritone', 'Guitar');
    await dismissSheet(t);
    expect(find.text('Guitar · Drop D'), findsOneWidget);
    await close(t);
  });

  testWidgets('unknown saved ids fall back to guitar, standard', (t) async {
    await open(t, prefs: {'tuner_instrument': 'sitar', 'tuner_tuning': 'nope'});
    expect(find.text('Guitar · Standard'), findsOneWidget);
    await close(t);
  });
}
