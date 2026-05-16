import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show lerpDouble;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter/foundation.dart' show consolidateHttpClientResponseBytes;
import 'package:path_provider/path_provider.dart';
import '../data/sounds_data.dart';
import '../models/scene_model.dart';
import '../models/sound_model.dart';
import '../services/clip_repository.dart';
import '../services/notification_service.dart';
import '../widgets/sound_button.dart';
import 'clip_editor_screen.dart';
import 'morse_screen.dart';
import 'morse_soundr_screen.dart';
import 'record_screen.dart';

class SoundboardScreen extends StatefulWidget {
  const SoundboardScreen({super.key});

  @override
  State<SoundboardScreen> createState() => _SoundboardScreenState();
}

class _SoundboardScreenState extends State<SoundboardScreen> {
  final Map<String, AudioSource> _preloaded = {};
  final Map<String, double> _durations = {};
  final List<SoundHandle> _activeHandles = [];

  List<SoundModel> _userClips = [];
  String _selectedCategory = 'All';
  bool _ready = false;
  int _stopSignal = 0;
  int _stopOthersSignal = 0;
  String? _stopOnTapExcludeId;
  int _loadedCount = 0;
  int _totalCount = 0;

  // Stop-on-tap
  bool _stopOnTap = false;
  bool _stopOnTapExpanded = false;
  Timer? _stopOnTapTimer;

  // Search
  bool _isSearching = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  // Favorites
  Set<String> _favorites = {};

  // Play counts (in-memory, persisted to DB)
  Map<String, int> _playCounts = {};

  // Recently played (in-memory, newest first)
  final List<SoundModel> _recentlyPlayed = [];

  // Scenes / boards
  List<SceneModel> _scenes = [];
  Map<String, Set<String>> _sceneSoundIds = {}; // sceneId → sound IDs in scene

  // Back-button guard
  DateTime? _lastBackPress;

  // ── Data ──────────────────────────────────────────────────────────────────

  List<SoundModel> get _allSounds => [...SoundsData.all, ..._userClips];

  List<String> get _categories {
    final cats = <String>['All'];
    if (_favorites.isNotEmpty) cats.add('Favorites');
    // Scenes appear right after Favorites
    for (final s in _scenes) { cats.add('scene:${s.id}'); }
    cats.add('__new_scene__'); // "New board" chip
    cats.addAll(SoundsData.categories.where((c) => c != 'All'));
    if (_userClips.isNotEmpty && !cats.contains('My Clips')) cats.add('My Clips');
    return cats;
  }

