import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/sound_model.dart';
import '../services/clip_repository.dart';
import '../services/haptics.dart';
import '../services/waveforms.dart';
import '../theme/app_colors.dart';
import '../widgets/clip_editor_trim.dart';

const _kWaveSamples = 64;

class ClipEditorScreen extends StatefulWidget {
  final String filePath;
  final SoundModel? existingClip;

  const ClipEditorScreen({
    super.key,
    required this.filePath,
    this.existingClip,
  });

  @override
  State<ClipEditorScreen> createState() => _ClipEditorScreenState();
}

class _ClipEditorScreenState extends State<ClipEditorScreen> {
  late final PlayerController _playerController;
  double _totalDuration = 0;
  double _trimStart = 0;
  double _trimEnd = 1;
  bool _isPlaying = false;
  /// Current preview position in ms, while playing.
  int? _playheadMs;
  bool _isLoading = true;
  bool _isSaving = false;
  Timer? _playStopTimer;
  StreamSubscription<int>? _playPositionSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  late final TextEditingController _nameController;
  late String _selectedEmoji;
  late String _selectedCategory;

  /// Button colour as ARGB; null = the category's default colour.
  int? _customColor;

  static const _emojis = [
    '🎙️', '🎵', '🎤', '🔊', '💥', '😂',
    '🎮', '👻', '🔥', '⚡', '🎺', '🥁',
    '🤣', '😱', '💀', '🐸', '🤖', '🎯',
  ];

  static const _categories = [
    'My Clips', 'Funny', 'Music', 'Reactions', 'Sound FX', 'Gaming'
  ];

  /// Same palette as the soundboard's "Change colour" sheet.
  static const _colorSwatches = <(Color, String)>[
    (Color(0xFF6C63FF), 'Purple'),
    (Color(0xFF4FC3F7), 'Sky blue'),
    (Color(0xFF26C6DA), 'Teal'),
    (Color(0xFF5DCAA5), 'Green'),
    (Color(0xFF7DDB86), 'Lime green'),
    (Color(0xFFFFD166), 'Yellow'),
    (Color(0xFFFAC775), 'Amber'),
    (Color(0xFFFF9F50), 'Orange'),
    (Color(0xFFFF7272), 'Red'),
    (Color(0xFFEC407A), 'Pink'),
    (Color(0xFFFF9FF0), 'Lavender pink'),
    (Color(0xFF9F8FF0), 'Violet'),
    (Color(0xFF64C8FF), 'Light blue'),
    (Color(0xFF78909C), 'Blue-grey'),
    (Color(0xFFB0BEC5), 'Light grey'),
  ];

  bool get _isEditMode => widget.existingClip != null;

