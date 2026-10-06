import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:path_provider/path_provider.dart';

import '../services/clip_repository.dart';
import '../services/zen_last_mix.dart';
import '../theme/app_colors.dart';
import '../widgets/zen_widgets.dart';

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

/// Pre-fills the screen so goldens can show a playing mix without SoLoud,
/// notifications or storage. Never used by the app itself.
@visibleForTesting
class ZenDebugSeed {
  /// Track id → volume (1–100) of the sounds that are "playing".
  final Map<String, double> playing;
  final bool paused;

  /// Length of a running sleep timer, and how much of it is left.
  final int? sleepMinutes;
  final Duration? sleepRemaining;

  /// Saved mixes, name → (track id → volume), in chip order.
  final Map<String, Map<String, double>> presets;
  final String? selectedPreset;
  final Set<String> loading;

  /// Show the preloading screen instead of the grid.
  final bool probing;

  const ZenDebugSeed({
    this.playing = const {},
    this.paused = false,
    this.sleepMinutes,
    this.sleepRemaining,
    this.presets = const {},
    this.selectedPreset,
    this.loading = const {},
    this.probing = false,
  });
}

class ZenScreen extends StatefulWidget {
  /// Start playing the last mix (see [ZenLastMix]) as soon as it loads.
  final bool resumeLastMix;

  @visibleForTesting
  final ZenDebugSeed? debugSeed;

  const ZenScreen({
    super.key,
    this.resumeLastMix = false,
    @visibleForTesting this.debugSeed,
  });

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
  // Timers that finish those fade-outs; cancelled on dispose
  final Set<Timer> _pendingStops = {};
  // Which tracks are in a loading state
  final Set<String> _loading = {};
  // Which tracks are available (file found in assets)
  final Set<String> _available = {};

  // Preload state
  bool _isProbing = true;
  int _probeCount = 0;

  // Per-track volume: 1–100, default 50 (maps to SoLoud 0.02–2.0, 50=1.0)
  final Map<String, double> _volumes = {};

  // Saved presets, and the one last started from its chip / saved
  List<_ZenPreset> _presets = [];
  String? _selectedPresetId;

  // Every handle is paused (the dock's Pause button)
  bool _paused = false;
  // Bumped on every pause/resume/stop so a pause fade that's been
  // overtaken doesn't pause the sounds when it finishes.
  int _pauseGen = 0;
  // Content has scrolled under the header.
  bool _scrolledUnder = false;

  // Usage stats. A session runs from the first sound starting to the mix
  // emptying; time spent paused is not counted.
  _ZenStats _stats = _ZenStats();
  bool _sessionActive = false;
  DateTime? _segmentStart; // non-null while the session is audibly playing
  int _sessionSecs = 0;    // played seconds banked before the current segment

  // Fires every minute to refresh the elapsed-time in the notification
  Timer? _notifTimer;

  // ── Sleep timer ──
  static const _sleepChoices = [15, 30, 45, 60, 90, 120];
  static const _sleepFadeTime = Duration(seconds: 60);
  DateTime? _sleepEnd;
  Duration _sleepTotal = Duration.zero;
  Timer? _sleepTimer;
  bool _sleepFading = false;     // the last-minute fade is under way
  bool _sleepFadeEnabled = true; // "Fade out gently" (persisted)
  int _sleepMinutes = 30;        // last chosen length (persisted)
  final ValueNotifier<Duration?> _sleepLeft = ValueNotifier(null);

  // Bumped on every setState so open sheets rebuild along with the screen.
  final ValueNotifier<int> _rev = ValueNotifier(0);

  Timer? _lastMixTimer;
  int _fakeHandleId = 1;
  // What the dock shows; kept while it slides away after the mix empties.
  List<_ZenTrack> _dockTracks = const [];

  bool get _audio => widget.debugSeed == null;

