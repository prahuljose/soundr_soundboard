import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/app_colors.dart';

// ── Zen notification globals ─────────────────────────────────────────────────
final _zenNotifPlugin = FlutterLocalNotificationsPlugin();
const _kZenNotifId   = 888;
const _kZenChannelId = 'zen_ambient';

/// Background handler — app is fully killed so sounds are already silent;
/// we only need to satisfy the flutter_local_notifications API.
@pragma('vm:entry-point')
void _onBgZenNotif(NotificationResponse _) {}

class _ZenTrack {
  final String id;
  final String name;
  final String emoji;
  final String description;
  final String file; // relative to assets/sounds/zen/

  const _ZenTrack({
    required this.id,
    required this.name,
    required this.emoji,
    required this.description,
    required this.file,
  });
}

class _ZenPreset {
  final String id;        // uuid-lite: timestamp hex
  final String name;
  final Map<String, double> volumes; // trackId → volume 1-100

  _ZenPreset({required this.id, required this.name, required this.volumes});

  factory _ZenPreset.fromJson(Map<String, dynamic> j) => _ZenPreset(
        id: j['id'] as String,
        name: j['name'] as String,
        volumes: Map<String, double>.from(
          (j['volumes'] as Map).map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        ),
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'volumes': volumes};
}

class _ZenStats {
  int totalSeconds;
  int weeklySeconds;
  String weekStartIso;
  int sessionsCount;
  int currentStreak;
  String lastUsedIso;

  _ZenStats({
    this.totalSeconds = 0,
    this.weeklySeconds = 0,
    this.weekStartIso = '',
    this.sessionsCount = 0,
    this.currentStreak = 0,
    this.lastUsedIso = '',
  });

  factory _ZenStats.fromJson(Map<String, dynamic> j) => _ZenStats(
        totalSeconds:  (j['totalSeconds']  as num?)?.toInt() ?? 0,
        weeklySeconds: (j['weeklySeconds'] as num?)?.toInt() ?? 0,
        weekStartIso:   j['weekStartIso']  as String? ?? '',
        sessionsCount: (j['sessionsCount'] as num?)?.toInt() ?? 0,
        currentStreak: (j['currentStreak'] as num?)?.toInt() ?? 0,
        lastUsedIso:    j['lastUsedIso']   as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'totalSeconds':  totalSeconds,
        'weeklySeconds': weeklySeconds,
        'weekStartIso':  weekStartIso,
        'sessionsCount': sessionsCount,
        'currentStreak': currentStreak,
        'lastUsedIso':   lastUsedIso,
      };
}

class ZenScreen extends StatefulWidget {
  const ZenScreen({super.key});

  @override
  State<ZenScreen> createState() => _ZenScreenState();
}

class _ZenScreenState extends State<ZenScreen> {
  // Singleton ref so the background-notification action can reach the live state.
  static _ZenScreenState? _instance;
  // Guard so the channel + plugin is only initialised once per process lifetime.
  static bool _notifsReady = false;

  static const _tracks = [
    _ZenTrack(id: 'zen_rain',      name: 'Rain',            emoji: '🌧️', description: 'Gentle rainfall',              file: 'rain_sound.mp3'),
    _ZenTrack(id: 'zen_thunder',   name: 'Thunderstorm',    emoji: '⛈️', description: 'Distant thunder',    file: 'thunderstorm.mp3'),
    _ZenTrack(id: 'zen_forest',    name: 'Forest',          emoji: '🌲', description: 'Birds and rustling leaves',    file: 'forest_sounds.mp3'),
    _ZenTrack(id: 'zen_ocean',     name: 'Ocean Waves',     emoji: '🌊', description: 'Rhythmic waves on shore',      file: 'ocean_waves.mp3'),
    _ZenTrack(id: 'zen_fire',      name: 'Fireplace',       emoji: '🔥', description: 'Crackling fire',              file: 'fireplace.mp3'),
    _ZenTrack(id: 'zen_cafe',      name: 'Café',            emoji: '☕', description: 'Quiet coffee shop ambience',  file: 'coffee_shop.mp3'),
    _ZenTrack(id: 'zen_wind',      name: 'Wind',            emoji: '🌬️', description: 'Soft breeze through trees',   file: 'windy.mp3'),
    _ZenTrack(id: 'zen_white',     name: 'White Noise',     emoji: '📻', description: 'Steady background hiss',      file: 'white_noise.mp3'),
    _ZenTrack(id: 'zen_stream',    name: 'Mountain Stream', emoji: '🏔️', description: 'Flowing water over rocks',    file: 'mountain_stream.mp3'),
    _ZenTrack(id: 'zen_night',     name: 'Night Crickets',  emoji: '🦗', description: 'Summer evening insects',      file: 'night_crickets.mp3'),
    _ZenTrack(id: 'zen_pad1',      name: 'Drift',           emoji: '🌌', description: 'Soft synthetic horizon',      file: 'ambient_pad1.mp3'),
    _ZenTrack(id: 'zen_pad2',      name: 'Ether',           emoji: '🔮', description: 'Warm atmospheric haze',       file: 'ambient_pad2.mp3'),
    _ZenTrack(id: 'zen_pad3',      name: 'Cosmos',          emoji: '✨', description: 'Deep space resonance',        file: 'ambient_pad3.mp3'),
    _ZenTrack(id: 'zen_pad4',      name: 'Aurora',          emoji: '🌠', description: 'Shimmering celestial tone',   file: 'ambient_pad4.mp3'),
    _ZenTrack(id: 'zen_guitar',    name: 'Guitar Loop',     emoji: '🎸', description: 'Gentle acoustic melody',       file: 'intentions_guitar_loop.mp3'),
    _ZenTrack(id: 'zen_farm',      name: 'Farm Morning',    emoji: '🐔', description: 'Countryside waking up',        file: 'farm_chicken_sound.mp3'),
    _ZenTrack(id: 'zen_simmer',    name: 'Simmering',       emoji: '♨️', description: 'Bubbling pot, warm kitchen',   file: 'pot_of_boiling_water.mp3'),
    _ZenTrack(id: 'zen_underwater',name: 'Deep Blue',       emoji: '🐠', description: 'Subaquatic serenity',          file: 'underwater_sounds.mp3'),
    _ZenTrack(id: 'zen_clock',     name: 'Ticking Clock',   emoji: '🕰️', description: 'Steady mechanical tick-tock',  file: 'ticking_clock.mp3'),
  ];

