import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../models/sound_model.dart';

/// Feeds the native home-screen widget (android/.../QuickSounds*.kt) over the
/// `com.soundr.app/quick` channel.
class QuickSounds {
  QuickSounds._();

  static const _channel = MethodChannel('com.soundr.app/quick');
  static const maxSounds = 8;

  /// Crowd-pleasers that fill the widget until the user has favourites or a
  /// play history, so it's useful from the first minute.
  static const _starterIds = ['s20', 's30', 's25', 's40', 's50', 's31', 's12', 's22'];

  /// Favourites (most played first), then other played sounds, then starters.
  static List<SoundModel> pick({
    required List<SoundModel> all,
    required Set<String> favorites,
    required Map<String, int> playCounts,
  }) {
    int plays(SoundModel s) => playCounts[s.id] ?? 0;
    int byPlays(SoundModel a, SoundModel b) => plays(b).compareTo(plays(a));

    final favs = all.where((s) => favorites.contains(s.id)).toList()..sort(byPlays);
    final played = all
        .where((s) => !favorites.contains(s.id) && plays(s) > 0)
        .toList()
      ..sort(byPlays);
    final byId = {for (final s in all) s.id: s};
    final starters = _starterIds.map((id) => byId[id]).whereType<SoundModel>();

    final picked = <SoundModel>[];
    final seen = <String>{};
    for (final s in [...favs, ...played, ...starters]) {
      if (seen.add(s.id)) picked.add(s);
      if (picked.length == maxSounds) break;
    }
    return picked;
  }

  static Future<void> sync({
    required List<SoundModel> all,
    required Set<String> favorites,
    required Map<String, int> playCounts,
  }) async {
    if (!Platform.isAndroid) return;
    final sounds = pick(all: all, favorites: favorites, playCounts: playCounts);
    final json = jsonEncode([
      for (final s in sounds)
        {
          'id': s.id,
          'name': s.name,
          'emoji': s.emoji,
          'asset': s.isUserClip ? '' : 'assets/sounds/raw/${s.file}',
          'path': s.isUserClip ? (s.filePath ?? '') : '',
          'startMs': _trimmed(s) ? (s.trimStart * 1000).round() : 0,
          'endMs': _trimmed(s) ? (s.trimEnd * 1000).round() : 0,
        },
    ]);
    try {
      await _channel.invokeMethod('syncQuickSounds', {'json': json});
    } catch (_) {/* the widget is a bonus — never break the app */}
  }

  static bool _trimmed(SoundModel s) => s.isUserClip && s.trimEnd > s.trimStart;

  /// Android 8+: whether the launcher supports "add widget" prompts.
  static Future<bool> canPinWidget() => _bool('canPinWidget');

  /// Shows the system "add widget to home screen" prompt.
  static Future<bool> pinWidget() => _bool('pinWidget');

  static Future<bool> _bool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}