  List<_ZenTrack> get _playingTracks =>
      _tracks.where((t) => _handles.containsKey(t.id)).toList();

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _rev.value++;
  }

  @override
  void initState() {
    super.initState();
    _instance = this;
    final seed = widget.debugSeed;
    if (seed != null) {
      _applySeed(seed);
    } else {
      _init();
    }
  }

  Future<void> _init() async {
    final presets = _loadPresets();
    _loadStats();
    _loadSleepPrefs();
    _initNotifications().catchError((_) {});
    await _probeAssets();
    await presets;
    if (widget.resumeLastMix && mounted) await _resumeLastMix();
  }

  void _applySeed(ZenDebugSeed s) {
    _isProbing = s.probing;
    _probeCount = s.probing ? 7 : _tracks.length;
    _available.addAll(_tracks.map((t) => t.id));
    var i = 0;
    for (final e in s.presets.entries) {
      final p = _ZenPreset(id: 'seed${i++}', name: e.key, volumes: Map.of(e.value));
      _presets.add(p);
      if (e.key == s.selectedPreset) _selectedPresetId = p.id;
    }
    for (final e in s.playing.entries) {
      _volumes[e.key] = e.value;
      _handles[e.key] = SoundHandle(_fakeHandleId++);
    }
    _loading.addAll(s.loading);
    _paused = s.paused && _handles.isNotEmpty;
    if (_handles.isNotEmpty) {
      _sessionActive = true;
      _segmentStart = _paused ? null : DateTime.now();
    }
    final mins = s.sleepMinutes;
    if (mins != null) {
      _sleepMinutes = mins;
      _sleepTotal = Duration(minutes: mins);
      final left = s.sleepRemaining ?? _sleepTotal;
      _sleepEnd = DateTime.now().add(left);
      _sleepLeft.value = left;
    }
  }

  @override
  void dispose() {
    if (_instance == this) _instance = null;
    _notifTimer?.cancel();
    _lastMixTimer?.cancel();
    for (final t in _pendingStops) {
      t.cancel();
    }
    _pendingStops.clear();
    // Remember the mix for the Tools tab before tearing it down
    if (_audio && _handles.isNotEmpty) ZenLastMix.save(_currentMix());
    // Record any in-progress session before tearing down
    _recordElapsed();
    _stopAll(notify: false);
    if (_audio) _cancelNotification();
    for (final src in _sources.values) {
      try { SoLoud.instance.disposeSource(src).ignore(); } catch (_) {}
    }
    _sleepLeft.dispose();
    _rev.dispose();
    super.dispose();
  }

  // ── SoLoud wrappers (no-ops when rendering a debug seed) ─────────────────

  Future<SoundHandle> _slPlay(String id) async {
    if (!_audio) return SoundHandle(_fakeHandleId++);
    return SoLoud.instance.play(_sources[id]!, looping: true, volume: 0.0);
  }

  void _slFade(SoundHandle h, double to, Duration time) {
    if (!_audio) return;
    try { SoLoud.instance.fadeVolume(h, to, time); } catch (_) {}
  }

  void _slSetVolume(SoundHandle h, double volume) {
    if (!_audio) return;
    try { SoLoud.instance.setVolume(h, volume); } catch (_) {}
  }

  void _slPause(SoundHandle h, bool pause) {
    if (!_audio) return;
    try { SoLoud.instance.setPause(h, pause); } catch (_) {}
  }

  void _slStop(SoundHandle h) {
    if (!_audio) return;
    try { SoLoud.instance.stop(h).ignore(); } catch (_) {}
  }

  /// Fades to silence, then SoLoud stops the sound itself.
  void _slFadeStop(SoundHandle h, Duration time) {
    if (!_audio) return;
    try {
      SoLoud.instance.fadeVolume(h, 0.0, time);
      SoLoud.instance.scheduleStop(h, time);
    } catch (_) {
      _slStop(h);
    }
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

  /// Wall-clock time in the user's 12/24-hour preference.
  String _fmtTimeOfDay(DateTime t) {
    if (mounted) {
      return MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(t),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );
    }
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Duration get _sessionElapsed {
    var d = Duration(seconds: _sessionSecs);
    final start = _segmentStart;
    if (start != null) d += DateTime.now().difference(start);
    return d;
  }

  /// Post (or refresh) the ongoing notification listing what's playing.
  Future<void> _showOrUpdateNotification() async {
    if (!_audio || !_notifsReady) return;
    final playing = _playingTracks;
    if (playing.isEmpty) return;
    final names = playing.map((t) => '${t.emoji} ${t.name}').join('  ·  ');
    // Second line: paused / "X min in Zen Mode" (after a minute) / sleep timer
    final extras = <String>[
      if (_paused) 'Paused',
      if (_fmtElapsed(_sessionElapsed).isNotEmpty)
        '${_fmtElapsed(_sessionElapsed)} in Zen Mode',
      if (_sleepEnd != null) 'Stops at ${_fmtTimeOfDay(_sleepEnd!)}',
    ];
    final body = extras.isEmpty ? names : '$names\n${extras.join('  ·  ')}';
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
    if (!_audio) return;
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
        // File not yet added — tile shows "Soon"
      }
      if (mounted) setState(() => _probeCount++);
    }
    if (mounted) setState(() => _isProbing = false);
  }

  // ── Playback ─────────────────────────────────────────────────────────────

  static const _fadeDuration = Duration(seconds: 1);
  static const _pauseFade = Duration(milliseconds: 600);

  Future<void> _toggle(_ZenTrack track) async {
    if (!_available.contains(track.id)) return;
    if (_handles.containsKey(track.id)) {
      _stopTrack(track.id);
    } else {
      await _startTrack(track.id);
    }
  }

  /// Fades a playing sound out and drops it from the mix.
  void _stopTrack(String id) {
    final handle = _handles[id];
    if (handle == null) return;
    final wasPaused = _paused;
    setState(() {
      _handles.remove(id);
      if (!wasPaused) _fadingOut[id] = handle;
      if (_handles.isEmpty) _paused = false;
    });
    if (wasPaused) {
      _slStop(handle); // nothing audible to fade
    } else {
      _slFade(handle, 0.0, _fadeDuration);
      late final Timer timer;
      timer = Timer(_fadeDuration, () {
        _pendingStops.remove(timer);
        if (!mounted || _fadingOut[id] != handle) return;
        _slStop(handle);
        setState(() => _fadingOut.remove(id));
      });
      _pendingStops.add(timer);
    }
    // Nothing left for a sleep timer to stop
    if (_handles.isEmpty) _cancelSleep(restore: false);
    _onHandlesUpdated(); // may end session if last track
  }

  /// Starts a sound looping, fading in to its stored volume.
  Future<void> _startTrack(String id) async {
    if (_handles.containsKey(id) || _loading.contains(id)) return;
    if (_audio && _sources[id] == null) return;

    // If a fade-out is still in progress for this track, cancel it by
    // stopping the old handle immediately so the new play starts clean.
    final old = _fadingOut.remove(id);
    if (old != null) _slStop(old);

    // Adding a sound to a paused mix resumes the whole mix
    if (_paused) _setPaused(false);

    // Default volume = 50 on first play
    _volumes.putIfAbsent(id, () => 50.0);

    setState(() => _loading.add(id));
    try {
      final handle = await _slPlay(id);
      if (!mounted) {
        _slStop(handle); // Widget disposed before play completed
        return;
      }
      _slFade(handle, _volumes[id]! / 50.0, _fadeDuration); // 50 → 1.0, 100 → 2.0
      if (_paused) _slPause(handle, true);
      if (_sleepFading) _fadeForSleep(handle);
      setState(() {
        _handles[id] = handle;
        _loading.remove(id);
      });
      _onHandlesUpdated(); // may start session if first track
    } catch (_) {
      if (mounted) setState(() => _loading.remove(id));
    }
  }

  void _setVolume(String trackId, double value) {
    setState(() => _volumes[trackId] = value);
    final handle = _handles[trackId];
    if (handle == null) return;
    _slSetVolume(handle, value / 50.0);
    // setVolume cancels SoLoud's fader, so keep the sleep fade going
    if (_sleepFading) _fadeForSleep(handle);
    _scheduleLastMixSave();
  }

  /// Pauses or resumes every sound in the mix.
  void _setPaused(bool paused) {
    if (_paused == paused || (paused && _handles.isEmpty)) return;
    final gen = ++_pauseGen;
    if (paused) {
      // Fade everything out, then pause once it's silent. Sounds already
      // fading out of the mix are left to finish on their own.
      final handles = _handles.values.toList();
      for (final h in handles) {
        _slFade(h, 0.0, _pauseFade);
      }
      late final Timer timer;
      timer = Timer(_pauseFade, () {
        _pendingStops.remove(timer);
        if (gen != _pauseGen) return; // resumed or stopped meanwhile
        for (final h in handles) {
          _slPause(h, true);
        }
      });
      _pendingStops.add(timer);
    } else {
      // Unpause silent (or mid fade-out) and fade back up to each volume.
      for (final e in _handles.entries) {
        _slPause(e.value, false);
        if (_sleepFading) {
          _fadeForSleep(e.value);
        } else {
          _slFade(e.value, (_volumes[e.key] ?? 50) / 50.0, _pauseFade);
        }
      }
    }
    if (paused) {
      final start = _segmentStart;
      if (start != null) {
        _sessionSecs += DateTime.now().difference(start).inSeconds;
        _segmentStart = null;
      }
    } else if (_sessionActive) {
      _segmentStart = DateTime.now();
    }
    setState(() => _paused = paused);
    _showOrUpdateNotification();
  }

  void _stopAll({bool notify = true, bool keepSleep = false}) {
    final wasPaused = _paused;
    _pauseGen++; // a pending pause no longer applies
    for (final handle in [..._handles.values, ..._fadingOut.values]) {
      // Fade out unless the screen is closing (its sources are disposed
      // right after) or the mix is paused (a paused sound never fades).
      if (notify && !wasPaused) {
        _slFadeStop(handle, _fadeDuration);
      } else {
        _slStop(handle);
      }
    }
    if (!keepSleep) _cancelSleep(restore: false, notify: notify);
    if (notify && mounted) {
      setState(() {
        _handles.clear();
        _fadingOut.clear();
        _paused = false;
      });
      _onHandlesUpdated(); // ends session if one was active
    } else {
      _handles.clear();
      _fadingOut.clear();
      _paused = false;
      // dispose() will call _recordElapsed() before this path
    }
  }

  // ── Sleep timer ──────────────────────────────────────────────────────────

  Future<void> _loadSleepPrefs() async {
    try {
      final fade = await ClipRepository.getString('zen_sleep_fade');
      final mins = int.tryParse(await ClipRepository.getString('zen_sleep_minutes') ?? '');
      if (!mounted) return;
      setState(() {
        if (fade != null) _sleepFadeEnabled = fade != '0';
        if (mins != null && _sleepChoices.contains(mins)) _sleepMinutes = mins;
      });
    } catch (_) {}
  }

  void _persistSleepPrefs() {
    if (!_audio) return;
    ClipRepository.setString('zen_sleep_fade', _sleepFadeEnabled ? '1' : '0')
        .catchError((_) {});
    ClipRepository.setString('zen_sleep_minutes', '$_sleepMinutes')
        .catchError((_) {});
  }

  void _startSleep(int minutes) {
    if (_handles.isEmpty) return; // nothing to put to sleep
    _cancelSleep(notify: false); // restores volumes if a fade had begun
    _sleepMinutes = minutes;
    _persistSleepPrefs();
    _sleepTotal = Duration(minutes: minutes);
    _sleepEnd = DateTime.now().add(_sleepTotal);
    _sleepLeft.value = _sleepTotal;
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sleepTick());
    setState(() {});
    _showOrUpdateNotification();
  }

  void _cancelSleep({bool restore = true, bool notify = true}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (_sleepFading && restore) {
      for (final e in _handles.entries) {
        _slFade(e.value, (_volumes[e.key] ?? 50) / 50.0, _fadeDuration);
      }
    }
    _sleepFading = false;
    if (_sleepEnd == null) return;
    _sleepEnd = null;
    _sleepLeft.value = null;
    if (notify && mounted) {
      setState(() {});
      _showOrUpdateNotification();
    }
  }

  void _sleepTick() {
    final end = _sleepEnd;
    if (end == null) return;
    final left = end.difference(DateTime.now());
    if (left <= Duration.zero) {
      _stopAll(); // also cancels the timer
      return;
    }
    // Round up so a fresh 30 min timer reads 30:00, not 29:59
    _sleepLeft.value = Duration(seconds: (left.inMilliseconds / 1000).ceil());
    if (_sleepFadeEnabled && !_sleepFading && left <= _sleepFadeTime) {
      _sleepFading = true;
      for (final h in _handles.values) {
        _slFade(h, 0.0, left);
      }
    }
  }

  /// Points [h] at silence by the time the sleep timer ends.
  void _fadeForSleep(SoundHandle h) {
    final end = _sleepEnd;
    if (end == null) return;
    var left = end.difference(DateTime.now());
    if (left < _fadeDuration) left = _fadeDuration;
    _slFade(h, 0.0, left);
  }

  void _setSleepFade(bool enabled) {
    if (!enabled && _sleepFading) {
      for (final e in _handles.entries) {
        _slFade(e.value, (_volumes[e.key] ?? 50) / 50.0, _fadeDuration);
      }
      _sleepFading = false;
    }
    setState(() => _sleepFadeEnabled = enabled);
    _persistSleepPrefs();
  }

  // ── Last mix (offered by the Tools tab) ─────────────────────────────────

  ZenLastMix _currentMix() => ZenLastMix(
        presetName: _currentPreset?.name,
        tracks: [
          for (final t in _playingTracks)
            ZenMixTrack(
              id: t.id,
              name: t.name,
              emoji: t.emoji,
              volume: _volumes[t.id] ?? 50.0,
            ),
        ],
      );

  void _scheduleLastMixSave() {
    if (!_audio) return;
    _lastMixTimer?.cancel();
    _lastMixTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) ZenLastMix.save(_currentMix());
    });
  }

  Future<void> _resumeLastMix() async {
    final mix = await ZenLastMix.load();
    if (mix == null || !mounted || _handles.isNotEmpty) return;
    final ids = [
      for (final t in mix.tracks)
        if (_available.contains(t.id)) t.id,
    ];
    if (ids.isEmpty) return;
    for (final t in mix.tracks) {
      _volumes[t.id] = t.volume.clamp(1.0, 100.0);
    }
    final name = mix.presetName;
    if (name != null) {
      for (final p in _presets) {
        if (p.name == name) _selectedPresetId = p.id;
      }
    }
    await Future.wait(ids.map(_startTrack));
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
    if (!_audio) return;
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
        if (mounted) {
          // Keep a session that started while the file was loading
          if (_sessionActive) s.sessionsCount += _stats.sessionsCount;
          setState(() => _stats = s);
        }
      }
    } catch (_) {}
  }

  Future<void> _persistStats() async {
    if (!_audio) return;
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
          style: TextStyle(color: c.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              setState(() => _stats = _ZenStats());
              _persistStats();
              Navigator.pop(ctx);             // close confirm dialog
              Navigator.pop(sheetContext);    // close info sheet
            },
            child: const Text('Clear', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// Called whenever _handles changes (track added or removed).
  void _onHandlesUpdated() {
    if (_handles.isNotEmpty) {
      if (!_sessionActive) {
        // First track — session starts
        _sessionActive = true;
        _sessionSecs = 0;
        _segmentStart = _paused ? null : DateTime.now();
        _stats.sessionsCount++;
        // Refresh the notification every minute so elapsed time stays current
        _notifTimer?.cancel();
        if (_audio) {
          _notifTimer = Timer.periodic(const Duration(minutes: 1), (_) {
            _showOrUpdateNotification();
          });
        }
      }
      // Show or refresh the notification with the current track list
      _showOrUpdateNotification();
    } else if (_sessionActive) {
      _notifTimer?.cancel();
      _notifTimer = null;
      _recordElapsed();
      _cancelNotification();
      if (mounted) setState(() {}); // refresh any stat display
    }
    _scheduleLastMixSave();
  }

  /// Flush played time to stats. Safe to call at any time; no-op if idle.
  void _recordElapsed() {
    if (!_sessionActive) return;
    final secs = _sessionElapsed.inSeconds;
    _sessionActive = false;
    _segmentStart = null;
    _sessionSecs = 0;
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

  // ── Presets ──────────────────────────────────────────────────────────────

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
    setState(() {
      _presets.add(preset);
      _selectedPresetId = preset.id;
    });
    _persistPresets();
    _scheduleLastMixSave();
  }

  Future<void> _activatePreset(_ZenPreset preset) async {
    // Switching mixes keeps a running sleep timer
    _stopAll(keepSleep: true);
    _selectedPresetId = preset.id;
    // Apply preset volumes first so the fade-in picks them up
    for (final e in preset.volumes.entries) {
      _volumes[e.key] = e.value;
    }
    // Start all preset tracks concurrently
    await Future.wait(
      preset.volumes.keys.where(_available.contains).map(_startTrack),
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
          style: TextStyle(color: c.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _presets.removeWhere((p) => p.id == preset.id);
                if (_selectedPresetId == preset.id) _selectedPresetId = null;
              });
              _persistPresets();
              Navigator.pop(ctx);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700)),
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
            style: TextStyle(color: c.textSecondary, fontSize: 14, height: 1.5),
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

    final playing = _playingTracks;
    if (playing.isEmpty) return;
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
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
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
    if (_handles.isEmpty || _handles.length != preset.volumes.length) return false;
    return _handles.keys.every((id) => preset.volumes.containsKey(id));
  }

  /// The saved mix the current sounds came from: the chip last tapped if the
  /// playing set still matches it, else any preset with the same sounds.
  _ZenPreset? get _currentPreset {
    for (final p in _presets) {
      if (p.id == _selectedPresetId && _isActivePreset(p)) return p;
    }
    for (final p in _presets) {
      if (_isActivePreset(p)) return p;
    }
    return null;
  }

  // ── Sheets ───────────────────────────────────────────────────────────────

  Future<void> _showZenSheet(WidgetBuilder builder) {
    final c = Theme.of(context).extension<AppColors>()!;
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.surfaceCard,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: builder,
    );
  }

  void _openMixer() {
    if (_handles.isEmpty) return;
    _showZenSheet((_) => _MixerSheet(host: this));
  }

  void _openSleep() {
    if (_handles.isEmpty) return;
    _showZenSheet((_) => _SleepSheet(host: this));
  }

  void _showVolumeSheet(BuildContext context, _ZenTrack track) {
    _showZenSheet((ctx) => ValueListenableBuilder<int>(
          valueListenable: _rev,
          builder: (ctx, _, _) {
            final c = Theme.of(ctx).extension<AppColors>()!;
            final z = ZenPalette.of(ctx);
            final vol = _volumes[track.id] ?? 50.0;
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _SheetHandle(),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        _EmojiBadge(emoji: track.emoji),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(track.name,
                                  style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700)),
                              Text(track.description,
                                  style: TextStyle(color: c.textSecondary, fontSize: 13)),
                            ],
                          ),
                        ),
                        Text(
                          '${vol.round()}%',
                          style: TextStyle(
                            color: z.teal,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Icon(Icons.volume_down_rounded, color: c.iconSecondary, size: 20),
                        Expanded(
                          child: _ZenSlider(
                            label: '${track.name} volume',
                            value: vol,
                            onChanged: (v) => _setVolume(track.id, v),
                          ),
                        ),
                        Icon(Icons.volume_up_rounded, color: c.iconSecondary, size: 20),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('Default is 50%',
                        style: TextStyle(color: c.textSecondary, fontSize: 12)),
                  ],
                ),
              ),
            );
          },
        ));
  }

  void _showInfoSheet(BuildContext context, AppColors c, Color accent) {
    _showZenSheet((sheetCtx) => _ZenInfoSheet(
          colors: c,
          accent: accent,
          stats: _stats,
          onClearStats: () => _clearStats(sheetCtx),
        ));
  }

  // ── Build ────────────────────────────────────────────────────────────────

  static const _kHint = 'Tap a sound to play it · hold a playing one for volume';

  Widget _buildHeader(AppColors c, Color accent) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: _scrolledUnder ? c.borderSubtle : Colors.transparent,
          ),
        ),
      ),
      child: Row(
        children: [
          ZenHeaderButton(
            icon: Icons.chevron_left_rounded,
            tooltip: 'Back',
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Zen Mode',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (!_isProbing)
            ZenHeaderButton(
              icon: Icons.info_outline_rounded,
              tooltip: 'About Zen Mode and your stats',
              onPressed: () => _showInfoSheet(context, c, accent),
            ),
        ],
      ),
    );
  }

  Widget _buildLoading(AppColors c, ZenPalette z) {
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(c, z.teal),
            Expanded(
              child: Center(
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
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Loading ambient sounds…',
                        style: TextStyle(color: c.textSecondary, fontSize: 14),
                      ),
                      const SizedBox(height: 32),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _tracks.isEmpty ? 0 : _probeCount / _tracks.length,
                          minHeight: 5,
                          backgroundColor: z.tint(0.14),
                          valueColor: AlwaysStoppedAnimation(z.teal),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '$_probeCount of ${_tracks.length}',
                        style: TextStyle(color: c.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Dock height above the bottom inset, for the grid's bottom padding:
  // 12 + handle 4 + 12 + label 20 + 14 + buttons 60 + 22.
  static const _kDockHeight = 144.0;

  Widget _buildDock(AppColors c, ZenPalette z, double bottomInset) {
    final names = _dockTracks.map((t) => '${t.emoji} ${t.name}').join('  ·  ');
    final label = _paused ? 'Paused  ·  $names' : names;
    final labelStyle = TextStyle(
      color: c.textPrimary,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    );
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(top: BorderSide(color: c.border)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: z.isDark ? 0.35 : 0.06),
            blurRadius: z.isDark ? 30 : 18,
            offset: Offset(0, z.isDark ? -12 : -4),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(16, 0, 16, 22 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle + now-playing line: tap or swipe up for the mixer
          Semantics(
            button: true,
            label: 'Now playing: $names. Open mixer',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openMixer,
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -150) _openMixer();
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  children: [
                    const _SheetHandle(),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 20,
                      child: Row(
                        children: [
                          ZenPulsingDot(animate: !_paused),
                          const SizedBox(width: 6),
                          Expanded(
                            child: _dockTracks.length > 2
                                ? _MarqueeText(text: label, style: labelStyle)
                                : Text(label,
                                    style: labelStyle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _TransportRow(host: this, onSleep: _openSleep, onMixer: _openMixer),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final z = ZenPalette.of(context);

    // ── Preload screen ────────────────────────────────────────────────────
    if (_isProbing) return _buildLoading(c, z);

    final playing = _playingTracks;
    if (playing.isNotEmpty) _dockTracks = playing;
    final dockVisible = playing.isNotEmpty;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final current = _currentPreset;

    // ── Main screen ───────────────────────────────────────────────────────
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                _buildHeader(c, z.teal),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      final under = n.depth == 0 && n.metrics.axis == Axis.vertical
                          ? n.metrics.pixels > 0.5
                          : _scrolledUnder;
                      if (under != _scrolledUnder) {
                        setState(() => _scrolledUnder = under);
                      }
                      return false;
                    },
                    child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                          child: Text(
                            _kHint,
                            style: TextStyle(color: c.textSecondary, fontSize: 13),
                          ),
                        ),
                      ),

                      // ── Save mix + saved mixes ──────────────────────────
                      if (_presets.isNotEmpty || playing.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _ChipRow(
                            top: 14,
                            children: [
                              if (playing.isNotEmpty)
                                _ZenChip(
                                  label: 'Save mix',
                                  icon: Icons.add_rounded,
                                  style: _ChipStyle.accent,
                                  onTap: () => _showSavePresetDialog(context, c, z.teal),
                                ),
                              for (final p in _presets)
                                _ZenChip(
                                  label: p.name,
                                  style: identical(p, current)
                                      ? _ChipStyle.selected
                                      : _ChipStyle.plain,
                                  onTap: () => _activatePreset(p),
                                  onLongPress: () => _deletePreset(p, context, c, z.teal),
                                ),
                            ],
                          ),
                        ),

                      // ── Grid ────────────────────────────────────────────
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          16,
                          16,
                          16,
                          (dockVisible ? _kDockHeight + 16 : 24) + bottomInset,
                        ),
                        sliver: SliverGrid(
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            mainAxisExtent: 128,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            childCount: _tracks.length,
                            (context, i) {
                              final track = _tracks[i];
                              final isPlaying = _handles.containsKey(track.id);
                              return _ZenTile(
                                track: track,
                                isAvailable: _available.contains(track.id),
                                isPlaying: isPlaying,
                                isPaused: _paused,
                                isLoading: _loading.contains(track.id),
                                colors: c,
                                onTap: () => _toggle(track),
                                onLongPress: isPlaying
                                    ? () => _showVolumeSheet(context, track)
                                    : null,
                                volume: _volumes[track.id] ?? 50.0,
                                tileIndex: i,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  ),
                ),
              ],
            ),
          ),

          // ── Now-playing dock ──────────────────────────────────────────────
          if (_dockTracks.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                ignoring: !dockVisible,
                child: AnimatedSlide(
                  offset: dockVisible ? Offset.zero : const Offset(0, 1.15),
                  duration: const Duration(milliseconds: 280),
                  curve: Curves.easeOutCubic,
                  child: _buildDock(c, z, bottomInset),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transport row — Pause/Play · Stop · Sleep pill · (Mixer)
// ---------------------------------------------------------------------------
class _TransportRow extends StatelessWidget {
  final _ZenScreenState host;
  final VoidCallback onSleep;
  final VoidCallback? onMixer;

  const _TransportRow({required this.host, required this.onSleep, this.onMixer});

  @override
  Widget build(BuildContext context) {
    final paused = host._paused;
    final hasMix = host._handles.isNotEmpty;
    return Row(
      children: [
        ZenRoundButton(
          primary: true,
          size: 60,
          iconSize: 30,
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          tooltip: paused ? 'Resume all' : 'Pause all',
          onPressed: hasMix ? () => host._setPaused(!paused) : null,
        ),
        const SizedBox(width: 10),
        ZenRoundButton(
          icon: Icons.stop_rounded,
          tooltip: 'Stop all',
          onPressed: hasMix ? host._stopAll : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ValueListenableBuilder<Duration?>(
            valueListenable: host._sleepLeft,
            builder: (context, left, _) =>
                ZenSleepPill(remaining: left, onPressed: onSleep),
          ),
        ),
        if (onMixer != null) ...[
          const SizedBox(width: 10),
          ZenRoundButton(
            icon: Icons.tune_rounded,
            iconSize: 20,
            tooltip: 'Open mixer',
            onPressed: onMixer,
          ),
        ],
      ],
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: c.handleBar,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Emoji in a 44px teal-tinted rounded square.
class _EmojiBadge extends StatelessWidget {
  final String emoji;
  const _EmojiBadge({required this.emoji});

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: z.tint(0.14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(emoji, style: const TextStyle(fontSize: 24, height: 1)),
    );
  }
}

class _ZenSlider extends StatelessWidget {
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _ZenSlider({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: z.teal,
        inactiveTrackColor: z.tint(0.20),
        thumbColor: z.teal,
        overlayColor: z.tint(0.14),
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(
            enabledThumbRadius: 8, elevation: 0, pressedElevation: 0),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        showValueIndicator: ShowValueIndicator.never,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Semantics(
        label: label,
        child: Slider(
          value: value.clamp(1.0, 100.0),
          min: 1,
          max: 100,
          divisions: 99,
          semanticFormatterCallback: (v) => '${v.round()}%',
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mixer sheet (5b)
// ---------------------------------------------------------------------------
class _MixerSheet extends StatefulWidget {
  final _ZenScreenState host;
  const _MixerSheet({required this.host});

  @override
  State<_MixerSheet> createState() => _MixerSheetState();
}

class _MixerSheetState extends State<_MixerSheet> {
  bool _closing = false;

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    return ValueListenableBuilder<int>(
      valueListenable: host._rev,
      builder: (context, _, _) {
        final c = Theme.of(context).extension<AppColors>()!;
        final z = ZenPalette.of(context);
        final playing = host._playingTracks;
        if (playing.isEmpty && !_closing) {
          // Everything was stopped (here, from the notification or the timer)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _close();
          });
        }
        final mixName = host._currentPreset?.name ?? 'Your mix';
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SheetHandle(),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'NOW PLAYING',
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.4,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                mixName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 22,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        _ZenChip(
                          label: 'Save mix',
                          style: _ChipStyle.accent,
                          height: 40,
                          onTap: () =>
                              host._showSavePresetDialog(context, c, z.teal),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: playing.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final t = playing[i];
                        return _MixerRow(
                          key: ValueKey(t.id),
                          track: t,
                          volume: host._volumes[t.id] ?? 50.0,
                          onChanged: (v) => host._setVolume(t.id, v),
                          onRemove: () => host._stopTrack(t.id),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  ZenDashedButton(
                    label: 'Add a sound from the grid',
                    onPressed: _close,
                  ),
                  const SizedBox(height: 20),
                  _TransportRow(
                    host: host,
                    onSleep: () {
                      _close();
                      host._openSleep();
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MixerRow extends StatelessWidget {
  final _ZenTrack track;
  final double volume;
  final ValueChanged<double> onChanged;
  final VoidCallback onRemove;

  const _MixerRow({
    super.key,
    required this.track,
    required this.volume,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final z = ZenPalette.of(context);
    return Container(
      height: 66,
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
      decoration: BoxDecoration(
        color: z.activeBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: z.tint(0.28)),
      ),
      child: Row(
        children: [
          _EmojiBadge(emoji: track.emoji),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        track.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${volume.round()}%',
                      style: TextStyle(
                        color: z.teal,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: 24,
                  child: _ZenSlider(
                    label: '${track.name} volume',
                    value: volume,
                    onChanged: onChanged,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove ${track.name}',
            onPressed: onRemove,
            icon: Icon(Icons.close_rounded, size: 18, color: c.textSecondary),
            style: IconButton.styleFrom(
              fixedSize: const Size(44, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sleep timer sheet (5c)
// ---------------------------------------------------------------------------
class _SleepSheet extends StatefulWidget {
  final _ZenScreenState host;
  const _SleepSheet({required this.host});

  @override
  State<_SleepSheet> createState() => _SleepSheetState();
}

class _SleepSheetState extends State<_SleepSheet> {
  late int _sel = widget.host._sleepEnd != null
      ? widget.host._sleepTotal.inMinutes
      : widget.host._sleepMinutes;
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final host = widget.host;
    return ListenableBuilder(
      listenable: Listenable.merge([host._rev, host._sleepLeft]),
      builder: (context, _) {
        final c = Theme.of(context).extension<AppColors>()!;
        final z = ZenPalette.of(context);
        if (host._handles.isEmpty && !_closing) {
          // The mix was stopped (timer ran out, notification, …)
          _closing = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop();
          });
        }
        final running = host._sleepEnd != null;
        final left = host._sleepLeft.value ?? Duration(minutes: _sel);
        final shown = running ? left : Duration(minutes: _sel);
        final end = running ? host._sleepEnd! : DateTime.now().add(shown);
        final progress = running && host._sleepTotal.inSeconds > 0
            ? left.inSeconds / host._sleepTotal.inSeconds
            : 1.0;
        final choice = zenMinutesLabel(_sel);

        Widget choiceRow(List<int> mins) => Row(
              children: [
                for (var i = 0; i < mins.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: ZenChoiceButton(
                      label: zenMinutesLabel(mins[i]),
                      selected: mins[i] == _sel,
                      onPressed: () => setState(() => _sel = mins[i]),
                    ),
                  ),
                ],
              ],
            );

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.92,
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _SheetHandle(),
                  const SizedBox(height: 18),
                  Text(
                    'Sleep timer',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Your mix fades out and stops on its own.',
                    style: TextStyle(color: c.textSecondary, fontSize: 14),
                  ),
                  const SizedBox(height: 22),
                  Center(
                    child: ZenSleepRing(
                      progress: progress,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.bedtime_outlined, size: 22, color: z.teal),
                          const SizedBox(height: 4),
                          Text(
                            zenClock(shown),
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: shown.inHours > 0 ? 40 : 46,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -1,
                              height: 1.1,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          Text(
                            'stops at ${host._fmtTimeOfDay(end)}',
                            style: TextStyle(color: c.textSecondary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Semantics(
                    container: true,
                    label: 'Timer length',
                    child: Column(
                      children: [
                        choiceRow(_ZenScreenState._sleepChoices.sublist(0, 3)),
                        const SizedBox(height: 8),
                        choiceRow(_ZenScreenState._sleepChoices.sublist(3)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  MergeSemantics(
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                      decoration: BoxDecoration(
                        color: z.buttonBg,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: z.buttonBorder),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Fade out gently',
                                    style: TextStyle(
                                        color: c.textPrimary,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500)),
                                Text('Lowers the volume over the last minute',
                                    style: TextStyle(
                                        color: c.textSecondary, fontSize: 12.5)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: host._sleepFadeEnabled,
                            onChanged: host._setSleepFade,
                            activeThumbColor: z.onTeal,
                            activeTrackColor: z.teal,
                            inactiveThumbColor: c.iconSecondary,
                            inactiveTrackColor: c.surfaceCard,
                            trackOutlineColor: WidgetStateProperty.resolveWith(
                              (s) => s.contains(WidgetState.selected)
                                  ? Colors.transparent
                                  : c.border,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            if (running) host._cancelSleep();
                            Navigator.of(context).pop();
                          },
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            foregroundColor: c.textPrimary,
                            side: BorderSide(color: c.border),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18)),
                            textStyle: _buttonText(context, FontWeight.w700),
                          ),
                          child: Text(running ? 'Turn off' : 'Cancel', maxLines: 1, softWrap: false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed: () {
                            host._startSleep(_sel);
                            Navigator.of(context).pop();
                          },
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                            backgroundColor: z.teal,
                            foregroundColor: z.onTeal,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18)),
                            textStyle: _buttonText(context, FontWeight.w800),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(!running
                                ? 'Start $choice timer'
                                : _sel == host._sleepTotal.inMinutes
                                    ? 'Restart $choice timer'
                                    : 'Update to $choice'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Button label style that keeps the app font (a bare TextStyle would drop it).
TextStyle _buttonText(BuildContext context, FontWeight weight) =>
    (Theme.of(context).textTheme.labelLarge ?? const TextStyle())
        .copyWith(fontSize: 15, fontWeight: weight);

// ---------------------------------------------------------------------------
// Chips above the grid
// ---------------------------------------------------------------------------
enum _ChipStyle { plain, selected, accent }

class _ChipRow extends StatelessWidget {
  final double top;
  final List<Widget> children;
  const _ChipRow({required this.top, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) => Center(child: children[i]),
        ),
      ),
    );
  }
}

class _ZenChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final _ChipStyle style;
  final double height;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ZenChip({
    required this.label,
    required this.style,
    required this.onTap,
    this.icon,
    this.onLongPress,
    this.height = 36,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final z = ZenPalette.of(context);
    final (bg, border, fg) = switch (style) {
      _ChipStyle.accent => (z.tint(0.10), BorderSide(color: z.tint(0.45)), z.teal),
      _ChipStyle.selected =>
        (z.tint(0.14), BorderSide(color: z.tint(0.6), width: 1.5), c.textPrimary),
      _ChipStyle.plain => (c.surfaceCard, BorderSide(color: c.border), c.textSecondary),
    };
    return Semantics(
      button: true,
      selected: style == _ChipStyle.selected,
      child: Material(
        color: bg,
        shape: StadiumBorder(side: border),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 17, color: fg),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: style == _ChipStyle.plain
                          ? FontWeight.w500
                          : FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sound tile
// ---------------------------------------------------------------------------
class _ZenTile extends StatefulWidget {
  final _ZenTrack track;
  final bool isAvailable;
  final bool isPlaying;
  final bool isPaused;
  final bool isLoading;
  final AppColors colors;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double volume;   // 1–100
  final int tileIndex;

  const _ZenTile({
    required this.track,
    required this.isAvailable,
    required this.isPlaying,
    required this.isPaused,
    required this.isLoading,
    required this.colors,
    required this.onTap,
    required this.onLongPress,
    required this.volume,
    required this.tileIndex,
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

  bool get _shimmering => widget.isPlaying && !widget.isPaused;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    _shimmerAnim = _tween.animate(_ctrl);
    if (_shimmering) _startShimmer();
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
    final was = old.isPlaying && !old.isPaused;
    if (_shimmering == was) return;
    if (_shimmering) {
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

  @override
  Widget build(BuildContext context) {
    final z = ZenPalette.of(context);
    final c = widget.colors;
    final on = widget.isPlaying;
    final dim = !widget.isAvailable;
    final t = widget.track;

    final content = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Opacity(
                opacity: dim ? 0.45 : 1,
                child: Text(t.emoji, style: const TextStyle(fontSize: 34, height: 1.05)),
              ),
              const Spacer(),
              if (widget.isLoading)
                Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(z.teal),
                    ),
                  ),
                ),
            ],
          ),
          const Spacer(),
          Text(
            t.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: dim ? c.textSecondary : on ? z.teal : c.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            t.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textSecondary, fontSize: 12, height: 1.25),
          ),
          if (on) const SizedBox(height: 4),
        ],
      ),
    );

    return Semantics(
      button: true,
      toggled: on,
      enabled: widget.isAvailable,
      label: dim ? '${t.name}, coming soon' : '${t.name}, ${t.description}',
      value: on ? 'Volume ${widget.volume.round()}%' : null,
      onLongPressHint: widget.onLongPress != null ? 'Adjust volume' : null,
      child: GestureDetector(
        onTap: widget.isAvailable && !widget.isLoading ? widget.onTap : null,
        onLongPress: widget.onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: on ? z.activeBg : c.surfaceCard,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: on ? z.tint(0.6) : c.border,
              width: on ? 1.5 : 1.0,
            ),
            boxShadow: on
                ? [BoxShadow(color: z.tint(z.isDark ? 0.16 : 0.18), blurRadius: 22)]
                : const [],
          ),
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              fit: StackFit.expand,
              children: [
                content,
                if (_shimmering)
                  AnimatedBuilder(
                    animation: _shimmerAnim,
                    builder: (context, _) => _ShimmerOverlay(
                      t: _shimmerAnim.value,
                      accent: z.teal,
                      tileWidth: box.maxWidth,
                      tileHeight: box.maxHeight,
                    ),
                  ),

                // Thin volume bar along the bottom while playing
                if (on)
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 8,
                    child: Container(
                      height: 3,
                      alignment: Alignment.centerLeft,
                      decoration: BoxDecoration(
                        color: z.tint(0.18),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: FractionallySizedBox(
                        widthFactor: (widget.volume / 100).clamp(0.0, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: widget.isPaused ? z.tint(0.5) : z.teal,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),

                if (!widget.isAvailable)
                  // Coming soon badge
                  Positioned(
                    top: 14,
                    right: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: c.surfaceElevated,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'Soon',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
        borderRadius: BorderRadius.circular(21),
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
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24, 10, 24,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
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
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Your ambient soundscape',
                      style: TextStyle(color: colors.textSecondary, fontSize: 13),
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
                border: Border.all(color: accent.withValues(alpha: 0.2)),
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
              body: 'Hold any playing tile — or open the mixer from the bar at the '
                  'bottom — to set each sound\'s volume from 1 to 100. Default is 50.',
              colors: colors,
              accent: accent,
            ),
            _InfoItem(
              emoji: '⏯️',
              title: 'Pause & stop',
              body: 'Pause holds every sound where it is; tap play to carry on. '
                  'Stop clears the whole mix at once.',
              colors: colors,
              accent: accent,
            ),
            _InfoItem(
              emoji: '🌙',
              title: 'Sleep timer',
              body: 'Tap the moon button to stop the mix after 15 minutes to 2 hours. '
                  'With "Fade out gently" on, it softens over the last minute.',
              colors: colors,
              accent: accent,
            ),
            _InfoItem(
              emoji: '🔖',
              title: 'Save a mix',
              body: 'When sounds are playing, tap "Save mix" above the grid or in the '
                  'mixer to name and save your current combination. Your mixes are '
                  'stored and persist between sessions.',
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
              isLast: true,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
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
                Icon(Icons.bar_chart_rounded, size: 16, color: colors.textSecondary),
                const SizedBox(width: 8),
                Text(
                  'Start listening to see your stats here.',
                  style: TextStyle(color: colors.textSecondary, fontSize: 13),
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
            style: TextStyle(color: colors.textSecondary, fontSize: 11, fontWeight: FontWeight.w500),
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
                    color: colors.textSecondary,
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
