import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../theme/app_colors.dart';

class _ZenTrack {
  final String id;
  final String name;
  final String emoji;
  final String description;
  final String file; // relative to assets/zen/

  const _ZenTrack({
    required this.id,
    required this.name,
    required this.emoji,
    required this.description,
    required this.file,
  });
}

class ZenScreen extends StatefulWidget {
  const ZenScreen({super.key});

  @override
  State<ZenScreen> createState() => _ZenScreenState();
}

class _ZenScreenState extends State<ZenScreen> {
  static const _tracks = [
    _ZenTrack(id: 'zen_rain',      name: 'Rain',            emoji: '🌧️', description: 'Gentle rainfall',              file: 'rain.mp3'),
    _ZenTrack(id: 'zen_thunder',   name: 'Thunderstorm',    emoji: '⛈️', description: 'Rain with distant thunder',    file: 'thunderstorm.mp3'),
    _ZenTrack(id: 'zen_forest',    name: 'Forest',          emoji: '🌲', description: 'Birds and rustling leaves',    file: 'forest.mp3'),
    _ZenTrack(id: 'zen_ocean',     name: 'Ocean Waves',     emoji: '🌊', description: 'Rhythmic waves on shore',      file: 'ocean.mp3'),
    _ZenTrack(id: 'zen_fire',      name: 'Fireplace',       emoji: '🔥', description: 'Crackling fire',              file: 'fireplace.mp3'),
    _ZenTrack(id: 'zen_cafe',      name: 'Café',            emoji: '☕', description: 'Quiet coffee shop ambience',  file: 'cafe.mp3'),
    _ZenTrack(id: 'zen_wind',      name: 'Wind',            emoji: '🌬️', description: 'Soft breeze through trees',   file: 'wind.mp3'),
    _ZenTrack(id: 'zen_white',     name: 'White Noise',     emoji: '📻', description: 'Steady background hiss',      file: 'white_noise.mp3'),
    _ZenTrack(id: 'zen_stream',    name: 'Mountain Stream', emoji: '🏔️', description: 'Flowing water over rocks',    file: 'stream.mp3'),
    _ZenTrack(id: 'zen_night',     name: 'Night Crickets',  emoji: '🦗', description: 'Summer evening insects',      file: 'night.mp3'),
  ];

  // Loaded sources — only populated for tracks whose file exists
  final Map<String, AudioSource> _sources = {};
  // Active handles
  final Map<String, SoundHandle> _handles = {};
  // Which tracks are in a loading state
  final Set<String> _loading = {};
  // Which tracks are available (file found in assets)
  final Set<String> _available = {};

  @override
  void initState() {
    super.initState();
    _probeAssets();
  }

  @override
  void dispose() {
    _stopAll(notify: false);
    for (final src in _sources.values) {
      try { SoLoud.instance.disposeSource(src); } catch (_) {}
    }
    super.dispose();
  }

  // Try loading each track silently to know which files exist
  Future<void> _probeAssets() async {
    for (final track in _tracks) {
      try {
        final data = await rootBundle.load('assets/zen/${track.file}');
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
    }
  }

  Future<void> _toggle(_ZenTrack track) async {
    if (!_available.contains(track.id)) return;

    if (_handles.containsKey(track.id)) {
      // Stop
      try { SoLoud.instance.stop(_handles[track.id]!); } catch (_) {}
      setState(() => _handles.remove(track.id));
      return;
    }

    // Play looping
    final source = _sources[track.id];
    if (source == null) return;

    setState(() => _loading.add(track.id));
    try {
      final handle = await SoLoud.instance.play(source, looping: true);
      if (mounted) {
        setState(() {
          _handles[track.id] = handle;
          _loading.remove(track.id);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading.remove(track.id));
    }
  }

  void _stopAll({bool notify = true}) {
    for (final handle in _handles.values) {
      try { SoLoud.instance.stop(handle); } catch (_) {}
    }
    if (notify && mounted) setState(() => _handles.clear());
  }

  bool get _anyPlaying => _handles.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.surfaceCard,
        foregroundColor: c.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            Text('🧘', style: const TextStyle(fontSize: 20)),
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
          // Header hint
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Row(
              children: [
                Icon(Icons.layers_rounded, size: 15, color: c.textMuted),
                const SizedBox(width: 6),
                Text(
                  'Layer multiple sounds — they loop until stopped.',
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),

          // Grid
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
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

class _ZenTile extends StatelessWidget {
  final _ZenTrack track;
  final bool isAvailable;
  final bool isPlaying;
  final bool isLoading;
  final Color accent;
  final AppColors colors;
  final VoidCallback onTap;

  const _ZenTile({
    required this.track,
    required this.isAvailable,
    required this.isPlaying,
    required this.isLoading,
    required this.accent,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dimmed = !isAvailable;

    return GestureDetector(
      onTap: isAvailable && !isLoading ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        decoration: BoxDecoration(
          color: isPlaying
              ? accent.withValues(alpha: 0.10)
              : colors.surfaceCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isPlaying
                ? accent.withValues(alpha: 0.55)
                : colors.border,
            width: isPlaying ? 1.8 : 1,
          ),
          boxShadow: isPlaying
              ? [BoxShadow(color: accent.withValues(alpha: 0.12), blurRadius: 16)]
              : [],
        ),
        child: Stack(
          children: [
            // Main content
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    track.emoji,
                    style: TextStyle(
                      fontSize: 36,
                      color: dimmed ? null : null,
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.name,
                        style: TextStyle(
                          color: dimmed
                              ? colors.textMuted
                              : isPlaying
                                  ? accent
                                  : colors.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        track.description,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Playing indicator (top-right)
            if (isLoading)
              Positioned(
                top: 10, right: 10,
                child: SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
                ),
              )
            else if (isPlaying)
              Positioned(
                top: 10, right: 10,
                child: Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),

            // Coming soon badge (bottom-right)
            if (!isAvailable)
              Positioned(
                bottom: 10, right: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colors.surfaceElevated,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Soon',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
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
            child: Text(
              label,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
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