  // Loaded sources — only populated for tracks whose file exists
  final Map<String, AudioSource> _sources = {};
  // Active handles
  final Map<String, SoundHandle> _handles = {};
  // Handles currently fading out (stop pending)
  final Map<String, SoundHandle> _fadingOut = {};
  // Which tracks are in a loading state
  final Set<String> _loading = {};
  // Which tracks are available (file found in assets)
  final Set<String> _available = {};

  // Preload state
  bool _isProbing = true;
  int _probeCount = 0;

  // Per-track volume: 1–100, default 50 (maps to SoLoud 0.02–2.0, 50=1.0)
  final Map<String, double> _volumes = {};

  // Saved presets
  List<_ZenPreset> _presets = [];

  // Pinned / favourite track IDs
  Set<String> _favourites = {};

  // Usage stats
  _ZenStats _stats = _ZenStats();
  DateTime? _playStart; // non-null while any track is playing

  // Fires every minute to refresh the elapsed-time in the notification
  Timer? _notifTimer;

  @override
  void initState() {
    super.initState();
    _instance = this;
    _probeAssets();
    _loadPresets();
    _loadFavourites();
    _loadStats();
    _initNotifications();
  }

  @override
  void dispose() {
    if (_instance == this) _instance = null;
    _notifTimer?.cancel();
    // Record any in-progress session before tearing down
    _recordElapsed();
    _stopAll(notify: false);
    _cancelNotification();
    for (final src in _sources.values) {
      try { SoLoud.instance.disposeSource(src); } catch (_) {}
    }
    super.dispose();
  }

  // ── Notifications ────────────────────────────────────────────────────────

