import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/main.dart';
import 'package:soundr_soundboard/models/sound_model.dart';
import 'package:soundr_soundboard/screens/pair_match_screen.dart';
import 'package:soundr_soundboard/widgets/sound_button.dart';

ThemeData get _theme =>
    buildSoundrTheme(Brightness.dark, const Color(0xFF6C63FF));

const _bonk = SoundModel(
  id: 's1',
  name: 'Bonk',
  file: 'bonk.mp3',
  category: 'Memes',
  emoji: '🔨',
);

Widget _button({
  bool favorited = false,
  double speed = 1.0,
  bool loopEnabled = false,
  bool looping = false,
  int playCount = 0,
  VoidCallback? onLongPress,
  VoidCallback? onTap,
  VoidCallback? onFavorite,
}) =>
    MaterialApp(
      theme: _theme,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 220,
            height: 120,
            // Same shape as the grid: the parent owns the long-press.
            child: GestureDetector(
              onLongPress: onLongPress ?? () {},
              child: SoundButton(
                sound: _bonk,
                onTap: onTap ?? () {},
                duration: 2,
                stopSignal: 0,
                isFavorited: favorited,
                onFavoriteToggle: onFavorite ?? () {},
                speed: speed,
                loopEnabled: loopEnabled,
                looping: looping,
                playCount: playCount,
                longPressHint: 'show options',
              ),
            ),
          ),
        ),
      ),
    );

final _tile = find.bySemanticsLabel(RegExp(r'^Bonk, '));

