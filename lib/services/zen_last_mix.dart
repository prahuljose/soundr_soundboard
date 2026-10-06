import 'dart:convert';

import 'clip_repository.dart';

/// One sound in the last Zen mix.
class ZenMixTrack {
  final String id;
  final String name;
  final String emoji;

  /// Volume 1–100.
  final double volume;

  const ZenMixTrack({
    required this.id,
    required this.name,
    required this.emoji,
    required this.volume,
  });

  factory ZenMixTrack.fromJson(Map<String, dynamic> j) => ZenMixTrack(
        id: j['id'] as String,
        name: j['name'] as String,
        emoji: j['emoji'] as String? ?? '',
        volume: (j['volume'] as num?)?.toDouble() ?? 50,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'emoji': emoji, 'volume': volume};
}

/// The mix that was playing when Zen Mode was last used, so the Tools tab can
/// offer to resume it. Stored in the settings table as `zen_last_mix`.
class ZenLastMix {
  /// The saved mix's name when the sounds came from one, else null.
  final String? presetName;
  final List<ZenMixTrack> tracks;

  const ZenLastMix({this.presetName, required this.tracks});

  static const _key = 'zen_last_mix';

  static Future<ZenLastMix?> load() async {
    try {
      final raw = await ClipRepository.getString(_key);
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final tracks = [
        for (final t in (j['tracks'] as List? ?? const []))
          ZenMixTrack.fromJson(Map<String, dynamic>.from(t as Map)),
      ];
      if (tracks.isEmpty) return null;
      return ZenLastMix(presetName: j['preset'] as String?, tracks: tracks);
    } catch (_) {
      return null;
    }
  }

  /// Saves [mix]; an empty mix keeps the previous one so stopping everything
  /// doesn't forget what to resume.
  static Future<void> save(ZenLastMix mix) async {
    if (mix.tracks.isEmpty) return;
    try {
      await ClipRepository.setString(
        _key,
        jsonEncode({
          'preset': mix.presetName,
          'tracks': [for (final t in mix.tracks) t.toJson()],
        }),
      );
    } catch (_) {}
  }
}
