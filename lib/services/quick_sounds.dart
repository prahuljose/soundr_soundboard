import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../data/sounds_data.dart';
import '../models/sound_model.dart';
import 'clip_repository.dart';

/// How the widget's sounds are chosen (Settings → Choose widget sounds).
enum WidgetSoundsMode {
  /// Favourites first, then most played, then starters.
  automatic,

  /// Exactly the sounds the user picked, in their order.
  custom,
}

/// Feeds the native home-screen widget (android/.../QuickSounds*.kt) over the
/// `com.soundr.app/quick` channel.
class QuickSounds {
  QuickSounds._();

  static const _channel = MethodChannel('com.soundr.app/quick');
  static const maxSounds = 8;

  // ── The user's choice, persisted in the settings table ───────────────────

  static const _kMode = 'widget_sounds_mode';
  static const _kIds = 'widget_sounds_ids';
  static WidgetSoundsMode _mode = WidgetSoundsMode.automatic;
  static List<String> _customIds = const [];
  static bool _choiceLoaded = false;

  static Future<({WidgetSoundsMode mode, List<String> ids})> loadChoice() async {
    if (!_choiceLoaded) {
      try {
        final mode = await ClipRepository.getString(_kMode);
        final ids = await ClipRepository.getString(_kIds);
        _mode = mode == WidgetSoundsMode.custom.name
            ? WidgetSoundsMode.custom
            : WidgetSoundsMode.automatic;
        _customIds = ids == null ? const [] : List<String>.from(jsonDecode(ids));
      } catch (_) {/* keep automatic */}
      _choiceLoaded = true;
    }
    return (mode: _mode, ids: List<String>.unmodifiable(_customIds));
  }

  static Future<void> saveChoice(WidgetSoundsMode mode, List<String> ids) async {
    _mode = mode;
    _customIds = ids.take(maxSounds).toList();
    _choiceLoaded = true;
    try {
      await ClipRepository.setString(_kMode, mode.name);
      await ClipRepository.setString(_kIds, jsonEncode(_customIds));
    } catch (_) {}
  }

  /// Crowd-pleasers that fill the widget until the user has favourites or a
  /// play history, so it's useful from the first minute.
  static const _starterIds = ['s20', 's30', 's25', 's40', 's50', 's31', 's12', 's22'];

  /// In [WidgetSoundsMode.custom], the chosen [customIds] in order (skipping
  /// any that no longer exist, e.g. a deleted clip). Otherwise — or if none of
  /// the custom picks are left — favourites (most played first), then other
  /// played sounds, then starters.
  static List<SoundModel> pick({
    required List<SoundModel> all,
    required Set<String> favorites,
    required Map<String, int> playCounts,
    WidgetSoundsMode mode = WidgetSoundsMode.automatic,
    List<String> customIds = const [],
  }) {
    final byId = {for (final s in all) s.id: s};
    if (mode == WidgetSoundsMode.custom) {
      final chosen = customIds
          .map((id) => byId[id])
          .whereType<SoundModel>()
          .take(maxSounds)
          .toList();
      if (chosen.isNotEmpty) return chosen;
    }

    int plays(SoundModel s) => playCounts[s.id] ?? 0;
    int byPlays(SoundModel a, SoundModel b) => plays(b).compareTo(plays(a));

    final favs = all.where((s) => favorites.contains(s.id)).toList()..sort(byPlays);
    final played = all
        .where((s) => !favorites.contains(s.id) && plays(s) > 0)
        .toList()
      ..sort(byPlays);
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
    final choice = await loadChoice();
    final sounds = pick(
      all: all,
      favorites: favorites,
      playCounts: playCounts,
      mode: choice.mode,
      customIds: choice.ids,
    );
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

  /// Same as [sync], reading sounds, favourites and play counts from the
  /// database — for screens that don't hold the soundboard's state.
  static Future<void> syncFromDatabase() async {
    try {
      await sync(
        all: [...SoundsData.all, ...await ClipRepository.getAll()],
        favorites: await ClipRepository.getFavorites(),
        playCounts: await ClipRepository.getPlayCounts(),
      );
    } catch (_) {}
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
