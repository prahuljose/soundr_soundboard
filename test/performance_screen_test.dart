import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/models/sound_model.dart';
import 'package:soundr_soundboard/screens/performance_screen.dart';
import 'package:soundr_soundboard/theme/app_colors.dart';
import 'package:soundr_soundboard/widgets/performance_widgets.dart';

class FakePlayer extends PerformancePlayer {
  final calls = <String>[];
  int disposed = 0;

  @override
  Future<Duration?> play(SoundModel sound) async {
    calls.add('play:${sound.id}');
    return const Duration(milliseconds: 1000);
  }

  @override
  void stop(String id) => calls.add('stop:$id');

  @override
  void stopAll() => calls.add('stopAll');

  @override
  void dispose() => disposed++;
}

SoundModel _s(int i, [String cat = 'Memes']) =>
    SoundModel(id: 'p$i', name: 'Pad $i', file: '', category: cat, emoji: '🔥');

final _favs = PerformanceSet(
  id: 'fav',
  name: 'Favourites',
  emoji: '⭐',
  sounds: [
    const SoundModel(
        id: 'bonk', name: 'Bonk', file: '', category: 'Memes', emoji: '🔨'),
    for (var i = 2; i <= 12; i++) _s(i, 'Reactions'),
  ],
);

final _big = PerformanceSet(
  id: 'big',
  name: 'Big board',
  emoji: '🎛',
  sounds: [for (var i = 100; i < 128; i++) _s(i)], // 28 → 3 pages
);

final _small = PerformanceSet(
  id: 'small',
  name: 'Tiny set',
  emoji: '🐣',
  sounds: [for (var i = 200; i < 203; i++) _s(i, 'Animals')],
);

