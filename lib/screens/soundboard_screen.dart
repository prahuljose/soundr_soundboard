import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show lerpDouble;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:share_plus/share_plus.dart';
import '../data/sounds_data.dart';
import '../models/sound_model.dart';
import '../services/clip_repository.dart';
import '../services/notification_service.dart';
import '../widgets/sound_button.dart';
import 'clip_editor_screen.dart';
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

  // Back-button guard
  DateTime? _lastBackPress;

  // ── Data ──────────────────────────────────────────────────────────────────

  List<SoundModel> get _allSounds => [...SoundsData.all, ..._userClips];

  List<String> get _categories {
    final cats = <String>['All'];
    if (_favorites.isNotEmpty) cats.add('Favorites');
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
    await SoLoud.instance.init();
    await _loadUserClips();
    final sounds = _allSounds;
    if (mounted) setState(() { _totalCount = sounds.length; _loadedCount = 0; });
    await _preloadAll(sounds);
    _favorites = await ClipRepository.getFavorites();
    _playCounts = await ClipRepository.getPlayCounts();
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _loadUserClips() async {
    _userClips = await ClipRepository.getAll();
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

    // Show notification
    NotificationService.showPlayingNotification(sound.name);

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

  Future<void> _showClipOptions(SoundModel clip) async {
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
                Text(clip.emoji, style: const TextStyle(fontSize: 28)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(clip.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            const Divider(color: Colors.white12, height: 1),
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
    setState(() {
      _userClips.removeWhere((c) => c.id == clip.id);
      _recentlyPlayed.removeWhere((s) => s.id == clip.id);
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
      actions: _isSearching
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
                final active = cat == _selectedCategory;
                return GestureDetector(
                  onTap: () => setState(() => _selectedCategory = cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: active ? Colors.white : const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: active ? Colors.white : Colors.white12,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      cat,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: active ? Colors.black : Colors.white54,
                      ),
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

        // Sound grid
        Expanded(
          child: _filtered.isEmpty
              ? Center(
                  child: Text(
                    _searchQuery.isEmpty ? 'No sounds' : 'No results for "$_searchQuery"',
                    style: const TextStyle(color: Colors.white38, fontSize: 15),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                          : null,
                      child: SoundButton(
                        sound: sound,
                        duration: _durations[sound.id] ?? 0,
                        stopSignal: _stopSignal,
                        stopOthersSignal: _stopOthersSignal,
                        excludeFromStopOthers: _stopOnTapExcludeId == sound.id,
                        isFavorited: _favorites.contains(sound.id),
                        onFavoriteToggle: () => _toggleFavorite(sound),
                        onTap: () => _play(sound),
                        playCount: _playCounts[sound.id] ?? 0,
                      ),
                    );
                  },
                ),
        ),
      ],
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
        // Import audio
        FloatingActionButton(
          heroTag: 'import',
          onPressed: _importAudio,
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