  List<SoundModel> get _filtered {
    if (_isSearching && _searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      return _allSounds
          .where((s) =>
              s.name.toLowerCase().contains(q) ||
              s.category.toLowerCase().contains(q))
          .toList();
    }
    if (_selectedCategory.startsWith('scene:')) {
      final sceneId = _selectedCategory.substring(6);
      final ids = _sceneSoundIds[sceneId] ?? const {};
      return _allSounds.where((s) => ids.contains(s.id)).toList();
    }
    if (_selectedCategory == 'Favorites') {
      return _allSounds.where((s) => _favorites.contains(s.id)).toList();
    }
    if (_selectedCategory == 'All') return _allSounds;
    return _allSounds.where((s) => s.category == _selectedCategory).toList();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await NotificationService.init();
    await NotificationService.requestPermission();
    NotificationService.setStopCallback(_stopAll);
    NotificationService.setPlayCallback(_playById);
    await SoLoud.instance.init();
    await _loadUserClips();
    final sounds = _allSounds;
    if (mounted) setState(() { _totalCount = sounds.length; _loadedCount = 0; });
    await _preloadAll(sounds);
    _favorites = await ClipRepository.getFavorites();
    _playCounts = await ClipRepository.getPlayCounts();
    await _loadScenes();
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _loadUserClips() async {
    _userClips = await ClipRepository.getAll();
  }

  Future<void> _loadScenes() async {
    final scenes = await ClipRepository.getScenes();
    final ids = <String, Set<String>>{};
    for (final s in scenes) {
      ids[s.id] = await ClipRepository.getSceneSoundIds(s.id);
    }
    if (mounted) setState(() { _scenes = scenes; _sceneSoundIds = ids; });
  }

  Future<void> _preloadAll(List<SoundModel> sounds) async {
    final unloaded = sounds.where((s) => !_preloaded.containsKey(s.id)).toList();
    await Future.wait(
      unloaded.map((sound) async {
        try {
          final Uint8List bytes;
          if (sound.isUserClip && sound.filePath != null) {
            bytes = await File(sound.filePath!).readAsBytes();
          } else {
            final data = await rootBundle.load('assets/sounds/raw/${sound.file}');
            bytes = data.buffer.asUint8List();
          }
          final source = await SoLoud.instance.loadMem(sound.id, bytes);
          _preloaded[sound.id] = source;
          final totalDur = SoLoud.instance.getLength(source).inMilliseconds / 1000;
          _durations[sound.id] = (sound.isUserClip && sound.trimEnd > sound.trimStart)
              ? sound.trimEnd - sound.trimStart
              : totalDur;
        } catch (_) {}
        if (mounted) setState(() => _loadedCount++);
      }),
    );
  }

  @override
  void dispose() {
    _stopOnTapTimer?.cancel();
    _searchController.dispose();
    NotificationService.clearStopCallback();
    NotificationService.clearPlayCallback();
    SoLoud.instance.deinit();
    super.dispose();
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  Future<void> _play(SoundModel sound) async {
    final source = _preloaded[sound.id];
    if (source == null) return;

    if (_stopOnTap) {
      for (final h in _activeHandles.toList()) {
        if (SoLoud.instance.getIsValidVoiceHandle(h)) SoLoud.instance.stop(h);
      }
      _activeHandles.clear();
      // Signal all OTHER buttons to reset their play animation. The button
      // that triggered this play is excluded so its animation starts fresh.
      setState(() {
        _stopOthersSignal++;
        _stopOnTapExcludeId = sound.id;
      });
    }

    _addToRecent(sound);

    // Increment play count in memory + persist
    setState(() => _playCounts[sound.id] = (_playCounts[sound.id] ?? 0) + 1);
    ClipRepository.incrementPlayCount(sound.id);

    // Build quick-play list: top-2 favourites by play count, excluding this sound.
    final quickPlays = (_allSounds
          .where((s) => _favorites.contains(s.id) && s.id != sound.id)
          .toList()
          ..sort((a, b) =>
              (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0)))
        .take(2)
        .map((s) => (id: s.id, name: s.name))
        .toList();

    // Show notification
    NotificationService.showPlayingNotification(
      sound.name,
      quickPlays: quickPlays,
    );

    final handle = await SoLoud.instance.play(source);
    _activeHandles.add(handle);

    final durationMs = sound.isUserClip && sound.trimEnd > sound.trimStart
        ? ((sound.trimEnd - sound.trimStart) * 1000).round()
        : null;

    if (sound.isUserClip && sound.trimEnd > sound.trimStart) {
      SoLoud.instance.seek(
          handle, Duration(milliseconds: (sound.trimStart * 1000).round()));
    }

    final playDuration = durationMs ??
        (SoLoud.instance.getLength(source).inMilliseconds);

    Future.delayed(Duration(milliseconds: playDuration), () {
      if (SoLoud.instance.getIsValidVoiceHandle(handle)) {
        SoLoud.instance.stop(handle);
      }
      _activeHandles.remove(handle);
      if (_activeHandles.isEmpty) {
        NotificationService.hideNotification();
      }
    });
  }

  Future<void> _stopAll() async {
    for (final h in _activeHandles.toList()) {
      if (SoLoud.instance.getIsValidVoiceHandle(h)) await SoLoud.instance.stop(h);
    }
    _activeHandles.clear();
    NotificationService.hideNotification();
    if (mounted) setState(() => _stopSignal++);
  }

  /// Play a sound by its ID — used by the notification quick-play callback.
  Future<void> _playById(String id) async {
    final sounds = _allSounds;
    final idx = sounds.indexWhere((s) => s.id == id);
    if (idx == -1) return;
    await _play(sounds[idx]);
  }

  /// Play a random sound from the currently visible (filtered) list.
  void _playRandom() {
    final pool = _filtered;
    if (pool.isEmpty) return;
    HapticFeedback.mediumImpact();
    final sound = pool[Random().nextInt(pool.length)];
    _play(sound);
  }

  // ── Play-count management ─────────────────────────────────────────────────

  Future<void> _resetPlayCount(SoundModel sound) async {
    await ClipRepository.resetPlayCount(sound.id);
    setState(() => _playCounts.remove(sound.id));
  }

  Future<void> _resetAllPlayCounts() async {
    await ClipRepository.resetAllPlayCounts();
    setState(() => _playCounts.clear());
  }

  // ── Scenes / boards ───────────────────────────────────────────────────────

  static const _sceneEmojis = [
    '🎙️', '🎮', '🎵', '🔥', '😂', '🎬',
    '🎧', '🏆', '💀', '✨', '🎭', '🎤',
    '🐸', '🚀', '⚡', '🎪',
  ];

  void _showCreateSceneDialog() {
    String selectedEmoji = _sceneEmojis.first;
    final nameCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            left: 20, right: 20, top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('New Board', style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700,
              )),
              const SizedBox(height: 16),
              // Emoji picker
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _sceneEmojis.map((e) {
                  final sel = e == selectedEmoji;
                  return GestureDetector(
                    onTap: () => setSheetState(() => selectedEmoji = e),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: 42, height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sel
                            ? const Color(0xFF6C63FF).withValues(alpha: 0.22)
                            : const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: sel
                              ? const Color(0xFF6C63FF)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: const Color(0xFF6C63FF),
                decoration: const InputDecoration(
                  hintText: 'Board name…',
                  hintStyle: TextStyle(color: Colors.white38),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF6C63FF)),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    Navigator.pop(ctx);
                    final scene = await ClipRepository.createScene(
                        name, selectedEmoji);
                    setState(() {
                      _scenes.add(scene);
                      _sceneSoundIds[scene.id] = {};
                      _selectedCategory = 'scene:${scene.id}';
                    });
                  },
                  child: const Text('Create Board',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      )),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSceneOptions(SceneModel scene) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Text(scene.emoji, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Text(scene.name, style: const TextStyle(
                    color: Colors.white, fontSize: 17,
                    fontWeight: FontWeight.w600)),
              ]),
            ),
            const SizedBox(height: 16),
            const Divider(color: Colors.white12, height: 1),
            _SheetOption(
              icon: Icons.edit_rounded,
              label: 'Rename board',
              onTap: () { Navigator.pop(ctx); _showRenameSceneDialog(scene); },
            ),
            _SheetOption(
              icon: Icons.delete_outline_rounded,
              label: 'Delete board',
              color: Colors.redAccent,
              onTap: () { Navigator.pop(ctx); _deleteScene(scene); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showRenameSceneDialog(SceneModel scene) {
    String selectedEmoji = scene.emoji;
    final nameCtrl = TextEditingController(text: scene.name);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            left: 20, right: 20, top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24, borderRadius: BorderRadius.circular(2),
                ),
              )),
              const SizedBox(height: 20),
              const Text('Rename Board', style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700,
              )),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8, runSpacing: 8,
                children: _sceneEmojis.map((e) {
                  final sel = e == selectedEmoji;
                  return GestureDetector(
                    onTap: () => setSheetState(() => selectedEmoji = e),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: 42, height: 42,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: sel
                            ? const Color(0xFF6C63FF).withValues(alpha: 0.22)
                            : const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: sel
                              ? const Color(0xFF6C63FF)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Text(e, style: const TextStyle(fontSize: 22)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: const Color(0xFF6C63FF),
                decoration: const InputDecoration(
                  hintText: 'Board name…',
                  hintStyle: TextStyle(color: Colors.white38),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF6C63FF)),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  style: TextButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) return;
                    Navigator.pop(ctx);
                    final updated = scene.copyWith(
                        name: name, emoji: selectedEmoji);
                    await ClipRepository.updateScene(updated);
                    setState(() {
                      final idx = _scenes.indexWhere((s) => s.id == scene.id);
                      if (idx != -1) _scenes[idx] = updated;
                    });
                  },
                  child: const Text('Save', style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600,
                    fontSize: 15,
                  )),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteScene(SceneModel scene) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Delete board?',
            style: TextStyle(color: Colors.white)),
        content: Text(
          'This removes the board "${scene.name}" but won\'t delete the sounds.',
          style: const TextStyle(color: Colors.white60),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ClipRepository.deleteScene(scene.id);
    setState(() {
      _scenes.removeWhere((s) => s.id == scene.id);
      _sceneSoundIds.remove(scene.id);
      if (_selectedCategory == 'scene:${scene.id}') {
        _selectedCategory = 'All';
      }
    });
  }

  /// Shows a sheet for adding/removing the sound from any board.
  void _showManageBoardsSheet(SoundModel sound) {
    if (_scenes.isEmpty) {
      // No boards yet — jump straight to create
      _showCreateSceneDialog();
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(children: [
                  const Icon(Icons.dashboard_customize_rounded,
                      color: Color(0xFF6C63FF), size: 20),
                  const SizedBox(width: 10),
                  const Text('Manage Boards', style: TextStyle(
                    color: Colors.white, fontSize: 16,
                    fontWeight: FontWeight.w700,
                  )),
                ]),
              ),
              const SizedBox(height: 8),
              const Divider(color: Colors.white12, height: 1),
              ..._scenes.map((scene) {
                final inScene =
                    _sceneSoundIds[scene.id]?.contains(sound.id) ?? false;
                return InkWell(
                  onTap: () async {
                    if (inScene) {
                      await ClipRepository.removeSoundFromScene(
                          scene.id, sound.id);
                      setSheetState(() =>
                          _sceneSoundIds[scene.id]?.remove(sound.id));
                      setState(() =>
                          _sceneSoundIds[scene.id]?.remove(sound.id));
                    } else {
                      await ClipRepository.addSoundToScene(
                          scene.id, sound.id);
                      setSheetState(() =>
                          _sceneSoundIds[scene.id]?.add(sound.id));
                      setState(() =>
                          _sceneSoundIds[scene.id]?.add(sound.id));
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    child: Row(children: [
                      Text(scene.emoji,
                          style: const TextStyle(fontSize: 22)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(scene.name, style: const TextStyle(
                          color: Colors.white, fontSize: 15,
                          fontWeight: FontWeight.w500,
                        )),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          inScene
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          key: ValueKey(inScene),
                          color: inScene
                              ? const Color(0xFF6C63FF)
                              : Colors.white24,
                          size: 22,
                        ),
                      ),
                    ]),
                  ),
                );
              }),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ── URL Import (#14) ─────────────────────────────────────────────────────

  void _showImportOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Import Sound', style: TextStyle(
                  color: Colors.white, fontSize: 17,
                  fontWeight: FontWeight.w700,
                )),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(color: Colors.white12, height: 1),
            _SheetOption(
              icon: Icons.folder_open_rounded,
              label: 'From file',
              onTap: () { Navigator.pop(ctx); _importAudio(); },
            ),
            _SheetOption(
              icon: Icons.link_rounded,
              label: 'From URL',
              onTap: () { Navigator.pop(ctx); _importFromUrl(); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromUrl() async {
    final urlCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Import from URL',
            style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: urlCtrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          cursorColor: const Color(0xFF6C63FF),
          decoration: const InputDecoration(
            hintText: 'https://example.com/sound.mp3',
            hintStyle: TextStyle(color: Colors.white38, fontSize: 13),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF6C63FF)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download',
                style: TextStyle(
                    color: Color(0xFF6C63FF),
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final url = urlCtrl.text.trim();
    if (url.isEmpty) return;

    // Validate URL
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Invalid URL'),
          backgroundColor: Color(0xFF2A2A2A),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }

    // Show loading dialog
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        backgroundColor: Color(0xFF1A1A1A),
        content: Row(children: [
          CircularProgressIndicator(color: Color(0xFF6C63FF)),
          SizedBox(width: 20),
          Text('Downloading…', style: TextStyle(color: Colors.white)),
        ]),
      ),
    );

    String? filePath;
    try {
      final request = await HttpClient().getUrl(uri);
      final response = await request.close();
      if (response.statusCode == 200) {
        final bytes = await consolidateHttpClientResponseBytes(response);
        final ext = uri.path.split('.').last.split('?').first.toLowerCase();
        final dir = await getTemporaryDirectory();
        final name =
            'soundr_${DateTime.now().millisecondsSinceEpoch}.$ext';
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(bytes);
        filePath = file.path;
      }
    } catch (_) {}

    if (!mounted) return;
    Navigator.pop(context); // dismiss loading

    if (filePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Download failed — check the URL and try again'),
        backgroundColor: Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    final navigator = Navigator.of(context);
    final saved = await navigator
        .push<bool>(MaterialPageRoute(
          builder: (_) => ClipEditorScreen(filePath: filePath!),
        ));
    if (saved != true || !mounted) return;

    final updated = await ClipRepository.getAll();
    final newClips =
        updated.where((c) => !_preloaded.containsKey(c.id)).toList();
    await _preloadAll(newClips);
    setState(() => _userClips = updated);
  }

  // ── Stats ─────────────────────────────────────────────────────────────────

  void _showStats() {
    final totalPlays = _playCounts.values.fold(0, (a, b) => a + b);

    // Top 5 sounds by play count.
    final topSounds = _allSounds
        .where((s) => (_playCounts[s.id] ?? 0) > 0)
        .toList()
      ..sort((a, b) =>
          (_playCounts[b.id] ?? 0).compareTo(_playCounts[a.id] ?? 0));
    final top5 = topSounds.take(5).toList();

    // Most active category (by total plays).
    final catTotals = <String, int>{};
    for (final s in _allSounds) {
      final c = (_playCounts[s.id] ?? 0);
      if (c > 0) catTotals[s.category] = (catTotals[s.category] ?? 0) + c;
    }
    String? topCat;
    int topCatCount = 0;
    catTotals.forEach((cat, count) {
      if (count > topCatCount) { topCat = cat; topCatCount = count; }
    });

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 36, height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Title row
                Row(
                  children: [
                    const Icon(Icons.bar_chart_rounded,
                        color: Color(0xFF6C63FF), size: 22),
                    const SizedBox(width: 10),
                    const Text(
                      'Play Stats',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    if (totalPlays > 0)
                      GestureDetector(
                        onTap: () async {
                          Navigator.pop(ctx);
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              backgroundColor: const Color(0xFF1A1A1A),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18)),
                              title: const Text('Clear all stats?',
                                  style: TextStyle(color: Colors.white)),
                              content: const Text(
                                'This will reset play counts for every sound.',
                                style: TextStyle(color: Colors.white60),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(d, false),
                                  child: const Text('Cancel',
                                      style: TextStyle(color: Colors.white54)),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(d, true),
                                  child: const Text('Clear',
                                      style: TextStyle(color: Colors.redAccent)),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) _resetAllPlayCounts();
                        },
                        child: const Text(
                          'Clear all',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 20),

                // Summary cards
                Row(
                  children: [
                    _StatCard(
                      label: 'Total plays',
                      value: totalPlays >= 1000
                          ? '${(totalPlays / 1000).toStringAsFixed(1)}k'
                          : '$totalPlays',
                      icon: Icons.play_arrow_rounded,
                      color: const Color(0xFF6C63FF),
                    ),
                    const SizedBox(width: 10),
                    _StatCard(
                      label: 'Top category',
                      value: topCat ?? '—',
                      icon: Icons.category_rounded,
                      color: const Color(0xFF5DCAA5),
                    ),
                  ],
                ),

                if (top5.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'TOP SOUNDS',
                    style: TextStyle(
                      color: Colors.white24,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...top5.asMap().entries.map((e) {
                    final rank = e.key + 1;
                    final s = e.value;
                    final count = _playCounts[s.id] ?? 0;
                    final maxCount = _playCounts[top5.first.id] ?? 1;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 18,
                            child: Text(
                              '$rank',
                              style: TextStyle(
                                color: rank == 1
                                    ? Colors.amber
                                    : Colors.white.withValues(alpha: 0.25),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(s.emoji,
                              style: const TextStyle(fontSize: 18)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: count / maxCount,
                                    backgroundColor:
                                        Colors.white.withValues(alpha: 0.07),
                                    valueColor:
                                        const AlwaysStoppedAnimation(
                                            Color(0xFF6C63FF)),
                                    minHeight: 4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            count >= 1000
                                ? '${(count / 1000).toStringAsFixed(1)}k'
                                : '$count',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ] else ...[
                  const SizedBox(height: 32),
                  Center(
                    child: Column(
                      children: [
                        Icon(Icons.bar_chart_rounded,
                            size: 40,
                            color: Colors.white.withValues(alpha: 0.10)),
                        const SizedBox(height: 12),
                        const Text(
                          'No plays recorded yet',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Recently played ───────────────────────────────────────────────────────

  void _addToRecent(SoundModel sound) {
    setState(() {
      _recentlyPlayed.removeWhere((s) => s.id == sound.id);
      _recentlyPlayed.insert(0, sound);
      if (_recentlyPlayed.length > 8) _recentlyPlayed.removeRange(8, _recentlyPlayed.length);
    });
  }

  // ── Favorites ─────────────────────────────────────────────────────────────

  Future<void> _toggleFavorite(SoundModel sound) async {
    final wasFav = _favorites.contains(sound.id);
    setState(() {
      if (wasFav) {
        _favorites.remove(sound.id);
        if (_selectedCategory == 'Favorites' && _favorites.isEmpty) {
          _selectedCategory = 'All';
        }
      } else {
        _favorites.add(sound.id);
      }
    });
    if (wasFav) {
      await ClipRepository.removeFavorite(sound.id);
    } else {
      await ClipRepository.addFavorite(sound.id);
    }
  }

  // ── Stop-on-tap ───────────────────────────────────────────────────────────

  void _toggleStopOnTap() {
    _stopOnTapTimer?.cancel();
    if (_stopOnTap) {
      setState(() { _stopOnTap = false; _stopOnTapExpanded = false; });
    } else {
      setState(() { _stopOnTap = true; _stopOnTapExpanded = true; });
      _stopOnTapTimer = Timer(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _stopOnTapExpanded = false);
      });
    }
  }

  // ── Import ────────────────────────────────────────────────────────────────

  Future<void> _importAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'ogg', 'flac'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || !mounted) return;

    final navigator = Navigator.of(context);
    final saved = await navigator.push<bool>(
      MaterialPageRoute(builder: (_) => ClipEditorScreen(filePath: path)),
    );
    if (saved != true || !mounted) return;

    final updated = await ClipRepository.getAll();
    final newClips = updated.where((c) => !_preloaded.containsKey(c.id)).toList();
    await _preloadAll(newClips);
    setState(() => _userClips = updated);
  }

  // ── Recorder ──────────────────────────────────────────────────────────────

  Future<void> _openRecorder() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const RecordScreen()),
    );
    if (saved != true || !mounted) return;
    final updated = await ClipRepository.getAll();
    final newClips = updated.where((c) => !_preloaded.containsKey(c.id)).toList();
    await _preloadAll(newClips);
    setState(() => _userClips = updated);
  }

  // ── Clip management ───────────────────────────────────────────────────────

  /// Shared header used by both option sheets.
  Widget _buildSheetHeader(SoundModel sound) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 8),
      Container(
        width: 36, height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(children: [
          Text(sound.emoji, style: const TextStyle(fontSize: 28)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(sound.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      const Divider(color: Colors.white12, height: 1),
    ],
  );

  /// Options sheet for built-in sounds (favorite + boards + reset plays).
  Future<void> _showSoundOptions(SoundModel sound) async {
    final isFav = _favorites.contains(sound.id);
    final hasPlays = (_playCounts[sound.id] ?? 0) > 0;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSheetHeader(sound),
            _SheetOption(
              icon: isFav ? Icons.star_rounded : Icons.star_outline_rounded,
              label: isFav ? 'Remove from favorites' : 'Add to favorites',
              color: isFav ? Colors.amber : Colors.white,
              onTap: () { Navigator.pop(ctx); _toggleFavorite(sound); },
            ),
            _SheetOption(
              icon: Icons.dashboard_customize_rounded,
              label: 'Manage boards',
              onTap: () { Navigator.pop(ctx); _showManageBoardsSheet(sound); },
            ),
            if (hasPlays)
              _SheetOption(
                icon: Icons.refresh_rounded,
                label: 'Reset play count',
                color: Colors.white54,
                onTap: () { Navigator.pop(ctx); _resetPlayCount(sound); },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Options sheet for user clips (favorite + boards + reset plays + edit + color + share + delete).
  Future<void> _showClipOptions(SoundModel clip) async {
    final isFav = _favorites.contains(clip.id);
    final hasPlays = (_playCounts[clip.id] ?? 0) > 0;
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildSheetHeader(clip),
            _SheetOption(
              icon: isFav ? Icons.star_rounded : Icons.star_outline_rounded,
              label: isFav ? 'Remove from favorites' : 'Add to favorites',
              color: isFav ? Colors.amber : Colors.white,
              onTap: () { Navigator.pop(ctx); _toggleFavorite(clip); },
            ),
            _SheetOption(
              icon: Icons.dashboard_customize_rounded,
              label: 'Manage boards',
              onTap: () { Navigator.pop(ctx); _showManageBoardsSheet(clip); },
            ),
            if (hasPlays)
              _SheetOption(
                icon: Icons.refresh_rounded,
                label: 'Reset play count',
                color: Colors.white54,
                onTap: () { Navigator.pop(ctx); _resetPlayCount(clip); },
              ),
            _SheetOption(
              icon: Icons.edit_rounded,
              label: 'Edit clip',
              onTap: () { Navigator.pop(ctx); _editUserClip(clip); },
            ),
            _SheetOption(
              icon: Icons.palette_outlined,
              label: 'Change color',
              onTap: () { Navigator.pop(ctx); _showColorPicker(clip); },
            ),
            _SheetOption(
              icon: Icons.share_rounded,
              label: 'Share clip',
              onTap: () { Navigator.pop(ctx); _shareClip(clip); },
            ),
            _SheetOption(
              icon: Icons.delete_outline_rounded,
              label: 'Delete clip',
              color: Colors.redAccent,
              onTap: () { Navigator.pop(ctx); _deleteUserClip(clip); },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _editUserClip(SoundModel clip) async {
    final result = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ClipEditorScreen(filePath: clip.filePath!, existingClip: clip),
      ),
    );
    if (!mounted || result is! SoundModel) return;
    final updated = result;
    final source = _preloaded[clip.id];
    if (source != null) {
      _durations[clip.id] = updated.trimEnd > updated.trimStart
          ? updated.trimEnd - updated.trimStart
          : SoLoud.instance.getLength(source).inMilliseconds / 1000;
    }
    setState(() {
      final idx = _userClips.indexWhere((c) => c.id == clip.id);
      if (idx != -1) _userClips[idx] = updated;
    });
  }

  Future<void> _shareClip(SoundModel clip) async {
    if (clip.filePath == null) return;
    await Share.shareXFiles([XFile(clip.filePath!)], text: clip.name);
  }

  Future<void> _deleteUserClip(SoundModel clip) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Delete clip?', style: TextStyle(color: Colors.white)),
        content: Text('This will permanently delete "${clip.name}".',
            style: const TextStyle(color: Colors.white60)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final source = _preloaded.remove(clip.id);
    if (source != null) {
      try { await SoLoud.instance.disposeSource(source); } catch (_) {}
    }
    _durations.remove(clip.id);
    await ClipRepository.delete(clip.id, clip.filePath!);
    await ClipRepository.removeSoundFromAllScenes(clip.id);
    setState(() {
      _userClips.removeWhere((c) => c.id == clip.id);
      _recentlyPlayed.removeWhere((s) => s.id == clip.id);
      for (final ids in _sceneSoundIds.values) { ids.remove(clip.id); }
      if (_selectedCategory == 'My Clips' && _userClips.isEmpty) {
        _selectedCategory = 'All';
      }
    });
  }

  // ── Color picker ─────────────────────────────────────────────────────────

  static const _colorSwatches = [
    Color(0xFF6C63FF), // purple (default)
    Color(0xFF4FC3F7), // sky blue
    Color(0xFF26C6DA), // teal
    Color(0xFF5DCAA5), // green
    Color(0xFF7DDB86), // lime green
    Color(0xFFFFD166), // yellow
    Color(0xFFFAC775), // amber
    Color(0xFFFF9F50), // orange
    Color(0xFFFF7272), // red
    Color(0xFFEC407A), // pink
    Color(0xFFFF9FF0), // lavender pink
    Color(0xFF9F8FF0), // violet
    Color(0xFF64C8FF), // light blue
    Color(0xFF78909C), // blue-grey
    Color(0xFFB0BEC5), // light grey
  ];

  Future<void> _showColorPicker(SoundModel clip) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Button Color',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  // Reset to default option
                  GestureDetector(
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _setClipColor(clip, null);
                    },
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: clip.customColor == null
                              ? Colors.white60
                              : Colors.white24,
                          width: clip.customColor == null ? 2 : 1,
                        ),
                      ),
                      child: const Icon(Icons.format_color_reset_rounded,
                          color: Colors.white38, size: 18),
                    ),
                  ),
                  ..._colorSwatches.map((color) {
                    final selected = clip.customColor == color.toARGB32();
                    return GestureDetector(
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _setClipColor(clip, color.toARGB32());
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected ? Colors.white : Colors.transparent,
                            width: 2.5,
                          ),
                          boxShadow: selected
                              ? [BoxShadow(
                                  color: color.withValues(alpha: 0.5),
                                  blurRadius: 8)]
                              : [],
                        ),
                      ),
                    );
                  }),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _setClipColor(SoundModel clip, int? colorValue) async {
    final updated = clip.copyWith(
      customColor: colorValue,
      clearColor: colorValue == null,
    );
    await ClipRepository.update(updated);
    setState(() {
      final idx = _userClips.indexWhere((c) => c.id == clip.id);
      if (idx != -1) _userClips[idx] = updated;
    });
  }

  // ── Search ────────────────────────────────────────────────────────────────

  void _openSearch() => setState(() { _isSearching = true; _searchQuery = ''; });

  void _closeSearch() {
    _searchController.clear();
    setState(() { _isSearching = false; _searchQuery = ''; });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final now = DateTime.now();
        if (_lastBackPress == null ||
            now.difference(_lastBackPress!) > const Duration(seconds: 2)) {
          _lastBackPress = now;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Press back again to exit',
                style: TextStyle(color: Colors.white),
              ),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF2A2A2A),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              margin: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
            ),
          );
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0E0E0E),
        drawer: _ready ? _buildDrawer() : null,
        appBar: _buildAppBar(),
        body: _ready
            ? Stack(
                children: [
                  _buildBody(),
                  Positioned(
                    right: 16,
                    bottom: 24,
                    child: _buildFabs(),
                  ),
                ],
              )
            : _buildLoadingScreen(),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF141414),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Row(children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                        color: const Color(0xFF6C63FF).withValues(alpha: 0.30)),
                  ),
                  child: const Center(
                    child: Text('🔊', style: TextStyle(fontSize: 22)),
                  ),
                ),
                const SizedBox(width: 12),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Soundr', style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    )),
                    Text('Your personal soundboard', style: TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    )),
                  ],
                ),
              ]),
            ),
            const Divider(color: Colors.white10, height: 1),
            const SizedBox(height: 8),

            // ── Nav items ────────────────────────────────────────────────────
            _DrawerItem(
              icon: Icons.grid_view_rounded,
              label: 'Soundboard',
              active: true,
              onTap: () => Navigator.pop(context),
            ),
            _DrawerItem(
              icon: Icons.radio_rounded,
              label: 'Morse Code Tapper',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MorseScreen(
                      dotSource:  _preloaded['s148'],
                      dashSource: _preloaded['s149'],
                    ),
                  ),
                );
              },
            ),
            _DrawerItem(
              icon: Icons.rss_feed_rounded,
              label: 'Morse Code Soundr',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => MorseSoundrScreen(
                      dotSource:  _preloaded['s148'],
                      dashSource: _preloaded['s149'],
                    ),
                  ),
                );
              },
            ),

            const Spacer(),
            const Divider(color: Colors.white10, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                'Soundr v1.0',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.15),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingScreen() => _SplashScreen(
        loadedCount: _loadedCount,
        totalCount: _totalCount,
      );

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0E0E0E),
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      title: _isSearching
          ? TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 17),
              cursorColor: const Color(0xFF6C63FF),
              decoration: const InputDecoration(
                hintText: 'Search sounds...',
                hintStyle: TextStyle(color: Colors.white38),
                border: InputBorder.none,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            )
          : const Text(
              'Soundr',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
      actions: !_ready
          ? null
          : _isSearching
              ? [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: _closeSearch,
                  ),
                ]
              : [
                  IconButton(
                    icon: const Icon(Icons.search_rounded, color: Colors.white),
                    tooltip: 'Search',
                    onPressed: _openSearch,
                  ),
                  IconButton(
                    icon: const Icon(Icons.bar_chart_rounded, color: Colors.white),
                    tooltip: 'Stats',
                    onPressed: _showStats,
                  ),
                  IconButton(
                    icon: const Icon(Icons.stop_circle_outlined, color: Colors.white),
                    tooltip: 'Stop all',
                    onPressed: _stopAll,
                  ),
                ],
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category tabs (hidden while searching)
        if (!_isSearching) ...[
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _categories.length,
              separatorBuilder: (context, i) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final cat = _categories[i];

                // ── "New board" chip ──────────────────────────────────
                if (cat == '__new_scene__') {
                  return GestureDetector(
                    onTap: _showCreateSceneDialog,
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: const Color(0xFF6C63FF).withValues(alpha: 0.35),
                          width: 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_rounded,
                              size: 14,
                              color: const Color(0xFF6C63FF)
                                  .withValues(alpha: 0.8)),
                          const SizedBox(width: 4),
                          Text(
                            'Board',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: const Color(0xFF6C63FF)
                                  .withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                // ── Scene / board chip ────────────────────────────────
                if (cat.startsWith('scene:')) {
                  final sceneId = cat.substring(6);
                  final scene = _scenes.firstWhere((s) => s.id == sceneId,
                      orElse: () => const SceneModel(
                          id: '', name: '', emoji: '', orderIndex: 0));
                  final active = cat == _selectedCategory;
                  final soundCount =
                      _sceneSoundIds[sceneId]?.length ?? 0;
                  return GestureDetector(
                    onTap: () =>
                        setState(() => _selectedCategory = cat),
                    onLongPress: () => _showSceneOptions(scene),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFF6C63FF)
                            : const Color(0xFF6C63FF).withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: active
                              ? const Color(0xFF6C63FF)
                              : const Color(0xFF6C63FF).withValues(alpha: 0.30),
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(scene.emoji,
                              style: const TextStyle(fontSize: 13)),
                          const SizedBox(width: 5),
                          Text(
                            scene.name,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: active
                                  ? Colors.white
                                  : Colors.white70,
                            ),
                          ),
                          if (soundCount > 0) ...[
                            const SizedBox(width: 5),
                            Text(
                              '$soundCount',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: active
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : Colors.white.withValues(alpha: 0.25),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                }

                // ── Standard category chip ────────────────────────────
                final active = cat == _selectedCategory;
                final accent = _categoryAccent(cat);
                // Count badge (skip 'All')
                final int? count = switch (cat) {
                  'All'       => null,
                  'Favorites' => _favorites.length,
                  _           => _allSounds
                                    .where((s) => s.category == cat)
                                    .length,
                };
                return GestureDetector(
                  onTap: () => setState(() => _selectedCategory = cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      // Active chip uses the category's accent color (#9)
                      color: active
                          ? accent
                          : const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: active
                            ? accent
                            : Colors.white12,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          cat,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: active ? Colors.black : Colors.white54,
                          ),
                        ),
                        if (count != null) ...[
                          const SizedBox(width: 5),
                          Text(
                            '$count',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: active
                                  ? Colors.black.withValues(alpha: 0.4)
                                  : Colors.white.withValues(alpha: 0.22),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
        ] else
          const SizedBox(height: 10),

        // Recently played
        if (_recentlyPlayed.isNotEmpty && !_isSearching) _buildRecentlyPlayed(),

        // Sound grid — AnimatedSwitcher fires on category change (not on every
        // search keystroke, so we use a combined key).
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOut,
                )),
                child: child,
              ),
            ),
            child: _filtered.isEmpty
                ? KeyedSubtree(
                    key: ValueKey('empty_${_isSearching ? 'search' : _selectedCategory}'),
                    child: _buildEmptyState(),
                  )
                : GridView.builder(
                    key: ValueKey(_isSearching ? 'search' : _selectedCategory),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                      childAspectRatio: 0.9,
                    ),
                    itemCount: _filtered.length,
                    itemBuilder: (context, i) {
                      final sound = _filtered[i];
                      return GestureDetector(
                        onLongPress: sound.isUserClip
                            ? () => _showClipOptions(sound)
                            : () => _showSoundOptions(sound),
                        child: SoundButton(
                          sound: sound,
                          duration: _durations[sound.id] ?? 0,
                          stopSignal: _stopSignal,
                          stopOthersSignal: _stopOthersSignal,
                          excludeFromStopOthers:
                              _stopOnTapExcludeId == sound.id,
                          isFavorited: _favorites.contains(sound.id),
                          onFavoriteToggle: () => _toggleFavorite(sound),
                          onTap: () => _play(sound),
                          playCount: _playCounts[sound.id] ?? 0,
                          highlightQuery: _isSearching ? _searchQuery : '',
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    // Search with no matches
    if (_isSearching && _searchQuery.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded,
                size: 48, color: Colors.white.withValues(alpha: 0.12)),
            const SizedBox(height: 16),
            Text(
              'No results for "$_searchQuery"',
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try a different name or category',
              style: TextStyle(color: Colors.white24, fontSize: 12),
            ),
          ],
        ),
      );
    }

    // Board (scene) with no sounds added yet
    if (_selectedCategory.startsWith('scene:')) {
      final sceneId = _selectedCategory.substring(6);
      final scene = _scenes.firstWhere((s) => s.id == sceneId,
          orElse: () =>
              const SceneModel(id: '', name: 'Board', emoji: '🎵', orderIndex: 0));
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(scene.emoji,
                style: TextStyle(
                    fontSize: 48,
                    color: Colors.white.withValues(alpha: 0.15))),
            const SizedBox(height: 16),
            Text(
              '"${scene.name}" is empty',
              style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              'Long-press any sound → Manage boards',
              style: TextStyle(color: Colors.white30, fontSize: 13),
            ),
          ],
        ),
      );
    }

    // Favorites tab but nothing starred yet
    if (_selectedCategory == 'Favorites') {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_outline_rounded,
                size: 52, color: Colors.amber.withValues(alpha: 0.25)),
            const SizedBox(height: 16),
            const Text(
              'No favorites yet',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap ★ on any sound to save it here',
              style: TextStyle(color: Colors.white30, fontSize: 13),
            ),
          ],
        ),
      );
    }

    // My Clips tab but no clips recorded or imported yet
    if (_selectedCategory == 'My Clips') {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.mic_none_rounded,
                size: 52, color: Colors.white.withValues(alpha: 0.12)),
            const SizedBox(height: 16),
            const Text(
              'No clips yet',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap 🎤 to record or 📂 to import a sound',
              style: TextStyle(color: Colors.white30, fontSize: 13),
            ),
          ],
        ),
      );
    }

    // Fallback
    return const Center(
      child: Text('No sounds', style: TextStyle(color: Colors.white38, fontSize: 15)),
    );
  }

  Widget _buildRecentlyPlayed() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'RECENTLY PLAYED',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.22),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _recentlyPlayed.length,
            separatorBuilder: (context, i) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final sound = _recentlyPlayed[i];
              return GestureDetector(
                onTapDown: (_) {
                  HapticFeedback.selectionClick();
                  _play(sound);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(sound.emoji,
                          style: const TextStyle(fontSize: 15)),
                      const SizedBox(width: 6),
                      Text(
                        sound.name,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildFabs() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Stop-on-tap FAB
        _buildStopOnTapFab(),
        const SizedBox(height: 10),
        // Randomize
        FloatingActionButton(
          heroTag: 'random',
          onPressed: _playRandom,
          backgroundColor: const Color(0xFF1A1A1A),
          elevation: 0,
          shape: CircleBorder(
            side: BorderSide(color: Colors.white.withAlpha(30), width: 1),
          ),
          child: const Icon(Icons.casino_rounded, color: Colors.white60, size: 22),
        ),
        const SizedBox(height: 10),
        // Import audio (file or URL)
        FloatingActionButton(
          heroTag: 'import',
          onPressed: _showImportOptions,
          backgroundColor: const Color(0xFF1A1A1A),
          elevation: 0,
          shape: CircleBorder(
            side: BorderSide(color: Colors.white.withAlpha(30), width: 1),
          ),
          child: const Icon(Icons.file_open_rounded, color: Colors.white60, size: 22),
        ),
        const SizedBox(height: 10),
        // Record
        FloatingActionButton(
          heroTag: 'record',
          onPressed: _openRecorder,
          backgroundColor: const Color(0xFF1C1C1C),
          shape: CircleBorder(
            side: BorderSide(color: Colors.white.withAlpha(40), width: 1),
          ),
          elevation: 0,
          child: const Icon(Icons.mic_rounded, color: Colors.white, size: 24),
        ),
      ],
    );
  }

  Widget _buildStopOnTapFab() {
    final isActive = _stopOnTap;
    final isExpanded = _stopOnTap && _stopOnTapExpanded;

    // AnimatedSize lets the container width follow its content exactly —
    // no hardcoded pill width, so there's never blank trailing space.
    // AnimatedAlign(widthFactor) slides the label in/out; AnimatedSize
    // tracks the resulting Row width and animates the outer bounds.
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: isActive ? Colors.white : const Color(0xFF1A1A1A),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: isActive ? Colors.white : Colors.white.withAlpha(30),
            width: 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _toggleStopOnTap,
            splashColor: isActive ? Colors.black12 : Colors.white10,
            highlightColor: Colors.transparent,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 54,
                  height: 56,
                  child: Center(
                    child: Icon(
                      Icons.touch_app_rounded,
                      color: isActive ? const Color(0xFF0E0E0E) : Colors.white38,
                      size: 22,
                    ),
                  ),
                ),
                ClipRect(
                  child: AnimatedAlign(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    alignment: Alignment.centerLeft,
                    widthFactor: isExpanded ? 1.0 : 0.0,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 18),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: isExpanded ? 1.0 : 0.0,
                        child: const Text(
                          'Stop-on-tap',
                          style: TextStyle(
                            color: Color(0xFF0E0E0E),
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
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

// ── Category accent colour map ────────────────────────────────────────────────

/// Returns the accent colour for a given category name.
/// Used by both the chip tinting (#9) and the SoundButton interior.
Color _categoryAccent(String category) => switch (category) {
  'Instruments' => const Color(0xFFFAC775),
  'Memes'       => const Color(0xFFFF7272),
  'Reactions'   => const Color(0xFF64C8FF),
  'Effects'     => const Color(0xFF5DCAA5),
  'UI'          => const Color(0xFF9F8FF0),
  'Music'       => const Color(0xFFFF9FF0),
  'Animals'     => const Color(0xFF7DDB86),
  'Gaming'      => const Color(0xFF7B73FF),
  'Anime'       => const Color(0xFFFF9F7F),
  'Cartoons'    => const Color(0xFFFFD166),
  'My Clips'    => const Color(0xFF6C63FF),
  'Favorites'   => Colors.amber,
  _             => const Color(0xFF888780),
};

// ── Stat summary card ─────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Drawer nav item ───────────────────────────────────────────────────────────

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF6C63FF);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: active ? accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(icon,
              size: 20,
              color: active ? accent : Colors.white38),
          const SizedBox(width: 14),
          Text(label,
              style: TextStyle(
                color: active ? accent : Colors.white60,
                fontSize: 15,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              )),
        ]),
      ),
    );
  }
}

