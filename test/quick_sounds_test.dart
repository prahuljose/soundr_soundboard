import 'package:flutter_test/flutter_test.dart';
import 'package:soundr_soundboard/data/sounds_data.dart';
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
}
