import 'dart:ui';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Top-level callback — required for background notification action handling.
@pragma('vm:entry-point')
void _onNotificationResponse(NotificationResponse response) {
  final actionId = response.actionId;
  if (actionId == null || actionId == 'stop_all') {
    // Body tap (payload) or Stop-All button — stop everything.
    NotificationService._stopCallback?.call();
  } else if (actionId.startsWith('play_')) {
    // Quick-play button — fire the registered play callback with the sound ID.
    NotificationService._playCallback?.call(actionId.substring(5));
  }
}

@pragma('vm:entry-point')
void _onBackgroundNotificationResponse(NotificationResponse response) {
  // App is not in foreground; nothing to play/stop — just dismiss.
}

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static VoidCallback? _stopCallback;
  static void Function(String soundId)? _playCallback;
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

  static void setPlayCallback(void Function(String soundId) cb) => _playCallback = cb;
  static void clearPlayCallback() => _playCallback = null;

  static Future<void> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  /// Shows a persistent playback notification.
  ///
  /// [quickPlays] is an optional list of up to 2 favourite sounds shown as
  /// action buttons so the user can trigger them from the notification shade.
  /// Each entry is a record with the sound's `id` and display `name`.
  static Future<void> showPlayingNotification(
    String soundName, {
    List<({String id, String name})> quickPlays = const [],
  }) async {
    if (!_initialized) return;

    final quickPlayActions = quickPlays.take(2).map(
      (s) => AndroidNotificationAction(
        'play_${s.id}',
        s.name,
        showsUserInterface: true,
      ),
    ).toList();

    final androidDetails = AndroidNotificationDetails(
      _channelId,
      'Soundr Playback',
      channelDescription: 'Shows when Soundr is playing a sound',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      playSound: false,
      enableVibration: false,
      icon: '@drawable/ic_notification',
      color: const Color(0xFF6C63FF),
      actions: [
        ...quickPlayActions,
        const AndroidNotificationAction(
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
      NotificationDetails(android: androidDetails),
      payload: 'stop_all',
    );
  }

  static Future<void> hideNotification() async {
    if (!_initialized) return;
    await _plugin.cancel(_notificationId);
  }
}