// ── Bottom sheet option ───────────────────────────────────────────────────────

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _SheetOption({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 16),
          Text(label,
              style: TextStyle(
                  color: color, fontSize: 16, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

// ── Animated splash screen ────────────────────────────────────────────────────

class _SplashScreen extends StatefulWidget {
  final int loadedCount;
  final int totalCount;
  const _SplashScreen({required this.loadedCount, required this.totalCount});

  @override
  State<_SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<_SplashScreen>
    with TickerProviderStateMixin {
  // Drives the bars — loops forever at 900 ms/cycle.
  late final AnimationController _barsCtrl;
  // One-shot fade/slide for the wordmark and progress bar.
  late final AnimationController _textCtrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  // Each bar oscillates between its min and max height using a sine wave.
  // Using 5 different phase offsets spreads them out so they never all
  // peak / trough at the same moment.
  static const _minH = [35.0, 50.0, 57.0, 40.0, 27.0];
  static const _maxH = [46.0, 62.0, 70.0, 54.0, 40.0];
  static const _phases = [0.0, 1.2, 2.4, 0.7, 3.6]; // radians

  @override
  void initState() {
    super.initState();

    _barsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(); // loops 0 → 1 → 0 → 1 …, smooth because sin(0)==sin(2π)

    _textCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();

    _fadeAnim = CurvedAnimation(parent: _textCtrl, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.22),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _textCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _barsCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        widget.totalCount > 0 ? widget.loadedCount / widget.totalCount : null;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // ── Looping equalizer logo ─────────────────────────────────────
          AnimatedBuilder(
            animation: _barsCtrl,
            builder: (context, _) => SizedBox(
              width: 82,
              height: 72,
              child: CustomPaint(
                painter: _BarsPainter(
                  t: _barsCtrl.value,
                  minHeights: _minH,
                  maxHeights: _maxH,
                  phases: _phases,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),

          // ── App name + tagline (fade in once) ─────────────────────────
          FadeTransition(
            opacity: _fadeAnim,
            child: SlideTransition(
              position: _slideAnim,
              child: Column(
                children: [
                  const Text(
                    'Soundr',
                    style: TextStyle(
                      fontSize: 44,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -2.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Your personal soundboard',
                    style: TextStyle(
                      color: Colors.white.withAlpha(50),
                      fontSize: 13,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 58),

          // ── Loading progress (fade in once) ───────────────────────────
          FadeTransition(
            opacity: _fadeAnim,
            child: Column(
              children: [
                SizedBox(
                  width: 140,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.white.withAlpha(12),
                      valueColor:
                          const AlwaysStoppedAnimation(Color(0xFF6C63FF)),
                      minHeight: 3,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.totalCount > 0
                      ? '${widget.loadedCount} / ${widget.totalCount} sounds'
                      : 'Starting up...',
                  style: TextStyle(
                    color: Colors.white.withAlpha(35),
                    fontSize: 12,
                    letterSpacing: 0.3,
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

class _BarsPainter extends CustomPainter {
  final double t;              // AnimationController.value — 0..1, repeating
  final List<double> minHeights;
  final List<double> maxHeights;
  final List<double> phases;   // per-bar phase offset in radians

  const _BarsPainter({
    required this.t,
    required this.minHeights,
    required this.maxHeights,
    required this.phases,
  });

  static const _barW = 11.0;
  static const _gap = 7.0;
  static const _canvasH = 72.0; // matches SizedBox height above
  static const _radius = Radius.circular(5);

  @override
  void paint(Canvas canvas, Size size) {
    final shaderRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Crisp gradient paint
    final barPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0xFF5A52E0), Color(0xFFD8D6FF)],
      ).createShader(shaderRect);

    // Soft glow behind each bar
    final glowPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0xFF6C63FF), Color(0xFFB8B5FF)],
      ).createShader(shaderRect)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);

    for (int i = 0; i < minHeights.length; i++) {
      // sin gives -1..1; map to 0..1 then lerp between min and max heights
      final wave = (sin(t * 2 * pi + phases[i]) + 1) / 2;
      final h = lerpDouble(minHeights[i], maxHeights[i], wave)!;
      final x = i * (_barW + _gap);
      final barRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, _canvasH - h, _barW, h),
        _radius,
      );
      canvas.drawRRect(barRect, glowPaint); // glow first
      canvas.drawRRect(barRect, barPaint);  // crisp bar on top
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) => old.t != t;
}
