import 'package:flutter/services.dart';

import 'clip_repository.dart';

/// Global gate for in-app haptic feedback.
///
/// Every haptic in the app routes through here so the user can turn vibration
/// off from the drawer. The preference is persisted in the settings table and
/// loaded once at startup via [init]; until then it defaults to on.
class Haptics {
  Haptics._();

  static bool _enabled = true;
  static bool get enabled => _enabled;

  static const _prefKey = 'haptics_enabled';

  /// Load the persisted preference. Safe to call before the DB is ready —
  /// any failure leaves haptics enabled (the sensible default).
  static Future<void> init() async {
    try {
      _enabled = await ClipRepository.getBool(_prefKey, defaultValue: true);
    } catch (_) {
      _enabled = true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      await ClipRepository.setBool(_prefKey, value);
    } catch (_) {/* best-effort — in-memory value still applies this session */}
  }

  static void light()     { if (_enabled) HapticFeedback.lightImpact(); }
  static void medium()    { if (_enabled) HapticFeedback.mediumImpact(); }
  static void heavy()     { if (_enabled) HapticFeedback.heavyImpact(); }
  static void selection() { if (_enabled) HapticFeedback.selectionClick(); }
}
