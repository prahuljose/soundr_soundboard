import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/screens/metronome_screen.dart';
import 'package:soundr_soundboard/services/metronome_presets.dart';
import 'package:soundr_soundboard/widgets/metronome_widgets.dart';

import 'bpm_detector_test.dart' show clickTrack;

void main() {
  late StreamController<Uint8List> mic;
  late MemoryMetronomeStore store;

  Future<void> open(WidgetTester t,
      {Size size = const Size(390, 844), Map<String, String>? saved}) async {
    mic = StreamController<Uint8List>();
    store = MemoryMetronomeStore(saved);
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final epoch = t.binding.clock.now();
    await t.pumpWidget(MaterialApp(
      theme: buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF)),
      home: MetronomeScreen(
        debugSoundReady: true,
        clock: () => t.binding.clock.now().difference(epoch),
        store: store,
        debugMicAudio: mic.stream,
      ),
    ));
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    unawaited(mic.close()); // awaiting would wait on the fake clock
  }

  /// Streams samples as 16-bit PCM in ~23 ms chunks, like a live mic.
  Future<void> feed(WidgetTester t, List<double> samples) async {
    const chunk = 1024;
    for (var i = 0; i < samples.length; i += chunk) {
      final end = (i + chunk).clamp(0, samples.length);
      final b = ByteData((end - i) * 2);
      for (var j = i; j < end; j++) {
        b.setInt16((j - i) * 2, (samples[j].clamp(-1.0, 1.0) * 32767).round(), Endian.little);
      }
      mic.add(b.buffer.asUint8List());
      await t.pump(const Duration(milliseconds: 23));
    }
  }

  /// The big tempo figure on the main screen.
  int shownBpm(WidgetTester t) => int.parse(t
      .widgetList<Text>(find.byWidgetPredicate(
          (w) => w is Text && (w.style?.fontSize ?? 0) == 92))
      .single
      .data!);

  String text(WidgetTester t, String key) =>
      t.widget<Text>(find.byKey(ValueKey(key))).data!;

  Future<void> openFinder(WidgetTester t) async {
    await t.ensureVisible(find.text('Find BPM'));
    await t.tap(find.text('Find BPM'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400)); // sheet slides up
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  testWidgets('finder, tap mode: five steady taps → BPM → Use sets the tempo', (t) async {
    await open(t);
    expect(shownBpm(t), 120);
    await openFinder(t);
    expect(text(t, 'bpm-tap-value'), '––');
    expect(find.text('Tap the pad in time with the music'), findsOneWidget);
    expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Use this tempo')).onPressed,
        isNull);

    final pad = find.byKey(const ValueKey('bpm-tap-pad'));
    await t.tap(pad);
    await t.pump();
    expect(find.text('Keep tapping…'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await t.pump(const Duration(milliseconds: 625));
      await t.tap(pad);
      await t.pump();
    }
    expect(text(t, 'bpm-tap-value'), '96');
    expect(find.text('Keep tapping… · 3 taps'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await t.pump(const Duration(milliseconds: 625));
      await t.tap(pad);
      await t.pump();
    }
    expect(text(t, 'bpm-tap-value'), '96');
    expect(find.text('Steady · 5 taps'), findsOneWidget);

    await t.tap(find.text('Use 96 BPM'));
    await settle(t);
    expect(find.byKey(const ValueKey('bpm-tap-pad')), findsNothing);
    expect(shownBpm(t), 96);
    await close(t);
  });

  testWidgets('finder, tap mode: a long pause starts over; fast taps clamp to 240', (t) async {
    await open(t);
    await openFinder(t);
    final pad = find.byKey(const ValueKey('bpm-tap-pad'));
    for (var i = 0; i < 4; i++) {
      await t.tap(pad);
      await t.pump(const Duration(milliseconds: 500));
    }
    expect(text(t, 'bpm-tap-value'), '120');
    await t.pump(const Duration(milliseconds: 2200));
    expect(find.text('Tap again to start over · 4 taps'), findsOneWidget);
    await t.tap(pad);
    await t.pump();
    expect(text(t, 'bpm-tap-value'), '––');
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(pad);
      await t.pump();
    }
    expect(text(t, 'bpm-tap-value'), '300');
    await t.tap(find.text('Use 240 BPM'));
    await settle(t);
    expect(shownBpm(t), 240);
    await close(t);
  });

  testWidgets('finder, listen mode: click track → BPM, ½× and 2×, listen again', (t) async {
    await open(t);
    // A running metronome is stopped so the mic doesn't hear it…
    await t.tap(find.byTooltip('Start metronome'));
    await t.pump();
    expect(find.byTooltip('Stop metronome'), findsOneWidget);
    await openFinder(t);
    expect(find.byTooltip('Start metronome'), findsOneWidget);

    await t.tap(find.text('Listen'));
    await t.pump();
    expect(find.text('Listening…'), findsOneWidget);
    await feed(t, clickTrack(128, seconds: 4, noise: 0.01));
    // Part-way: a tentative figure, nothing to use yet.
    expect(find.text('Listening…'), findsOneWidget);
    expect(text(t, 'bpm-listen-value'), '128');
    expect(find.text('Use this tempo'), findsOneWidget);
    await feed(t, clickTrack(128, seconds: 5, noise: 0.01));
    expect(find.text('Clear beat'), findsOneWidget);
    expect(find.text('Use 128 BPM'), findsOneWidget);

    await t.tap(find.text('½×'));
    await t.pump();
    expect(text(t, 'bpm-listen-value'), '64');
    expect(find.text('Use 64 BPM'), findsOneWidget);
    await t.tap(find.text('2×'));
    await t.pump();
    await t.tap(find.text('2×'));
    await t.pump();
    expect(find.text('Use 240 BPM'), findsNothing);
    expect(text(t, 'bpm-listen-value'), '128'); // 256 would be out of range
    await t.tap(find.text('½×'));
    await t.pump();

    // Listen again, to something slower.
    await t.tap(find.text('Listen again'));
    await t.pump();
    expect(find.text('Listening…'), findsOneWidget);
    await feed(t, clickTrack(90, seconds: 9));
    expect(text(t, 'bpm-listen-value'), '90');
    await t.tap(find.text('Use 90 BPM'));
    await settle(t);
    expect(shownBpm(t), 90);
    // …and it does not start again by itself.
    await t.pump(const Duration(seconds: 2));
    expect(find.byTooltip('Start metronome'), findsOneWidget);
    await close(t);
  });

  testWidgets('finder, listen mode: silence finds no beat', (t) async {
    await open(t, size: const Size(360, 640));
    await openFinder(t);
    await t.tap(find.text('Listen'));
    await t.pump();
    await feed(t, List.filled(44100 * 9, 0.0));
    expect(find.text('Couldn’t find a steady beat'), findsOneWidget);
    expect(find.text('Use this tempo'), findsOneWidget);
    expect(find.text('Listen again'), findsOneWidget);
    expect(t.takeException(), isNull);
    // Dismissing leaves the tempo alone.
    await t.tapAt(const Offset(180, 20));
    await settle(t);
    expect(shownBpm(t), 120);
    await close(t);
  });

  testWidgets('subdivisions: picked, kept on beat, remembered', (t) async {
    await open(t);
    expect(find.bySemanticsLabel('Sixteenths'), findsOneWidget);
    await t.ensureVisible(find.bySemanticsLabel('Triplets'));
    await t.tap(find.bySemanticsLabel('Triplets'));
    await t.pump();
    expect(
        t.widget<MetronomeSubdivisionPicker>(find.byType(MetronomeSubdivisionPicker)).selected,
        MetronomeSubdivision.triplets);

    // Sub-clicks don't move the beat dots: still one beat per 500 ms.
    await t.tap(find.byTooltip('Start metronome'));
    await t.pump();
    expect(find.bySemanticsLabel('Beat 1 of 4'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 340)); // two sub-clicks later
    expect(find.bySemanticsLabel('Beat 1 of 4'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 170));
    expect(find.bySemanticsLabel('Beat 2 of 4'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 1500));
    expect(find.bySemanticsLabel('Beat 1 of 4'), findsOneWidget);
    await t.tap(find.byTooltip('Stop metronome'));
    await t.pump(const Duration(seconds: 1)); // the save debounce
    expect(decodeSetup(store.values[MetronomeStore.lastKey]),
        const MetronomeSetup(subdivision: MetronomeSubdivision.triplets));
    await close(t);
  });

  testWidgets('keeps time at 240 BPM in sixteenths (16 clicks a second)', (t) async {
    await open(t, saved: {
      MetronomeStore.lastKey: encodeSetup(const MetronomeSetup(
          bpm: 240, subdivision: MetronomeSubdivision.sixteenths)),
    });
    expect(shownBpm(t), 240);
    await t.tap(find.byTooltip('Start metronome'));
    await t.pump();
    // 30 s = 120 beats = 30 bars exactly: back on beat 1, no drift.
    for (var i = 0; i < 300; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.pump(const Duration(milliseconds: 10));
    expect(find.bySemanticsLabel('Beat 1 of 4'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 250));
    expect(find.bySemanticsLabel('Beat 2 of 4'), findsOneWidget);
    await close(t);
  });

  testWidgets('saved tempos: save, load, rename, delete', (t) async {
    await open(t);
    for (var i = 0; i < 33; i++) {
      await t.tap(find.byTooltip('Slower'));
    }
    await t.pump();
    await t.ensureVisible(find.text('3/4'));
    await t.tap(find.text('3/4'));
    await t.pump();
    expect(shownBpm(t), 87);

    await t.ensureVisible(find.text('Save this tempo'));
    await t.tap(find.text('Save this tempo'));
    await settle(t);
    expect(find.text('87 BPM · 3/4'), findsOneWidget);
    await t.enterText(find.byType(TextField), '  Wonderwall ');
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(t);
    expect(find.text('Wonderwall'), findsOneWidget);
    expect(decodePresets(store.values[MetronomeStore.presetsKey]).single.name, 'Wonderwall');

    // Change everything, then load it back.
    await t.tap(find.text('4/4'));
    for (var i = 0; i < 5; i++) {
      await t.tap(find.byTooltip('Faster'));
    }
    await t.pump();
    expect(shownBpm(t), 92);
    await t.tap(find.text('Wonderwall'));
    await t.pump();
    expect(shownBpm(t), 87);
    expect(find.bySemanticsLabel('3 beats per bar'), findsOneWidget);

    // Rename.
    await t.longPress(find.text('Wonderwall'));
    await settle(t);
    await t.tap(find.text('Rename'));
    await settle(t);
    await t.enterText(find.byType(TextField), 'Wonderwall – 87');
    await t.tap(find.widgetWithText(FilledButton, 'Rename'));
    await settle(t);
    expect(find.text('Wonderwall – 87'), findsOneWidget);
    expect(decodePresets(store.values[MetronomeStore.presetsKey]).single.name, 'Wonderwall – 87');

    // Delete.
    await t.longPress(find.text('Wonderwall – 87'));
    await settle(t);
    await t.tap(find.text('Delete'));
    await settle(t);
    expect(find.text('Wonderwall – 87'), findsNothing);
    expect(decodePresets(store.values[MetronomeStore.presetsKey]), isEmpty);
    expect(find.text('Save this tempo'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // snackbar
    await close(t);
  });

  testWidgets('reopens as it was left, with saved tempos; the list is capped', (t) async {
    final full = [
      for (var i = 0; i < kMetronomeMaxPresets; i++)
        MetronomePreset(name: 'Song $i', setup: MetronomeSetup(bpm: 60 + i)),
    ];
    await open(t, saved: {
      MetronomeStore.lastKey: encodeSetup(const MetronomeSetup(
          bpm: 152, beatsPerBar: 6, subdivision: MetronomeSubdivision.eighths)),
      MetronomeStore.presetsKey: encodePresets(full),
    });
    expect(shownBpm(t), 152);
    expect(find.bySemanticsLabel('6 beats per bar'), findsOneWidget);
    expect(
        t.widget<MetronomeSubdivisionPicker>(find.byType(MetronomeSubdivisionPicker)).selected,
        MetronomeSubdivision.eighths);
    expect(find.text('Song 0'), findsOneWidget);

    await t.tap(find.text('Save'));
    await settle(t);
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('up to 20 tempos'), findsOneWidget);
    await t.pump(const Duration(seconds: 5));
    await close(t);
  });

  testWidgets('works with broken storage', (t) async {
    mic = StreamController<Uint8List>();
    await t.pumpWidget(MaterialApp(
      theme: buildSoundrTheme(Brightness.light, const Color(0xFF6C63FF)),
      home: MetronomeScreen(store: _BrokenStore(), debugSoundReady: true),
    ));
    await t.pump();
    await t.tap(find.byTooltip('Faster'));
    await t.pump(const Duration(seconds: 1));
    expect(shownBpm(t), 121);
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('garbage in storage falls back to defaults', (t) async {
    await open(t, saved: {
      MetronomeStore.lastKey: '{"bpm": "fast"',
      MetronomeStore.presetsKey: 'not json',
    });
    expect(shownBpm(t), 120);
    expect(find.text('Save this tempo'), findsOneWidget);
    await close(t);
  });
}

class _BrokenStore implements MetronomeStore {
  @override
  Future<String?> read(String key) => Future.error(StateError('no database'));

  @override
  Future<void> write(String key, String value) => throw StateError('no database');
}