  @override
  void initState() {
    super.initState();
    final clip = widget.existingClip;
    _nameController = TextEditingController(text: clip?.name ?? 'My Clip');
    _selectedEmoji = clip?.emoji ?? '🎙️';
    _selectedCategory = clip?.category ?? 'My Clips';
    _customColor = clip?.customColor;
    _playerController = PlayerController();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      // Frequent position updates so the waveform fills smoothly.
      _playerController.updateFrequency = UpdateFrequency.high;
      await _playerController.preparePlayer(
        path: widget.filePath,
        shouldExtractWaveform: true,
        noOfSamples: _kWaveSamples,
      );
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }
    final durationMs = await _playerController.getDuration(DurationType.max);
    _playerStateSub = _playerController.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlaying = state == PlayerState.playing;
        if (!_isPlaying) _playheadMs = null;
      });
    });
    if (mounted) {
      final totalSec = math.max(0, durationMs) / 1000.0;
      double normStart = 0, normEnd = 1;
      final clip = widget.existingClip;
      if (clip != null && totalSec > 0 && clip.trimEnd > clip.trimStart) {
        normStart = (clip.trimStart / totalSec).clamp(0.0, 1.0);
        normEnd = (clip.trimEnd / totalSec).clamp(0.0, 1.0);
      }
      setState(() {
        _totalDuration = totalSec;
        _trimStart = normStart;
        _trimEnd = normEnd;
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _playStopTimer?.cancel();
    _playPositionSub?.cancel();
    _playerStateSub?.cancel();
    _playerController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _cancelPlayback() {
    _playStopTimer?.cancel();
    _playPositionSub?.cancel();
    _playPositionSub = null;
  }

  Future<void> _togglePlayback() async {
    Haptics.light();
    if (_isPlaying) {
      _cancelPlayback();
      await _playerController.pausePlayer();
    } else {
      _cancelPlayback();
      // audio_waveforms' default FinishMode.stop sends the player to stopped
      // after natural completion. seekTo and startPlayer are both no-ops from
      // stopped, so we re-prepare (no waveform re-extraction) to get back to
      // initialized state before attempting to seek and play.
      if (_playerController.playerState == PlayerState.stopped) {
        await _playerController.preparePlayer(
          path: widget.filePath,
          shouldExtractWaveform: false,
          noOfSamples: _kWaveSamples,
        );
      }
      final startMs = (_trimStart * _totalDuration * 1000).round();
      final endMs = (_trimEnd * _totalDuration * 1000).round();
      await _playerController.seekTo(startMs);
      if (mounted) setState(() => _playheadMs = startMs);
      _playPositionSub = _playerController.onCurrentDurationChanged.listen((ms) {
        if (mounted && _isPlaying) setState(() => _playheadMs = ms);
      });
      await _playerController.startPlayer();
      _playStopTimer = Timer(Duration(milliseconds: endMs - startMs), () async {
        if (!mounted) return;
        _cancelPlayback();
        await _playerController.pausePlayer();
        await _playerController.seekTo(startMs);
      });
    }
  }

  void _onTrimStartChanged(double v) {
    _cancelPlayback();
    if (_isPlaying) _playerController.pausePlayer();
    setState(() => _trimStart = v);
  }

  void _onTrimEndChanged(double v) {
    _cancelPlayback();
    if (_isPlaying) _playerController.pausePlayer();
    setState(() => _trimEnd = v);
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);
    try {
      final trimStartS = _trimStart * _totalDuration;
      final trimEndS = _trimEnd * _totalDuration;

      if (_isEditMode) {
        final updated = widget.existingClip!.copyWith(
          name: name,
          category: _selectedCategory,
          emoji: _selectedEmoji,
          trimStart: trimStartS,
          trimEnd: trimEndS,
          customColor: _customColor,
          clearColor: _customColor == null,
        );
        await ClipRepository.update(updated);
        if (mounted) Navigator.pop(context, updated);
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final id = 'clip_${DateTime.now().millisecondsSinceEpoch}';
        final clipsDir = Directory(p.join(dir.path, 'clips'));
        await clipsDir.create(recursive: true);
        final ext = p.extension(widget.filePath);
        final outPath = p.join(clipsDir.path, '$id${ext.isNotEmpty ? ext : '.wav'}');
        await File(widget.filePath).copy(outPath);
        await ClipRepository.insert(SoundModel(
          id: id,
          name: name,
          file: '',
          category: _selectedCategory,
          emoji: _selectedEmoji,
          isUserClip: true,
          filePath: outPath,
          trimStart: trimStartS,
          trimEnd: trimEndS,
          customColor: _customColor,
        ));
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      setState(() => _isSaving = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not save clip: $e'),
          backgroundColor: Colors.redAccent,
        ));
      }
    }
  }

  static String _clock(double seconds) {
    final tenths = (math.max(0.0, seconds) * 10).round();
    final m = tenths ~/ 600;
    final s = (tenths % 600) / 10;
    return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }

  /// Extracted waveform scaled so the loudest bar is full height (gentle
  /// curve lifts quiet passages); a stand-in shape until extraction lands.
  List<double>? _levelsCacheSource;
  int _levelsCacheLength = -1;
  List<double> _levelsCache = const [];

  List<double> get _levels {
    final raw = _playerController.waveformData;
    if (identical(raw, _levelsCacheSource) && raw.length == _levelsCacheLength) {
      return _levelsCache;
    }
    _levelsCacheSource = raw;
    _levelsCacheLength = raw.length;
    final loudest = raw.isEmpty ? 0.0 : raw.map((v) => v.abs()).reduce(math.max);
    _levelsCache = loudest <= 0
        ? Waveforms.placeholder(widget.filePath, _kWaveSamples)
        : [for (final v in raw) math.pow(v.abs() / loudest, 0.7).toDouble()];
    return _levelsCache;
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isEditMode ? 'Edit clip' : 'New clip',
          style: TextStyle(
            color: c.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 20,
            letterSpacing: -0.4,
          ),
        ),
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: c.textMuted))
          : SafeArea(
              top: false,
              child: CustomScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverToBoxAdapter(child: _content(context, c, accent)),
                  // Pushes the save button to the bottom on tall screens;
                  // on short ones (or with the keyboard up) it just follows
                  // the content and the whole page scrolls.
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 28, 16, 20),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [_saveButton(context)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _content(BuildContext context, AppColors c, Color accent) {
    final selected = (_trimEnd - _trimStart) * _totalDuration;
    final tabular = [const FontFeature.tabularFigures()];
    final canPlay = _totalDuration > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Trim card ───────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Container(
            // No side padding: the waveform's grab area runs to the card
            // edges; the other rows pad themselves.
            padding: const EdgeInsets.fromLTRB(0, 18, 0, 14),
            decoration: BoxDecoration(
              color: c.surfaceCard,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: c.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Expanded(child: _Label('TRIM', pad: false)),
                      Text('${selected.toStringAsFixed(1)}s selected',
                          style: TextStyle(
                            color: accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            fontFeatures: tabular,
                          )),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: _playerController,
                  builder: (context, _) => ClipTrimWaveform(
                    levels: _levels,
                    trimStart: _trimStart,
                    trimEnd: _trimEnd,
                    totalDuration: _totalDuration,
                    onStartChanged: _onTrimStartChanged,
                    onEndChanged: _onTrimEndChanged,
                    playhead: _playheadMs != null && _totalDuration > 0
                        ? (_playheadMs! / 1000 / _totalDuration).clamp(0.0, 1.0)
                        : null,
                  ),
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 12,
                      fontFeatures: tabular,
                    ),
                    child: Row(children: [
                      Text(_clock(_trimStart * _totalDuration)),
                      Expanded(
                        child: Text(
                          'Drag the handles to trim',
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Theme.of(context).brightness == Brightness.light
                                ? c.textSecondary
                                : c.textMuted,
                            fontFeatures: const [],
                          ),
                        ),
                      ),
                      Text(_clock(_trimEnd * _totalDuration)),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── Play selection ──────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: Row(children: [
            _PlayButton(
              playing: _isPlaying,
              onTap: canPlay ? _togglePlayback : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_isPlaying ? 'Playing selection' : 'Play selection',
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 2),
                  Text(
                    canPlay
                        ? 'of ${_totalDuration.toStringAsFixed(1)}s recorded'
                        : 'Preview unavailable',
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 13,
                      fontFeatures: tabular,
                    ),
                  ),
                ],
              ),
            ),
          ]),
        ),

        // ── Name ────────────────────────────────────────────────────────
        const _Label('NAME', top: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _nameController,
            style: TextStyle(color: c.textPrimary, fontSize: 16),
            cursorColor: accent,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'Name your clip',
              hintStyle: TextStyle(color: c.textSecondary),
              filled: true,
              fillColor: c.surfaceCard,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: accent, width: 1.5),
              ),
            ),
          ),
        ),

        // ── Category ────────────────────────────────────────────────────
        const _Label('CATEGORY', top: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Semantics(
            container: true,
            label: 'Category',
            child: Wrap(
              spacing: 8,
              children: [
                for (final cat in _categories)
                  _CategoryChip(
                    label: cat,
                    selected: _selectedCategory == cat,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _selectedCategory = cat);
                    },
                  ),
              ],
            ),
          ),
        ),

        // ── Emoji ───────────────────────────────────────────────────────
        const _Label('EMOJI', top: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LayoutBuilder(builder: (context, constraints) {
            const cols = 6, gap = 8.0;
            final size = (constraints.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final e in _emojis)
                  _EmojiTile(
                    emoji: e,
                    size: size,
                    selected: _selectedEmoji == e,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _selectedEmoji = e);
                    },
                  ),
              ],
            );
          }),
        ),

        // ── Button colour ───────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
          child: Row(children: [
            const Expanded(child: _Label('BUTTON COLOUR', pad: false)),
            Text(_colorName(_customColor),
                style: TextStyle(color: c.textSecondary, fontSize: 13)),
          ]),
        ),
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              _Swatch(
                color: null,
                label: 'Default colour',
                selected: _customColor == null,
                onTap: () => _pickColor(null),
              ),
              for (final (color, name) in _colorSwatches)
                _Swatch(
                  color: color,
                  label: name,
                  selected: _customColor == color.toARGB32(),
                  onTap: () => _pickColor(color.toARGB32()),
                ),
            ],
          ),
        ),
      ],
    );
  }

  void _pickColor(int? argb) {
    Haptics.selection();
    setState(() => _customColor = argb);
  }

  static String _colorName(int? argb) {
    if (argb == null) return 'Category default';
    for (final (color, name) in _colorSwatches) {
      if (color.toARGB32() == argb) return name;
    }
    return 'Custom';
  }

  Widget _saveButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _nameController,
      builder: (context, value, _) {
        final enabled = !_isSaving && !_isLoading && value.text.trim().isNotEmpty;
        return SizedBox(
          width: double.infinity,
          height: 56,
          child: FilledButton(
            onPressed: enabled ? _save : null,
            style: FilledButton.styleFrom(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              textStyle: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            child: _isSaving
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: scheme.onPrimary),
                  )
                : Text(_isEditMode ? 'Save changes' : 'Save to soundboard'),
          ),
        );
      },
    );
  }
}

