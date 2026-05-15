import 'dart:ui';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Top-level callback — required for background notification action handling.
@pragma('vm:entry-point')
void _onNotificationResponse(NotificationResponse response) {
  if (response.payload == 'stop_all') {
    NotificationService._stopCallback?.call();
  }
}

@pragma('vm:entry-point')
void _onBackgroundNotificationResponse(NotificationResponse response) {
  // App is not in foreground; nothing to stop — just dismiss.
}

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static VoidCallback? _stopCallback;
  static bool _initialized = false;

  static const _channelId = 'soundr_playback';
  static const _notificationId = 1;

  static Future<void> init() async {
    if (_initialized) return;
    const androidSettings = AndroidInitializationSettings('@drawable/ic_notification');
    const initSettings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: _onBackgroundNotificationResponse,
    );
    _initialized = true;
  }

  static void setStopCallback(VoidCallback cb) => _stopCallback = cb;
  static void clearStopCallback() => _stopCallback = null;

  static Future<void> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  static Future<void> showPlayingNotification(String soundName) async {
    if (!_initialized) return;
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      'Soundr Playback',
      channelDescription: 'Shows when Soundr is playing a sound',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      playSound: false,
      enableVibration: false,
      icon: '@drawable/ic_notification',
      color: Color(0xFF6C63FF),
      actions: [
        AndroidNotificationAction(
          'stop_all',
          'Stop All',
          cancelNotification: true,
        ),
      ],
    );
    await _plugin.show(
      _notificationId,
      'Soundr',
      soundName,
      const NotificationDetails(android: androidDetails),
      payload: 'stop_all',
    );
  }

  static Future<void> hideNotification() async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId);
  }
}
