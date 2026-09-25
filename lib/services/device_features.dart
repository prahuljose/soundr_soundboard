import 'package:flutter/services.dart';

/// Flashlight and vibration, via the native `com.soundr.app/device` channel
/// (see android/.../DeviceFeatures.kt). Every call fails soft: on platforms
/// without the channel, or devices without the hardware, it simply no-ops.
class DeviceFeatures {
  DeviceFeatures._();

  static const _channel = MethodChannel('com.soundr.app/device');

  static Future<bool> hasTorch() => _bool('hasTorch');
  static Future<bool> hasVibrator() => _bool('hasVibrator');

  static Future<void> setTorch(bool on) async {
    try {
      await _channel.invokeMethod('setTorch', {'on': on});
    } catch (_) {}
  }

  static Future<void> vibrate(int ms) async {
    try {
      await _channel.invokeMethod('vibrate', {'ms': ms});
    } catch (_) {}
  }

  static Future<void> cancelVibrate() async {
    try {
      await _channel.invokeMethod('cancelVibrate');
    } catch (_) {}
  }

  static Future<bool> _bool(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}