  Future<void> _initNotifications() async {
    if (_notifsReady) return;
    // Create the low-importance Android channel (no sound, no vibration).
    final androidPlugin = _zenNotifPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        _kZenChannelId, 'Zen Mode',
        description: 'Ambient sound playback controls',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    );
    await _zenNotifPlugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_stat_soundr'),
        iOS: DarwinInitializationSettings(requestSoundPermission: false),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.actionId == 'stop_all') _instance?._stopAll();
      },
      onDidReceiveBackgroundNotificationResponse: _onBgZenNotif,
    );
    _notifsReady = true;
  }

  /// Formats a duration into a human-readable elapsed string for the notification.
  static String _fmtElapsed(Duration d) {
    final mins = d.inMinutes;
    if (mins < 1) return '';
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  /// Post (or refresh) the ongoing notification listing what's playing.
  Future<void> _showOrUpdateNotification() async {
    if (!_notifsReady) return;
    final playing = _tracks.where((t) => _handles.containsKey(t.id)).toList();
    if (playing.isEmpty) return;
    final names = playing.map((t) => '${t.emoji} ${t.name}').join('  ·  ');
    // Second line: "X min in Zen Mode" — only shown once a minute has elapsed
    final elapsedStr = _playStart != null
        ? _fmtElapsed(DateTime.now().difference(_playStart!))
        : '';
    final body = elapsedStr.isEmpty
        ? names
        : '$names\n$elapsedStr in Zen Mode';
    final androidDetails = AndroidNotificationDetails(
      _kZenChannelId, 'Zen Mode',
      channelDescription: 'Ambient sound playback controls',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      // BigTextStyleInformation preserves the \n as a real second line
      styleInformation: BigTextStyleInformation(body),
      actions: const [
        AndroidNotificationAction(
          'stop_all', 'Stop all',
          // showsUserInterface routes the tap through the main isolate so
          // onDidReceiveNotificationResponse (and _instance._stopAll) fires.
          showsUserInterface: true,
          cancelNotification: false, // we cancel it ourselves inside _stopAll
        ),
      ],
    );
    try {
      await _zenNotifPlugin.show(
        _kZenNotifId,
        '🧘 Zen Mode',
        body,
        NotificationDetails(android: androidDetails),
      );
    } catch (_) {}
  }

  Future<void> _cancelNotification() async {
    try {
      await _zenNotifPlugin.cancel(_kZenNotifId);
    } catch (_) {}
  }

  // Try loading each track silently to know which files exist
  Future<void> _probeAssets() async {
    for (final track in _tracks) {
      try {
        final data = await rootBundle.load('assets/sounds/zen/${track.file}');
        final bytes = data.buffer.asUint8List();
        final source = await SoLoud.instance.loadMem(track.id, bytes);
        if (mounted) {
          setState(() {
            _sources[track.id] = source;
            _available.add(track.id);
          });
        }
      } catch (_) {
        // File not yet added — tile shows "Coming Soon"
      }
      if (mounted) setState(() => _probeCount++);
    }
    if (mounted) setState(() => _isProbing = false);
  }

  static const _fadeDuration = Duration(seconds: 1);

  Future<void> _toggle(_ZenTrack track) async {
    if (!_available.contains(track.id)) return;

    if (_handles.containsKey(track.id)) {
      // Fade out then stop
      final handle = _handles[track.id]!;
      setState(() {
        _handles.remove(track.id);
        _fadingOut[track.id] = handle;
      });
      _onHandlesUpdated(); // may end session if last track
      try {
        SoLoud.instance.fadeVolume(handle, 0.0, _fadeDuration);
      } catch (_) {}
      Future.delayed(_fadeDuration, () {
        if (!mounted) return;
        try { SoLoud.instance.stop(handle); } catch (_) {}
        setState(() => _fadingOut.remove(track.id));
      });
      return;
    }

    // If a fade-out is still in progress for this track, cancel it by
    // stopping the old handle immediately so the new play starts clean.
    if (_fadingOut.containsKey(track.id)) {
      final old = _fadingOut[track.id]!;
      try { SoLoud.instance.stop(old); } catch (_) {}
      _fadingOut.remove(track.id);
    }

    // Play looping at volume 0, then fade in to the track's stored volume
    final source = _sources[track.id];
    if (source == null) return;

    // Default volume = 50 on first play
    _volumes.putIfAbsent(track.id, () => 50.0);

    setState(() => _loading.add(track.id));
    try {
      final handle = await SoLoud.instance.play(
        source,
        looping: true,
        volume: 0.0,
      );
      if (mounted) {
        final targetVol = _volumes[track.id]! / 50.0; // 50 → 1.0, 100 → 2.0
        try {
          SoLoud.instance.fadeVolume(handle, targetVol, _fadeDuration);
        } catch (_) {}
        setState(() {
          _handles[track.id] = handle;
          _loading.remove(track.id);
        });
        _onHandlesUpdated(); // may start session if first track
      } else {
        // Widget disposed before play completed
        try { SoLoud.instance.stop(handle); } catch (_) {}
      }
    } catch (_) {
      if (mounted) setState(() => _loading.remove(track.id));
    }
  }

  void _setVolume(String trackId, double value) {
    setState(() => _volumes[trackId] = value);
    final handle = _handles[trackId];
    if (handle == null) return;
    try {
      SoLoud.instance.setVolume(handle, value / 50.0);
    } catch (_) {}
  }

  // ── Favourites persistence ───────────────────────────────────────────────

  Future<File> _favouritesFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/zen_favourites.json');
  }

  Future<void> _loadFavourites() async {
    try {
      final file = await _favouritesFile();
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List;
        if (mounted) {
          setState(() => _favourites = list.cast<String>().toSet());
        }
      }
    } catch (_) {}
  }

  Future<void> _persistFavourites() async {
    try {
      final file = await _favouritesFile();
      await file.writeAsString(jsonEncode(_favourites.toList()));
    } catch (_) {}
  }

  void _toggleFavourite(String trackId) {
    setState(() {
      if (_favourites.contains(trackId)) {
        _favourites.remove(trackId);
      } else {
        _favourites.add(trackId);
      }
    });
    _persistFavourites();
  }

  // ── Preset persistence ──────────────────────────────────────────────────

  Future<File> _presetsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/zen_presets.json');
  }

  Future<void> _loadPresets() async {
    try {
      final file = await _presetsFile();
      if (await file.exists()) {
        final list = jsonDecode(await file.readAsString()) as List;
        if (mounted) {
          setState(() {
            _presets = list.map((j) => _ZenPreset.fromJson(j as Map<String, dynamic>)).toList();
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _persistPresets() async {
    try {
      final file = await _presetsFile();
      await file.writeAsString(jsonEncode(_presets.map((p) => p.toJson()).toList()));
    } catch (_) {}
  }

  // ── Usage stats ──────────────────────────────────────────────────────────

  static String _todayIso() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  static String _mondayIso() {
    final n = DateTime.now();
    final mon = n.subtract(Duration(days: n.weekday - 1));
    return '${mon.year}-${mon.month.toString().padLeft(2, '0')}-${mon.day.toString().padLeft(2, '0')}';
  }

  static bool _isYesterday(String isoA, String isoB) {
    try {
      return DateTime.parse(isoB).difference(DateTime.parse(isoA)).inDays == 1;
    } catch (_) {
      return false;
    }
  }

  Future<File> _statsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/zen_stats.json');
  }

  Future<void> _loadStats() async {
    try {
      final file = await _statsFile();
      if (await file.exists()) {
        final s = _ZenStats.fromJson(
            jsonDecode(await file.readAsString()) as Map<String, dynamic>);
        // Reset weekly counter if a new week has started
        final monday = _mondayIso();
        if (s.weekStartIso != monday) {
          s.weeklySeconds = 0;
          s.weekStartIso = monday;
        }
        if (mounted) setState(() => _stats = s);
      }
    } catch (_) {}
  }

  Future<void> _persistStats() async {
    try {
      final file = await _statsFile();
      await file.writeAsString(jsonEncode(_stats.toJson()));
    } catch (_) {}
  }

  void _clearStats(BuildContext sheetContext) {
    final c = Theme.of(context).extension<AppColors>()!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Clear all stats?',
            style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
        content: Text(
          'Your session history, streak, and totals will be permanently deleted.',
          style: TextStyle(color: c.textMuted, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: c.textMuted)),
          ),
          TextButton(
            onPressed: () {
              setState(() => _stats = _ZenStats());
              _persistStats();
              Navigator.pop(ctx);             // close confirm dialog
              Navigator.pop(sheetContext);    // close info sheet
            },
            child: Text('Clear', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// Called whenever _handles changes (track added or removed).
  void _onHandlesUpdated() {
    if (_handles.isNotEmpty) {
      if (_playStart == null) {
        // First track — session starts
        _playStart = DateTime.now();
        _stats.sessionsCount++;
        // Refresh the notification every minute so elapsed time stays current
        _notifTimer?.cancel();
        _notifTimer = Timer.periodic(const Duration(minutes: 1), (_) {
          _showOrUpdateNotification();
        });
      }
      // Show or refresh the notification with the current track list
      _showOrUpdateNotification();
    } else if (_handles.isEmpty && _playStart != null) {
      _notifTimer?.cancel();
      _notifTimer = null;
      _recordElapsed();
      _cancelNotification();
      if (mounted) setState(() {}); // refresh any stat display
    }
  }

  /// Flush elapsed time to stats. Safe to call at any time; no-op if not playing.
  void _recordElapsed() {
    if (_playStart == null) return;
    final secs = DateTime.now().difference(_playStart!).inSeconds;
    _playStart = null;
    if (secs < 5) return; // ignore accidental taps

    // Weekly reset guard
    final monday = _mondayIso();
    if (_stats.weekStartIso != monday) {
      _stats.weeklySeconds = 0;
      _stats.weekStartIso = monday;
    }

    _stats.totalSeconds  += secs;
    _stats.weeklySeconds += secs;

    // Streak
    final today = _todayIso();
    if (_stats.lastUsedIso != today) {
      if (_stats.lastUsedIso.isEmpty || _isYesterday(_stats.lastUsedIso, today)) {
        _stats.currentStreak++;
      } else {
        _stats.currentStreak = 1;
      }
      _stats.lastUsedIso = today;
    }

    _persistStats();
  }

  void _saveCurrentAsPreset(String name) {
    final volumes = <String, double>{};
    for (final id in _handles.keys) {
      volumes[id] = _volumes[id] ?? 50.0;
    }
    if (volumes.isEmpty) return;
    final preset = _ZenPreset(
      id: DateTime.now().millisecondsSinceEpoch.toRadixString(16),
      name: name,
      volumes: volumes,
    );
    setState(() => _presets.add(preset));
    _persistPresets();
  }

  Future<void> _activatePreset(_ZenPreset preset) async {
    _stopAll();
    // Apply preset volumes first so _toggle picks them up during fade-in
    for (final e in preset.volumes.entries) {
      _volumes[e.key] = e.value;
    }
    // Start all preset tracks concurrently
    await Future.wait(
      preset.volumes.keys
          .where((id) => _available.contains(id))
          .map((id) => _toggle(_tracks.firstWhere((t) => t.id == id))),
    );
  }

  void _deletePreset(_ZenPreset preset, BuildContext context, AppColors c, Color accent) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Delete preset?',
            style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
        content: Text(
          '"${preset.name}" will be removed.',
          style: TextStyle(color: c.textMuted, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: c.textMuted)),
          ),
          TextButton(
            onPressed: () {
              setState(() => _presets.removeWhere((p) => p.id == preset.id));
              _persistPresets();
              Navigator.pop(ctx);
            },
            child: Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  static const _kMaxPresets = 10;

  void _showSavePresetDialog(BuildContext context, AppColors c, Color accent) {
    // Preset limit guard
    if (_presets.length >= _kMaxPresets) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: c.surfaceCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Mix limit reached',
              style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
          content: Text(
            'You have $_kMaxPresets saved mixes — the strip gets crowded beyond that. '
            'Long-press any mix chip to delete one, then save your new mix.',
            style: TextStyle(color: c.textMuted, fontSize: 14, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Got it', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
      return;
    }

    final playing = _tracks.where((t) => _handles.containsKey(t.id)).toList();
    final suggestion = playing.length <= 2
        ? playing.map((t) => t.name).join(' + ')
        : '${playing.first.name} mix';
    final ctrl = TextEditingController(text: suggestion);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Save mix',
            style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700, fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sound preview chips
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: playing
                  .map((t) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('${t.emoji} ${t.name}',
                            style: TextStyle(fontSize: 12, color: accent, fontWeight: FontWeight.w500)),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: TextStyle(color: c.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Name this mix…',
                hintStyle: TextStyle(color: c.textMuted),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.border)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: accent, width: 2)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: c.textMuted)),
          ),
          TextButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              _saveCurrentAsPreset(name);
              Navigator.pop(ctx);
            },
            child: Text('Save', style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // Returns true if the currently playing set exactly matches the preset's tracks
  bool _isActivePreset(_ZenPreset preset) {
    if (_handles.length != preset.volumes.length) return false;
    return _handles.keys.every((id) => preset.volumes.containsKey(id));
  }

  void _stopAll({bool notify = true}) {
    for (final handle in _handles.values) {
      try { SoLoud.instance.stop(handle); } catch (_) {}
    }
    for (final handle in _fadingOut.values) {
      try { SoLoud.instance.stop(handle); } catch (_) {}
    }
    if (notify && mounted) {
      setState(() {
        _handles.clear();
        _fadingOut.clear();
      });
      _onHandlesUpdated(); // ends session if one was active
    } else {
      _handles.clear();
      _fadingOut.clear();
      // dispose() will call _recordElapsed() before this path
    }
  }

  bool get _anyPlaying => _handles.isNotEmpty || _fadingOut.isNotEmpty;

  void _showVolumeSheet(BuildContext context, _ZenTrack track, AppColors c, Color accent) {
    showModalBottomSheet(
      context: context,
      backgroundColor: c.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final vol = _volumes[track.id] ?? 50.0;
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle bar
                Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: c.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                // Track header
                Row(
                  children: [
                    Text(track.emoji, style: const TextStyle(fontSize: 28)),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.name,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          track.description,
                          style: TextStyle(color: c.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        vol.round().toString(),
                        style: TextStyle(
                          color: accent,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Slider row
                Row(
                  children: [
                    Icon(Icons.volume_down_rounded, color: c.textMuted, size: 20),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: accent,
                          inactiveTrackColor: accent.withValues(alpha: 0.18),
                          thumbColor: accent,
                          overlayColor: accent.withValues(alpha: 0.12),
                          trackHeight: 3.5,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                        ),
                        child: Slider(
                          value: vol,
                          min: 1,
                          max: 100,
                          divisions: 99,
                          onChanged: (v) {
                            setSheetState(() => _volumes[track.id] = v);
                            _setVolume(track.id, v);
                          },
                        ),
                      ),
                    ),
                    Icon(Icons.volume_up_rounded, color: c.textMuted, size: 20),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('1', style: TextStyle(color: c.textMuted, fontSize: 11)),
                    Text('50  (default)', style: TextStyle(color: c.textMuted, fontSize: 11)),
                    Text('100', style: TextStyle(color: c.textMuted, fontSize: 11)),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showInfoSheet(BuildContext context, AppColors c, Color accent) {
    showModalBottomSheet(
      context: context,
      backgroundColor: c.surfaceCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetCtx) => _ZenInfoSheet(
        colors: c,
        accent: accent,
        stats: _stats,
        onClearStats: () => _clearStats(sheetCtx),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    // ── Preload screen ────────────────────────────────────────────────────
    if (_isProbing) {
      return Scaffold(
        backgroundColor: c.scaffoldBg,
        appBar: AppBar(
          backgroundColor: c.surfaceCard,
          foregroundColor: c.textPrimary,
          elevation: 0,
          title: Row(
            children: [
              const Text('🧘', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Text('Zen Mode',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  )),
            ],
          ),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🧘', style: TextStyle(fontSize: 72)),
                const SizedBox(height: 28),
                Text(
                  'Zen Mode',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Loading ambient sounds…',
                  style: TextStyle(color: c.textMuted, fontSize: 14),
                ),
                const SizedBox(height: 32),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _tracks.isEmpty ? 0 : _probeCount / _tracks.length,
                    minHeight: 5,
                    backgroundColor: accent.withValues(alpha: 0.12),
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$_probeCount of ${_tracks.length}',
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ── Main screen ───────────────────────────────────────────────────────
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.surfaceCard,
        foregroundColor: c.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            const Text('🧘', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Text(
              'Zen Mode',
              style: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ],
        ),
        actions: [
          if (_anyPlaying)
            TextButton.icon(
              onPressed: _stopAll,
              icon: Icon(Icons.stop_rounded, size: 18, color: c.textSecondary),
              label: Text(
                'Stop all',
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Header hint row — tap anywhere to open the info sheet
          GestureDetector(
            onTap: () => _showInfoSheet(context, c, accent),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Row(
                children: [
                  Icon(Icons.layers_rounded, size: 15, color: c.textMuted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Layer multiple sounds — they loop until stopped.',
                      style: TextStyle(color: c.textMuted, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.info_outline_rounded, size: 15, color: c.textMuted),
                ],
              ),
            ),
          ),

          // ── Favourites row ───────────────────────────────────────────────
          if (_favourites.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 5),
              child: Row(
                children: [
                  Icon(Icons.star_rounded, size: 12, color: accent),
                  const SizedBox(width: 5),
                  Text(
                    'Pinned',
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: _tracks
                    .where((t) => _favourites.contains(t.id) && _available.contains(t.id))
                    .map((t) => _FavouriteChip(
                          track: t,
                          isPlaying: _handles.containsKey(t.id),
                          accent: accent,
                          colors: c,
                          onTap: () => _toggle(t),
                        ))
                    .toList(),
              ),
            ),
            const SizedBox(height: 6),
          ],

          // ── Presets row ──────────────────────────────────────────────────
          if (_presets.isNotEmpty || _handles.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  if (_handles.isNotEmpty)
                    _SaveMixChip(
                      accent: accent,
                      colors: c,
                      onTap: () => _showSavePresetDialog(context, c, accent),
                    ),
                  ..._presets.map((p) => _PresetChip(
                        preset: p,
                        isActive: _isActivePreset(p),
                        accent: accent,
                        colors: c,
                        onTap: () => _activatePreset(p),
                        onLongPress: () => _deletePreset(p, context, c, accent),
                      )),
                ],
              ),
            ),

          if (_presets.isNotEmpty || _handles.isNotEmpty)
            const SizedBox(height: 6),

          // Grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 5, 16, 100),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.1,
              ),
              itemCount: _tracks.length,
              itemBuilder: (context, i) {
                final track = _tracks[i];
                final isAvailable = _available.contains(track.id);
                final isPlaying = _handles.containsKey(track.id);
                final isLoading = _loading.contains(track.id);

                return _ZenTile(
                  track: track,
                  isAvailable: isAvailable,
                  isPlaying: isPlaying,
                  isLoading: isLoading,
                  accent: accent,
                  colors: c,
                  onTap: () => _toggle(track),
                  onLongPress: isPlaying
                      ? () => _showVolumeSheet(context, track, c, accent)
                      : null,
                  volume: _volumes[track.id] ?? 50.0,
                  tileIndex: i,
                  isFavourited: _favourites.contains(track.id),
                  onToggleFavourite: () => _toggleFavourite(track.id),
                );
              },
            ),
          ),
        ],
      ),

      // Now playing bar
      bottomSheet: _anyPlaying ? _NowPlayingBar(
        handles: _handles,
        tracks: _tracks,
        colors: c,
        accent: accent,
        onStop: _stopAll,
      ) : null,
    );
  }
}

class _ZenTile extends StatefulWidget {
  final _ZenTrack track;
  final bool isAvailable;
  final bool isPlaying;
  final bool isLoading;
  final Color accent;
  final AppColors colors;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double volume;   // 1–100
  final int tileIndex;
  final bool isFavourited;
  final VoidCallback onToggleFavourite;

  const _ZenTile({
    required this.track,
    required this.isAvailable,
    required this.isPlaying,
    required this.isLoading,
    required this.accent,
    required this.colors,
    required this.onTap,
    required this.onLongPress,
    required this.volume,
    required this.tileIndex,
    required this.isFavourited,
    required this.onToggleFavourite,
  });

  @override
  State<_ZenTile> createState() => _ZenTileState();
}

class _ZenTileState extends State<_ZenTile> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _shimmerAnim;

  // 25 % of each cycle is a pause (strip off-screen left),
  // 75 % is the eased sweep across the tile.
  static final _tween = TweenSequence<double>([
    TweenSequenceItem(tween: ConstantTween(0.0), weight: 25),
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0)
          .chain(CurveTween(curve: Curves.easeInOut)),
      weight: 75,
    ),
  ]);

  @override
  void initState() {
    super.initState();
    // Stagger start slightly per tile so all tiles don't sweep in sync
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _shimmerAnim = _tween.animate(_ctrl);
    if (widget.isPlaying) _startShimmer();
  }

  void _startShimmer() {
    // Stagger by tile index so sweeps aren't all in lockstep
    final offset = (widget.tileIndex * 0.18) % 1.0;
    _ctrl.value = offset;
    _ctrl.repeat();
  }

  @override
  void didUpdateWidget(_ZenTile old) {
    super.didUpdateWidget(old);
    if (widget.isPlaying == old.isPlaying) return;
    if (widget.isPlaying) {
      _startShimmer();
    } else {
      _ctrl.stop();
      _ctrl.reset();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ── Static tile content ────────────────────────────────────────────────
  Widget _buildContent() {
    final dimmed = !widget.isAvailable;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.track.emoji, style: const TextStyle(fontSize: 36)),
              // Right padding guards description from overlapping the volume badge
              Padding(
                padding: EdgeInsets.only(right: widget.isPlaying ? 36.0 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.track.name,
                      style: TextStyle(
                        color: dimmed
                            ? widget.colors.textMuted
                            : widget.isPlaying
                                ? widget.accent
                                : widget.colors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.track.description,
                      style: TextStyle(color: widget.colors.textMuted, fontSize: 11),
                      softWrap: true,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Loading / playing dot — top-LEFT corner
        if (widget.isLoading)
          Positioned(
            top: 10, left: 10,
            child: SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(widget.accent),
              ),
            ),
          )
        else if (widget.isPlaying)
          Positioned(
            top: 10, left: 10,
            child: Container(
              width: 8, height: 8,
              decoration: BoxDecoration(
                color: widget.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),

        // Star / favourite — top-RIGHT corner, generous tap target
        if (widget.isAvailable)
          Positioned(
            top: 2, right: 2,
            child: GestureDetector(
              onTap: widget.onToggleFavourite,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  widget.isFavourited
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 18,
                  color: widget.isFavourited
                      ? widget.accent
                      : widget.colors.textMuted.withValues(alpha: 0.40),
                ),
              ),
            ),
          ),

        // Volume badge (bottom-left) — visible when playing
        if (widget.isPlaying)
          Positioned(
            bottom: 10, right: 10,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.volume_up_rounded,
                    size: 15, color: widget.accent.withValues(alpha: 0.70)),
                const SizedBox(width: 3),
                Text(
                  widget.volume.round().toString(),
                  style: TextStyle(
                    color: widget.accent.withValues(alpha: 0.70),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),

        // Coming soon badge
        if (!widget.isAvailable)
          Positioned(
            bottom: 10, right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: widget.colors.surfaceElevated,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Soon',
                style: TextStyle(
                  color: widget.colors.textMuted,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final colors = widget.colors;
    final playing = widget.isPlaying;

    return GestureDetector(
      onTap: widget.isAvailable && !widget.isLoading ? widget.onTap : null,
      onLongPress: widget.onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          color: playing ? accent.withValues(alpha: 0.10) : colors.surfaceCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: playing ? accent.withValues(alpha: 0.60) : colors.border,
            width: playing ? 1.8 : 1.0,
          ),
          boxShadow: playing
              ? [BoxShadow(
                  color: accent.withValues(alpha: 0.18),
                  blurRadius: 20,
                  spreadRadius: 1,
                )]
              : [],
        ),
        // StackFit.expand ensures _buildContent fills the AnimatedContainer
        // so Positioned children (dot, badge) sit in the correct corners.
        child: playing
            ? LayoutBuilder(
                builder: (context, box) => Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildContent(),
                    AnimatedBuilder(
                      animation: _shimmerAnim,
                      builder: (context, _) => _ShimmerOverlay(
                        t: _shimmerAnim.value,
                        accent: accent,
                        tileWidth: box.maxWidth,
                        tileHeight: box.maxHeight,
                      ),
                    ),
                  ],
                ),
              )
            : _buildContent(),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shimmer overlay — accent-tinted, brightness-aware diagonal light sweep
// ---------------------------------------------------------------------------
class _ShimmerOverlay extends StatelessWidget {
  final double t;           // 0 → 1, eased, forward-only
  final Color accent;
  final double tileWidth;
  final double tileHeight;

  const _ShimmerOverlay({
    required this.t,
    required this.accent,
    required this.tileWidth,
    required this.tileHeight,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Strip travels from fully off-left to fully off-right
    const stripW = 80.0;
    final dx = -stripW + t * (tileWidth + stripW * 1.5);

    // Dark mode: bright white core + accent halo
    // Light mode: accent-coloured highlight (white wouldn't show on light bg)
    final peak = isDark
        ? Color.lerp(accent, Colors.white, 0.60)!.withValues(alpha: 0.26)
        : accent.withValues(alpha: 0.30);
    final mid = isDark
        ? accent.withValues(alpha: 0.13)
        : accent.withValues(alpha: 0.14);

    return Positioned.fill(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Stack(
          children: [
            Positioned(
              left: dx,
              // Extend beyond tile top/bottom so the tilted strip fills full height
              top: -tileHeight * 0.4,
              bottom: -tileHeight * 0.4,
              width: stripW,
              child: Transform.rotate(
                angle: -0.32, // ~18° — gentle diagonal
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Colors.transparent,
                        mid,
                        peak,
                        mid,
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowPlayingBar extends StatelessWidget {
  final Map<String, SoundHandle> handles;
  final List<_ZenTrack> tracks;
  final AppColors colors;
  final Color accent;
  final VoidCallback onStop;

  const _NowPlayingBar({
    required this.handles,
    required this.tracks,
    required this.colors,
    required this.accent,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final playing = tracks.where((t) => handles.containsKey(t.id)).toList();
    final label = playing.map((t) => '${t.emoji} ${t.name}').join('  ·  ');
    final useMarquee = playing.length > 2;

    final labelStyle = TextStyle(
      color: colors.textPrimary,
      fontSize: 13,
      fontWeight: FontWeight.w500,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 20),
      decoration: BoxDecoration(
        color: colors.surfaceCard,
        border: Border(top: BorderSide(color: colors.borderSubtle)),
      ),
      child: Row(
        children: [
          // Animated dot
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: useMarquee
                ? _MarqueeText(text: label, style: labelStyle)
                : Text(label, style: labelStyle, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onStop,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Stop all',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Continuous seamless marquee using CustomPainter + Ticker.
//
// CustomPainter draws text directly at pixel coordinates — completely bypassing
// Flutter's width-constraint system, so the full text always renders at its
// natural width regardless of Expanded/Row constraints.
// Ticker fires every frame (~60 fps) for perfectly smooth motion.
// A ValueNotifier drives repaints without rebuilding the widget tree.
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  const _MarqueeText({required this.text, required this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late TextPainter _tp;
  late double _unitWidth;
  final ValueNotifier<double> _offset = ValueNotifier(0);
  Duration _prev = Duration.zero;
  bool _firstTick = true;

  // Gap between the end of one loop and the start of the next (pixels)
  static const _kGap = 56.0;
  // Scroll speed in pixels per second
  static const _kSpeed = 48.0;

  @override
  void initState() {
    super.initState();
    // Initial measure with raw widget.style — context-free, just to ensure
    // `_tp` is non-null before the ticker fires its first frame.
    _measure(widget.style);
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-measure with the merged DefaultTextStyle so the app's font family
    // (Outfit via google_fonts) is applied. TextPainter, unlike the Text
    // widget, does not inherit DefaultTextStyle on its own — this merge is
    // what makes the marquee match the rest of the UI.
    _measure(DefaultTextStyle.of(context).style.merge(widget.style));
  }

  void _measure(TextStyle effectiveStyle) {
    _tp = TextPainter(
      text: TextSpan(text: widget.text, style: effectiveStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _unitWidth = _tp.width + _kGap;
    _offset.value = 0;
    _prev = Duration.zero;
    _firstTick = true;
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    // Skip the first tick to establish a valid _prev reference
    if (_firstTick) { _firstTick = false; _prev = elapsed; return; }
    final dt = (elapsed - _prev).inMicroseconds / 1e6;
    _prev = elapsed;
    _offset.value = (_offset.value + _kSpeed * dt) % _unitWidth;
  }

  @override
  void didUpdateWidget(_MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.style != widget.style) {
      _measure(DefaultTextStyle.of(context).style.merge(widget.style));
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // LayoutBuilder reads the exact available width from Expanded so we can
    // pass a concrete Size to CustomPaint — avoids relying on constraint
    // clamping of Size.zero and prevents any ambiguity about the canvas size.
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth == double.infinity ? 300.0 : constraints.maxWidth;
      return SizedBox(
        width: w,
        height: _tp.height,
        child: ClipRect(
          child: CustomPaint(
            size: Size(w, _tp.height),
            painter: _MarqueePainter(
              tp: _tp,
              offset: _offset,
              unitWidth: _unitWidth,
            ),
          ),
        ),
      );
    });
  }
}

// Repaints whenever _offset changes (via ValueNotifier repaint hook).
// No widget rebuilds needed — just direct canvas draws each frame.
class _MarqueePainter extends CustomPainter {
  final TextPainter tp;
  final ValueNotifier<double> offset;
  final double unitWidth;

  _MarqueePainter({
    required this.tp,
    required this.offset,
    required this.unitWidth,
  }) : super(repaint: offset);

  @override
  void paint(Canvas canvas, Size size) {
    final o = offset.value;
    final y = (size.height - tp.height) / 2;
    // First copy: slides left as o increases
    tp.paint(canvas, Offset(-o, y));
    // Second copy: exactly one unit-width to the right — slides in seamlessly
    tp.paint(canvas, Offset(unitWidth - o, y));
  }

  @override
  bool shouldRepaint(_MarqueePainter old) =>
      old.tp != tp || old.unitWidth != unitWidth;
}

// ---------------------------------------------------------------------------
// Zen Mode info sheet
// ---------------------------------------------------------------------------
class _ZenInfoSheet extends StatelessWidget {
  final AppColors colors;
  final Color accent;
  final _ZenStats stats;
  final VoidCallback onClearStats;

  const _ZenInfoSheet({
    required this.colors,
    required this.accent,
    required this.stats,
    required this.onClearStats,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24, 16, 24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: colors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // Header
          Row(
            children: [
              const Text('🧘', style: TextStyle(fontSize: 40)),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Zen Mode',
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Your ambient soundscape',
                    style: TextStyle(color: colors.textMuted, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Stats card ────────────────────────────────────────────────
          _ZenStatsCard(
            stats: stats,
            colors: colors,
            accent: accent,
            onReset: (stats.totalSeconds > 0 || stats.sessionsCount > 0)
                ? onClearStats
                : null,
          ),
          const SizedBox(height: 16),

          // Intro blurb
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: accent.withValues(alpha: 0.16)),
            ),
            child: Text(
              'Mix and match ambient sounds to craft the perfect focus, relaxation or sleep atmosphere. '
              'Sounds run continuously in the background — set it up once and let it be.',
              style: TextStyle(
                color: colors.textSecondary,
                fontSize: 13,
                height: 1.55,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // How-to items
          _InfoItem(
            emoji: '▶',
            title: 'Play & stop',
            body: 'Tap any tile to start a sound. Tap it again to stop. '
                'Each sound fades in smoothly when started and fades out when stopped.',
            colors: colors,
            accent: accent,
          ),
          _InfoItem(
            emoji: '🔁',
            title: 'Seamless looping',
            body: 'Every sound loops continuously with no gaps or interruptions — '
                'just set it and enjoy.',
            colors: colors,
            accent: accent,
          ),
          _InfoItem(
            emoji: '🎚️',
            title: 'Layer sounds',
            body: 'Tap multiple tiles to play them at the same time and blend '
                'your own soundscape. Try Rain + Fireplace, or Forest + Stream.',
            colors: colors,
            accent: accent,
          ),
          _InfoItem(
            emoji: '🔊',
            title: 'Volume per sound',
            body: 'Long-press any playing tile to adjust its volume individually '
                'on a scale of 1–100. Default is 50.',
            colors: colors,
            accent: accent,
          ),
          _InfoItem(
            emoji: '🔖',
            title: 'Save a mix',
            body: 'When sounds are playing, tap "Save mix" in the strip above the grid '
                'to name and save your current combination. Your mixes are stored '
                'and persist between sessions.',
            colors: colors,
            accent: accent,
          ),
          _InfoItem(
            emoji: '▤',
            title: 'Restore a mix',
            body: 'Tap any saved mix chip to instantly switch to it — current sounds '
                'stop and the saved ones fade in at their saved volumes. '
                'Long-press a chip to delete it.',
            colors: colors,
            accent: accent,
          ),
          _InfoItem(
            emoji: '⏹️',
            title: 'Stop everything',
            body: 'Tap "Stop all" in the app bar or the bottom bar to silence '
                'all active sounds at once.',
            colors: colors,
            accent: accent,
            isLast: true,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Preset chips
// ---------------------------------------------------------------------------

class _SaveMixChip extends StatelessWidget {
  final Color accent;
  final AppColors colors;
  final VoidCallback onTap;

  const _SaveMixChip({required this.accent, required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 0),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_add_outlined, size: 14, color: accent),
            const SizedBox(width: 5),
            Text(
              'Save mix',
              style: TextStyle(color: accent, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final _ZenPreset preset;
  final bool isActive;
  final Color accent;
  final AppColors colors;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _PresetChip({
    required this.preset,
    required this.isActive,
    required this.accent,
    required this.colors,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
        decoration: BoxDecoration(
          color: isActive ? accent.withValues(alpha: 0.13) : colors.surfaceElevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isActive ? accent.withValues(alpha: 0.55) : colors.border,
            width: isActive ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive) ...[
              Icon(Icons.graphic_eq_rounded, size: 13, color: accent),
              const SizedBox(width: 5),
            ],
            Text(
              preset.name,
              style: TextStyle(
                color: isActive ? accent : colors.textSecondary,
                fontSize: 13,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Favourite chip — compact tile in the pinned row
// ---------------------------------------------------------------------------
class _FavouriteChip extends StatelessWidget {
  final _ZenTrack track;
  final bool isPlaying;
  final Color accent;
  final AppColors colors;
  final VoidCallback onTap;

  const _FavouriteChip({
    required this.track,
    required this.isPlaying,
    required this.accent,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        decoration: BoxDecoration(
          color: isPlaying ? accent.withValues(alpha: 0.12) : colors.surfaceElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isPlaying ? accent.withValues(alpha: 0.55) : colors.border,
            width: isPlaying ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(track.emoji, style: const TextStyle(fontSize: 17)),
            const SizedBox(width: 6),
            Text(
              track.name,
              style: TextStyle(
                color: isPlaying ? accent : colors.textSecondary,
                fontSize: 12,
                fontWeight: isPlaying ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (isPlaying) ...[
              const SizedBox(width: 6),
              Container(
                width: 5, height: 5,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stats card shown inside the info sheet
// ---------------------------------------------------------------------------
class _ZenStatsCard extends StatelessWidget {
  final _ZenStats stats;
  final AppColors colors;
  final Color accent;
  final VoidCallback? onReset; // null → no reset button shown

  const _ZenStatsCard({
    required this.stats,
    required this.colors,
    required this.accent,
    this.onReset,
  });

  static String _fmt(int seconds) {
    if (seconds < 60) return '< 1 min';
    final m = seconds ~/ 60;
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final rm = m % 60;
    return rm == 0 ? '${h}h' : '${h}h ${rm}m';
  }

  @override
  Widget build(BuildContext context) {
    final hasData = stats.totalSeconds > 0 || stats.sessionsCount > 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
      ),
      child: hasData
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StatCell(label: 'This week',  value: _fmt(stats.weeklySeconds), emoji: '⏱', colors: colors, accent: accent),
                    _StatCell(label: 'All time',   value: _fmt(stats.totalSeconds),  emoji: '📅', colors: colors, accent: accent),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    _StatCell(label: 'Sessions',   value: stats.sessionsCount.toString(), emoji: '🎵', colors: colors, accent: accent),
                    _StatCell(
                      label: 'Streak',
                      value: stats.currentStreak == 0 ? '—' : '${stats.currentStreak}d',
                      emoji: '🔥',
                      colors: colors,
                      accent: accent,
                    ),
                  ],
                ),
                if (onReset != null) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: GestureDetector(
                      onTap: onReset,
                      child: const Text(
                        'Reset',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            )
          : Row(
              children: [
                Icon(Icons.bar_chart_rounded, size: 16, color: colors.textMuted),
                const SizedBox(width: 8),
                Text(
                  'Start listening to see your stats here.',
                  style: TextStyle(color: colors.textMuted, fontSize: 13),
                ),
              ],
            ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final String emoji;
  final AppColors colors;
  final Color accent;

  const _StatCell({
    required this.label,
    required this.value,
    required this.emoji,
    required this.colors,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$emoji  $label',
            style: TextStyle(color: colors.textMuted, fontSize: 11, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final String emoji;
  final String title;
  final String body;
  final AppColors colors;
  final Color accent;
  final bool isLast;

  const _InfoItem({
    required this.emoji,
    required this.title,
    required this.body,
    required this.colors,
    required this.accent,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon chip
          Container(
            width: 38, height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(emoji, style: const TextStyle(fontSize: 17)),
          ),
          const SizedBox(width: 14),
          // Text
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