void main() {
  late FakePlayer player;

  Future<void> open(
    WidgetTester t, {
    Size size = const Size(390, 844),
    String? initial,
    bool pushed = false,
  }) async {
    player = FakePlayer();
    t.view.physicalSize = size * 2;
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final screen = PerformanceScreen(
      sets: [_favs, _big, _small],
      initialSetId: initial,
      debugPlayer: player,
    );
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        fontFamily: 'Outfit',
        extensions: const [AppColors.dark],
      ),
      home: pushed
          ? Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => screen)),
                    child: const Text('Home'),
                  ),
                ),
              ),
            )
          : screen,
    ));
    if (pushed) {
      await t.tap(find.text('Home'));
      await t.pumpAndSettle();
    }
    await t.pump();
  }

  Future<void> close(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  }

  Future<void> tapPad(WidgetTester t, String name) async {
    await t.tap(find.text(name));
    await t.pump(); // let the (fake) play future resolve
  }

  Set<double> xs() => find
      .byType(PerformancePad)
      .evaluate()
      .map((e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dx)
      .toSet();
  Set<double> ys() => find
      .byType(PerformancePad)
      .evaluate()
      .map((e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy)
      .toSet();

  testWidgets('portrait shows 12 pads in 3×4 filling the space', (t) async {
    await open(t);
    expect(find.byType(PerformancePad), findsNWidgets(12));
    expect(xs(), hasLength(3));
    expect(ys(), hasLength(4));
    final pad = t.getSize(find.byType(PerformancePad).first);
    expect(pad.height, greaterThan(120)); // stretched, not fixed tiles
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('landscape switches to 6×2', (t) async {
    await open(t, size: const Size(844, 390));
    expect(find.byType(PerformancePad), findsNWidgets(12));
    expect(xs(), hasLength(6));
    expect(ys(), hasLength(2));
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('small portrait 360×640 lays out without overflow', (t) async {
    await open(t, size: const Size(360, 640), initial: 'big');
    expect(find.byType(PerformancePad), findsNWidgets(12));
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('tap plays; tapping again restarts', (t) async {
    await open(t);
    await tapPad(t, 'Bonk');
    expect(player.calls, ['play:bonk']);
    final pad = t.widget<PerformancePad>(find.byKey(const ValueKey('pad-bonk')));
    expect(pad.progress, isNotNull);

    await t.pump(const Duration(milliseconds: 400));
    await tapPad(t, 'Bonk');
    expect(player.calls, ['play:bonk', 'stop:bonk', 'play:bonk']);

    // Progress restarted from 0, and the pad goes idle when the sound ends.
    final again =
        t.widget<PerformancePad>(find.byKey(const ValueKey('pad-bonk')));
    expect(again.progress!.value, lessThan(0.1));
    await t.pump(const Duration(milliseconds: 1100));
    expect(
        t.widget<PerformancePad>(find.byKey(const ValueKey('pad-bonk'))).progress,
        isNull);
    await close(t);
  });

  testWidgets('Layer mode layers; Cut mode stops the others first', (t) async {
    await open(t);
    await tapPad(t, 'Bonk');
    await tapPad(t, 'Pad 2');
    expect(player.calls, ['play:bonk', 'play:p2']);
    expect(
        find.byWidgetPredicate(
            (w) => w is PerformancePad && w.progress != null),
        findsNWidgets(2));

    await t.tap(find.text('Cut'));
    await t.pump();
    player.calls.clear();
    await tapPad(t, 'Pad 3');
    expect(player.calls, ['stopAll', 'play:p3']);
    expect(
        find.byWidgetPredicate(
            (w) => w is PerformancePad && w.progress != null),
        findsOneWidget);
    await close(t);
  });

  testWidgets('Stop all stops everything', (t) async {
    await open(t);
    await tapPad(t, 'Bonk');
    await tapPad(t, 'Pad 2');
    await t.tap(find.text('Stop all'));
    await t.pump();
    expect(player.calls.last, 'stopAll');
    expect(
        find.byWidgetPredicate(
            (w) => w is PerformancePad && w.progress != null),
        findsNothing);
    await close(t);
  });

  testWidgets('lock disables set picker and mode switch; pads still play',
      (t) async {
    await open(t);
    await t.tap(find.byIcon(Icons.lock_open_rounded));
    await t.pump();
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);

    await t.tap(find.text('Favourites'));
    await t.pumpAndSettle();
    expect(find.text('Choose a set'), findsNothing);

    await t.tap(find.text('Cut'));
    await t.pump();
    await tapPad(t, 'Bonk');
    await tapPad(t, 'Pad 2');
    expect(player.calls, ['play:bonk', 'play:p2']); // still Layer

    await t.tap(find.text('Stop all'));
    await t.pump();
    expect(player.calls.last, 'stopAll');

    // Unlock: the picker works again.
    await t.tap(find.byIcon(Icons.lock_rounded));
    await t.pump();
    await t.tap(find.text('Favourites'));
    await t.pumpAndSettle();
    expect(find.text('Choose a set'), findsOneWidget);
    await close(t);
  });

  testWidgets('set picker switches sets', (t) async {
    await open(t);
    await t.tap(find.text('Favourites'));
    await t.pumpAndSettle();
    expect(find.text('3 sounds'), findsOneWidget);
    expect(find.text('28 sounds'), findsOneWidget);
    await t.tap(find.text('Tiny set'));
    await t.pumpAndSettle();
    expect(find.text('Choose a set'), findsNothing);
    expect(find.byType(PerformancePad), findsNWidgets(3));
    expect(find.text('Pad 200'), findsOneWidget);
    expect(find.text('Bonk'), findsNothing);
    await close(t);
  });

  testWidgets('more than 12 sounds pages with a swipe', (t) async {
    final handle = t.ensureSemantics();
    await open(t, initial: 'big');
    expect(find.bySemanticsLabel('Page 1 of 3'), findsOneWidget);
    expect(find.text('Pad 100'), findsOneWidget);
    expect(find.text('Pad 112'), findsNothing);

    await t.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Page 2 of 3'), findsOneWidget);
    expect(find.text('Pad 112'), findsOneWidget);

    await tapPad(t, 'Pad 112');
    expect(player.calls, ['play:p112']);
    handle.dispose();
    await close(t);
  });

  testWidgets('landscape pages too, dots in the rail', (t) async {
    final handle = t.ensureSemantics();
    await open(t, size: const Size(844, 390), initial: 'big');
    expect(find.bySemanticsLabel('Page 1 of 3'), findsOneWidget);
    await t.fling(find.byType(PageView), const Offset(-500, 0), 1000);
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Page 2 of 3'), findsOneWidget);
    handle.dispose();
    await close(t);
  });

  testWidgets('tap on X shows the hint; long-press exits', (t) async {
    await open(t, pushed: true);
    double hintOpacity() => t
        .widget<AnimatedOpacity>(find.ancestor(
            of: find.text('Hold to exit'),
            matching: find.byType(AnimatedOpacity)))
        .opacity;

    expect(hintOpacity(), 0);
    await t.tap(find.byIcon(Icons.close_rounded));
    await t.pump(const Duration(milliseconds: 200));
    expect(hintOpacity(), 1);
    expect(find.byType(PerformanceScreen), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(hintOpacity(), 0);

    // System back is swallowed too (shows the hint).
    await t.binding.handlePopRoute();
    await t.pump();
    expect(find.byType(PerformanceScreen), findsOneWidget);
    expect(hintOpacity(), 1);

    final g = await t.startGesture(t.getCenter(find.byIcon(Icons.close_rounded)));
    await t.pump(); // the hold ring's ticker starts on this frame
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(PerformanceScreen), findsOneWidget); // not yet
    await t.pump(const Duration(milliseconds: 400));
    await g.up();
    await t.pumpAndSettle();
    expect(find.byType(PerformanceScreen), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(player.disposed, 1);
    expect(t.takeException(), isNull);
    await close(t);
  });

  testWidgets('disposing restores system UI without errors', (t) async {
    await open(t);
    await tapPad(t, 'Bonk');
    await t.pumpWidget(const SizedBox());
    expect(player.disposed, 1);
    expect(t.takeException(), isNull);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('semantics labels', (t) async {
    final handle = t.ensureSemantics();
    await open(t);
    expect(find.bySemanticsLabel('Bonk, Memes'), findsOneWidget);
    expect(find.bySemanticsLabel('Hold to exit performance mode'), findsOneWidget);
    expect(find.bySemanticsLabel('Stop all sounds'), findsOneWidget);
    expect(find.bySemanticsLabel('Lock the board'), findsOneWidget);
    expect(find.bySemanticsLabel('Sound set: Favourites'), findsOneWidget);
    expect(find.bySemanticsLabel('When a new sound starts'), findsOneWidget);

    expect(t.getSemantics(find.bySemanticsLabel('Bonk, Memes')),
        isSemantics(isButton: true, hasTapAction: true));

    await tapPad(t, 'Bonk');
    expect(find.bySemanticsLabel('Bonk, Memes, playing'), findsOneWidget);

    expect(t.getSemantics(find.bySemanticsLabel('Lock the board')),
        isSemantics(hasToggledState: true, isToggled: false));
    await t.tap(find.byIcon(Icons.lock_open_rounded));
    await t.pump();
    expect(t.getSemantics(find.bySemanticsLabel('Lock the board')),
        isSemantics(hasToggledState: true, isToggled: true));
    expect(t.getSemantics(find.bySemanticsLabel('Sound set: Favourites')),
        isSemantics(hasEnabledState: true, isEnabled: false));
    handle.dispose();
    await close(t);
  });
}