void main() {
  group('SoundButton', () {
    testWidgets('announces name, category and length as one button',
        (t) async {
      final handle = t.ensureSemantics();
      await t.pumpWidget(_button());

      expect(_tile, findsOneWidget);
      expect(
        t.getSemantics(_tile),
        isSemantics(
          label: 'Bonk, Memes, 2.0 seconds',
          isButton: true,
          hasTapAction: true,
          hasLongPressAction: true,
          onTapHint: 'play',
          onLongPressHint: 'show options',
        ),
      );
      // The emoji and visible name are not read out a second time.
      expect(find.bySemanticsLabel('🔨'), findsNothing);
      expect(find.bySemanticsLabel('Bonk'), findsNothing);
      handle.dispose();
    });

    testWidgets('label carries speed, loop, favourite and play count',
        (t) async {
      final handle = t.ensureSemantics();
      await t.pumpWidget(_button(
          favorited: true, speed: 1.5, loopEnabled: true, playCount: 3));

      expect(
        t.getSemantics(_tile).label,
        'Bonk, Memes, 1.3 seconds, 1.5 times speed, loop on, favorited, '
        'played 3 times',
      );

      await t.pumpWidget(_button(speed: 2, loopEnabled: true, looping: true));
      final node = t.getSemantics(_tile);
      expect(node.label, 'Bonk, Memes, 1.0 seconds, 2 times speed, looping');
      expect(
        node,
        isSemantics(
            onTapHint: 'stop the loop', onLongPressHint: 'show options'),
      );
      handle.dispose();
    });

    testWidgets('says "playing" while it plays, and stops saying it after',
        (t) async {
      final handle = t.ensureSemantics();
      var plays = 0;
      await t.pumpWidget(_button(onTap: () => plays++));

      t.semantics.tap(find.semantics.byLabel(RegExp(r'^Bonk, ')));
      await t.pump(const Duration(milliseconds: 100));
      expect(plays, 1);
      expect(t.getSemantics(_tile).label, 'Bonk, Memes, 2.0 seconds, playing');

      await t.pump(const Duration(seconds: 3));
      expect(t.getSemantics(_tile).label, 'Bonk, Memes, 2.0 seconds');
      handle.dispose();
    });

    testWidgets('long-press action reaches the parent handler', (t) async {
      final handle = t.ensureSemantics();
      var longPresses = 0;
      await t.pumpWidget(_button(onLongPress: () => longPresses++));

      t.semantics.longPress(find.semantics.byLabel(RegExp(r'^Bonk, ')));
      await t.pump();
      expect(longPresses, 1);
      handle.dispose();
    });

    testWidgets('favourite star is its own toggle button', (t) async {
      final handle = t.ensureSemantics();
      var toggles = 0;
      await t.pumpWidget(_button(onFavorite: () => toggles++));

      final star = find.bySemanticsLabel('Add Bonk to favorites');
      expect(
        t.getSemantics(star),
        isSemantics(
            isButton: true,
            hasToggledState: true,
            isToggled: false,
            hasTapAction: true),
      );
      await t.tap(star);
      expect(toggles, 1);

      await t.pumpWidget(_button(favorited: true));
      expect(
        t.getSemantics(find.bySemanticsLabel('Remove Bonk from favorites')),
        isSemantics(isToggled: true),
      );
      handle.dispose();
    });
  });

  group('Pair Match', () {
    const names = ['Bonk', 'Airhorn', 'Vine Boom', 'Quack', 'Tada', 'Oof'];
    final sounds = [
      for (var i = 0; i < names.length; i++)
        SoundModel(
          id: 'p$i',
          name: names[i],
          file: 'p$i.mp3',
          category: 'Memes',
          emoji: '🎵',
        ),
    ];
    // Audio can't play in tests; the screen only needs a non-null source.
    // ignore: invalid_use_of_internal_member
    final preloaded = {for (final s in sounds) s.id: AudioSource(SoundHash.random())};

    Future<void> start(WidgetTester t) async {
      await t.pumpWidget(MaterialApp(
        theme: _theme,
        home: PairMatchScreen(sounds: sounds, preloaded: preloaded),
      ));
      await t.pump(const Duration(milliseconds: 100));
    }

    Finder card(int n, String rest) =>
        find.bySemanticsLabel(RegExp('^Card $n, $rest\$'));

    testWidgets('difficulty choices read as labelled buttons', (t) async {
      final handle = t.ensureSemantics();
      await start(t);

      for (final label in [
        'Easy, 4 pairs, 4 columns',
        'Medium, 6 pairs, 4 columns',
        'Hard, 10 pairs, 5 columns',
      ]) {
        expect(
          t.getSemantics(find.bySemanticsLabel(label)),
          isSemantics(isButton: true, hasTapAction: true),
        );
      }
      handle.dispose();
    });

    testWidgets('cards are numbered buttons whose label follows their state',
        (t) async {
      final handle = t.ensureSemantics();
      await start(t);
      await t.tap(find.bySemanticsLabel('Easy, 4 pairs, 4 columns'));
      await t.pump(const Duration(milliseconds: 300));

      // Eight cards, all face down, all tappable buttons.
      for (var n = 1; n <= 8; n++) {
        expect(
          t.getSemantics(card(n, 'face down')),
          isSemantics(
              isButton: true,
              hasTapAction: true,
              hasEnabledState: true,
              isEnabled: true),
          reason: 'card $n',
        );
      }
      expect(find.bySemanticsLabel('0 moves'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Time 0 seconds, 0 of 4 pairs found'),
        findsOneWidget,
      );

      // Flip the first card through the screen reader's tap action.
      t.semantics.tap(find.semantics.byLabel('Card 1, face down'));
      await t.pump(const Duration(milliseconds: 300));
      expect(card(1, 'face down'), findsNothing);
      final faceUp = card(1, '.+, face up');
      expect(faceUp, findsOneWidget);
      final name = RegExp('^Card 1, (.+), face up\$')
          .firstMatch(t.getSemantics(faceUp).label)!
          .group(1)!;
      expect(names, contains(name));
      // Face up, it can't be flipped again.
      expect(t.getSemantics(faceUp), isNot(isSemantics(hasTapAction: true)));

      // Hunt for its twin; wrong guesses turn both cards back over.
      var moves = 0;
      for (var n = 2; n <= 8; n++) {
        if (card(1, 'face down').evaluate().isNotEmpty) {
          await t.tap(card(1, 'face down'));
          await t.pump(const Duration(milliseconds: 50));
        }
        await t.tap(card(n, 'face down'));
        await t.pump(const Duration(milliseconds: 50));
        moves++;
        if (card(1, '$name, matched').evaluate().isNotEmpty) {
          expect(card(n, '$name, matched'), findsOneWidget);
          break;
        }
        // Mismatch: the second card names itself while it is showing…
        expect(card(n, '.+, face up'), findsOneWidget);
        await t.pump(const Duration(milliseconds: 1300));
        // …and both go back to face down.
        expect(card(n, 'face down'), findsOneWidget);
        expect(card(1, 'face down'), findsOneWidget);
      }

      expect(
        t.getSemantics(card(1, '$name, matched')),
        isSemantics(
            isButton: true, hasEnabledState: true, isEnabled: false),
      );
      expect(
        find.bySemanticsLabel('$moves ${moves == 1 ? 'move' : 'moves'}'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'1 of 4 pairs found$')),
          findsOneWidget);
      handle.dispose();
    });
  });
}
