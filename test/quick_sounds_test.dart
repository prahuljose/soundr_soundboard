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

  test('never more than the widget can show', () {
    final favorites = {for (final s in all.take(20)) s.id};
    final picked = QuickSounds.pick(all: all, favorites: favorites, playCounts: {});
    expect(picked, hasLength(QuickSounds.maxSounds));
    expect(picked.every((s) => favorites.contains(s.id)), isTrue);
  });
}
