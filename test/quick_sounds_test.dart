import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/data/sounds_data.dart';
import 'package:soundr_soundboard/models/sound_model.dart';
import 'package:soundr_soundboard/services/quick_sounds.dart';

void main() {
  final all = SoundsData.all;

  test('starters fill the widget when there are no favourites or plays', () {
    final picked = QuickSounds.pick(all: all, favorites: {}, playCounts: {});
    expect(picked, hasLength(QuickSounds.maxSounds));
    expect(picked.first.id, 's20');
  });

  test('favourites come first, most played first, then played, then starters', () {
    final picked = QuickSounds.pick(
      all: all,
      favorites: {'s1', 's2'},
      playCounts: {'s2': 9, 's1': 3, 's3': 5},
    );
    expect(picked.take(3).map((s) => s.id), ['s2', 's1', 's3']);
    expect(picked, hasLength(QuickSounds.maxSounds));
    expect(picked.map((s) => s.id).toSet(), hasLength(picked.length),
        reason: 'no duplicates');
  });

  test('custom mode keeps the chosen sounds in the chosen order', () {
    final picked = QuickSounds.pick(
      all: all,
      favorites: {'s1'},
      playCounts: {'s1': 99},
      mode: WidgetSoundsMode.custom,
      customIds: ['s30', 's12', 's1'],
    );
    expect(picked.map((s) => s.id), ['s30', 's12', 's1']);
  });

  test('custom mode skips missing sounds and falls back when none are left', () {
    final some = QuickSounds.pick(
      all: all,
      favorites: {},
      playCounts: {},
      mode: WidgetSoundsMode.custom,
      customIds: ['deleted_clip', 's25'],
    );
    expect(some.map((s) => s.id), ['s25']);

    final none = QuickSounds.pick(
      all: all,
      favorites: {},
      playCounts: {},
      mode: WidgetSoundsMode.custom,
      customIds: ['deleted_clip'],
    );
    expect(none, hasLength(QuickSounds.maxSounds), reason: 'automatic fallback');
  });

  test('never more than the widget can show', () {
    final favorites = {for (final s in all.take(20)) s.id};
    final picked = QuickSounds.pick(all: all, favorites: favorites, playCounts: {});
    expect(picked, hasLength(QuickSounds.maxSounds));
    expect(picked.every((s) => favorites.contains(s.id)), isTrue);
  });

  group('widget payload', () {
    SoundModel byId(String id) => all.firstWhere((s) => s.id == id);

    test('built-in sounds carry their asset and category colour', () {
      final p = QuickSounds.payload(byId('s20')); // Yeah Boy, Memes
      expect(p['id'], 's20');
      expect(p['name'], 'Yeah Boy');
      expect(p['asset'], 'assets/sounds/raw/yeah_boy.wav');
      expect(p['path'], '');
      expect(p['startMs'], 0);
      expect(p['endMs'], 0);
      expect(p['color'], 0xFFFF7272);
      expect(QuickSounds.payload(byId('s50'))['color'], 0xFF64C8FF); // Reactions
    });

    test('a clip uses its own colour and trim points', () {
      const clip = SoundModel(
        id: 'clip_1',
        name: 'Mine',
        file: '',
        category: 'My Clips',
        emoji: '🎙️',
        isUserClip: true,
        filePath: '/data/clip.m4a',
        trimStart: 0.5,
        trimEnd: 1.25,
        customColor: 0xFF7FE0C2,
      );
      final p = QuickSounds.payload(clip);
      expect(p['asset'], '');
      expect(p['path'], '/data/clip.m4a');
      expect(p['startMs'], 500);
      expect(p['endMs'], 1250);
      expect(p['color'], 0xFF7FE0C2);
    });

    test('no colour key when the widget should use its accent', () {
      const clip = SoundModel(
        id: 'clip_2',
        name: 'Plain',
        file: '',
        category: 'My Clips',
        emoji: '🎙️',
        isUserClip: true,
        filePath: '/data/plain.m4a',
      );
      expect(QuickSounds.payload(clip).containsKey('color'), isFalse);
    });
  });
}
