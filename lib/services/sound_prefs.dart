import 'clip_repository.dart';

/// Per-sound playback settings set from the long-press sheet: loop on/off and
/// speed (0.5×–2×). Kept in memory for instant playback, persisted in the
/// settings table as `sound_speed_<id>` / `sound_loop_<id>`.
class SoundPrefs {
  SoundPrefs._();

  static const speeds = [0.5, 1.0, 1.5, 2.0];

  static const _kSpeed = 'sound_speed_';
  static const _kLoop = 'sound_loop_';

  static final Map<String, double> _speed = {};
  static final Set<String> _loop = {};

  static double speedOf(String id) => _speed[id] ?? 1.0;
  static bool loops(String id) => _loop.contains(id);

  static Future<void> load() async {
    try {
      final speeds = await ClipRepository.getStringsWithPrefix(_kSpeed);
      speeds.forEach((id, v) {
        final speed = double.tryParse(v);
        if (speed != null && speed != 1.0) _speed[id] = speed;
      });
      final loops = await ClipRepository.getStringsWithPrefix(_kLoop);
      loops.forEach((id, v) {
        if (v == '1') _loop.add(id);
      });
    } catch (_) {/* defaults: 1×, no loop */}
  }

  static Future<void> setSpeed(String id, double speed) async {
    if (speed == 1.0) {
      _speed.remove(id);
    } else {
      _speed[id] = speed;
    }
    try {
      if (speed == 1.0) {
        await ClipRepository.deleteSetting('$_kSpeed$id');
      } else {
        await ClipRepository.setString('$_kSpeed$id', '$speed');
      }
    } catch (_) {}
  }

  static Future<void> setLoop(String id, bool loop) async {
    if (loop) {
      _loop.add(id);
    } else {
      _loop.remove(id);
    }
    try {
      if (loop) {
        await ClipRepository.setBool('$_kLoop$id', true);
      } else {
        await ClipRepository.deleteSetting('$_kLoop$id');
      }
    } catch (_) {}
  }

  /// Forget a deleted clip's settings.
  static Future<void> forget(String id) async {
    await setSpeed(id, 1.0);
    await setLoop(id, false);
  }
}