// ── Building blocks ───────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  final double top;
  final bool pad;
  const _Label(this.text, {this.top = 0, this.pad = true});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final label = Text(
      text,
      style: TextStyle(
        color: c.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    );
    if (!pad) return label;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, top, 20, 8),
      child: label,
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final VoidCallback? onTap;
  const _PlayButton({required this.playing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Material(
      color: enabled ? scheme.primary : scheme.onSurface.withValues(alpha: 0.12),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 52,
          height: 52,
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: enabled ? scheme.onPrimary : scheme.onSurface.withValues(alpha: 0.38),
            size: 28,
            semanticLabel: playing ? 'Pause selection' : 'Play selection',
          ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          // 36px chip inside a 48px tap target.
          tapTargetSize: MaterialTapTargetSize.padded,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          backgroundColor: selected ? scheme.primary : c.surfaceCard,
          foregroundColor: selected ? scheme.onPrimary : c.textSecondary,
          shape: StadiumBorder(
            side: selected ? BorderSide.none : BorderSide(color: c.border),
          ),
          textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
        ),
        child: Text(label),
      ),
    );
  }
}

class _EmojiTile extends StatelessWidget {
  final String emoji;
  final double size;
  final bool selected;
  final VoidCallback onTap;
  const _EmojiTile({
    required this.emoji,
    required this.size,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: 'Emoji $emoji',
      child: Material(
        color: selected
            ? accent.withValues(alpha: 0.18)
            : c.surfaceElevated.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? accent : c.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: ExcludeSemantics(
                child: Text(emoji, style: const TextStyle(fontSize: 26)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round colour swatch (37px dot, ring when selected) in a 52px tap target. [color] null is
/// the "use the category's colour" option.
class _Swatch extends StatelessWidget {
  final Color? color;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      child: Tooltip(
        message: label,
        child: InkResponse(
          onTap: onTap,
          radius: 26,
          child: SizedBox(
            width: 52,
            height: 52,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 48,
                height: 48,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? c.textPrimary : Colors.transparent,
                    width: 2.5,
                  ),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color ?? c.surfaceElevated,
                    border: color == null ? Border.all(color: c.border) : null,
                  ),
                  child: color == null
                      ? Icon(Icons.format_color_reset_rounded,
                          size: 16, color: c.iconSecondary)
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
