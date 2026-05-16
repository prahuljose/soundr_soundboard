import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../models/sound_model.dart';
import '../services/clip_repository.dart';
import '../theme/app_colors.dart';

const _kWaveSamples = 30;

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
  bool _isLoading = true;
  bool _isSaving = false;
  Timer? _playStopTimer;
  StreamSubscription<int>? _playPositionSub;
  late final TextEditingController _nameController;
  late String _selectedEmoji;
  late String _selectedCategory;

  static const _emojis = [
    '🎙️', '🎵', '🎤', '🔊', '💥', '😂',
    '🎮', '👻', '🔥', '⚡', '🎺', '🥁',
    '🤣', '😱', '💀', '🐸', '🤖', '🎯',
  ];

  static const _categories = [
    'My Clips', 'Funny', 'Music', 'Reactions', 'Sound FX', 'Gaming'
  ];

  bool get _isEditMode => widget.existingClip != null;

  @override
  void initState() {
    super.initState();
    final clip = widget.existingClip;
    _nameController = TextEditingController(text: clip?.name ?? 'My Clip');
    _selectedEmoji = clip?.emoji ?? '🎙️';
    _selectedCategory = clip?.category ?? 'My Clips';
    _playerController = PlayerController();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
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
    _playerController.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      setState(() => _isPlaying = state == PlayerState.playing);
    });
    if (mounted) {
      final totalSec = durationMs / 1000.0;
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

  String _fmt(double seconds) {
    if (seconds < 0) seconds = 0;
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: c.iconSecondary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _isEditMode ? 'Edit Clip' : 'New Clip',
          style: TextStyle(
            color: c.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 20,
            letterSpacing: -0.4,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _isSaving || _isLoading ? null : _save,
              child: _isSaving
                  ? SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: accent),
                    )
                  : Text('Save',
                      style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w700,
                          fontSize: 16)),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: c.textMuted))
          : SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 28),
                  _Label('CLIP NAME'),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _nameController,
                    style: TextStyle(color: c.textPrimary, fontSize: 16),
                    cursorColor: accent,
                    decoration: InputDecoration(
                      hintText: 'Enter a name...',
                      hintStyle: TextStyle(color: c.textMuted),
                      filled: true,
                      fillColor: c.surfaceCard,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide:
                              BorderSide(color: accent, width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 28),
                  _Label('CATEGORY'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _categories.map((cat) {
                      final sel = _selectedCategory == cat;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedCategory = cat),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: sel
                                ? accent.withValues(alpha: 0.18)
                                : c.surfaceCard,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: sel ? accent : c.border,
                              width: 1.5,
                            ),
                          ),
                          child: Text(cat,
                              style: TextStyle(
                                  color: sel ? accent : c.textSecondary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 28),
                  _Label('ICON'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _emojis.map((e) {
                      final sel = _selectedEmoji == e;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedEmoji = e),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 50,
                          height: 50,
                          decoration: BoxDecoration(
                            color: sel
                                ? accent.withValues(alpha: 0.18)
                                : c.surfaceElevated,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: sel ? accent : Colors.transparent,
                              width: 1.5,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(e,
                              style: const TextStyle(fontSize: 24)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 32),

                  // ── Trim section ──────────────────────────────────────────
                  _Label('TRIM'),
                  const SizedBox(height: 6),
                  Text(
                    'Drag the handles to set start and end points',
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Waveform + trim overlay
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: c.surfaceCard,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: c.borderSubtle),
                      ),
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 12),
                      child: LayoutBuilder(builder: (context, constraints) {
                        final waveWidth = constraints.maxWidth;
                        // spacing = (width - 2) / N ensures bar i lands at
                        // (i+1)*spacing, so the last bar is at width-2 px —
                        // just inside the painter's strict `dx < width` check.
                        final spacing = (waveWidth - 2.0) / _kWaveSamples;
                        final thickness = (spacing * 0.55).clamp(2.0, 7.0);
                        return SizedBox(
                          width: waveWidth,
                          height: 90,
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              // AbsorbPointer prevents the waveform widget
                              // from claiming drag events meant for handles.
                              AbsorbPointer(
                                child: AudioFileWaveforms(
                                  playerController: _playerController,
                                  size: Size(waveWidth, 90),
                                  waveformType: WaveformType.fitWidth,
                                  playerWaveStyle: PlayerWaveStyle(
                                    fixedWaveColor: const Color(0xFF3A3A3A),
                                    liveWaveColor: const Color(0xFF5A5A8A),
                                    showSeekLine: false,
                                    spacing: spacing,
                                    waveThickness: thickness,
                                  ),
                                ),
                              ),
                              // Trim overlay shares the same waveWidth so
                              // handle positions map to the same time scale.
                              Positioned.fill(
                                child: _TrimOverlay(
                                  trimStart: _trimStart,
                                  trimEnd: _trimEnd,
                                  width: waveWidth,
                                  onStartChanged: _onTrimStartChanged,
                                  onEndChanged: _onTrimEndChanged,
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Time labels
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _TimeLabel(_fmt(_trimStart * _totalDuration)),
                        _TimeLabel(
                          '${_fmt((_trimEnd - _trimStart) * _totalDuration)} selected',
                          dim: true,
                          fontSize: 11,
                        ),
                        _TimeLabel(_fmt(_trimEnd * _totalDuration)),
                      ],
                    ),
                  ),

                  const SizedBox(height: 28),
                  Center(
                    child: GestureDetector(
                      onTap: _togglePlayback,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: accent.withValues(alpha: 0.12),
                          border: Border.all(
                              color: accent.withValues(alpha: 0.5),
                              width: 1.5),
                        ),
                        child: Icon(
                          _isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: accent,
                          size: 34,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
    );
  }
}

// ── Trim overlay ──────────────────────────────────────────────────────────────

class _TrimOverlay extends StatefulWidget {
  final double trimStart;
  final double trimEnd;
  // Explicit width passed from the same LayoutBuilder that sizes the waveform,
  // so handle positions always map to the exact same pixel scale.
  final double width;
  final ValueChanged<double> onStartChanged;
  final ValueChanged<double> onEndChanged;

  const _TrimOverlay({
    required this.trimStart,
    required this.trimEnd,
    required this.width,
    required this.onStartChanged,
    required this.onEndChanged,
  });

  @override
  State<_TrimOverlay> createState() => _TrimOverlayState();
}

class _TrimOverlayState extends State<_TrimOverlay> {
  String? _activeHandle;

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    final startX = widget.trimStart * w;
    final endX = widget.trimEnd * w;

    // Listener bypasses the gesture arena entirely — no competition with the
    // parent ScrollView. localPosition.dx is the absolute finger X within
    // this widget; dividing by the known width gives a perfect 0–1 value.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        final x = e.localPosition.dx;
        _activeHandle =
            (x - startX).abs() <= (x - endX).abs() ? 'start' : 'end';
      },
      onPointerMove: (e) {
        if (_activeHandle == null) return;
        final pos = (e.localPosition.dx / w).clamp(0.0, 1.0);
        if (_activeHandle == 'start') {
          widget.onStartChanged(pos.clamp(0.0, widget.trimEnd - 0.02));
        } else {
          widget.onEndChanged(pos.clamp(widget.trimStart + 0.02, 1.0));
        }
      },
      onPointerUp: (_) => _activeHandle = null,
      onPointerCancel: (_) => _activeHandle = null,
      child: CustomPaint(
        size: Size(w, 90),
        painter:
            _TrimPainter(trimStart: widget.trimStart, trimEnd: widget.trimEnd, accent: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _TrimPainter extends CustomPainter {
  final double trimStart;
  final double trimEnd;
  final Color accent;

  const _TrimPainter({required this.trimStart, required this.trimEnd, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final startX = trimStart * size.width;
    final endX = trimEnd * size.width;

    // ── Darken untrimmed regions ──────────────────────────────────────────
    final shadow = Paint()..color = const Color(0xBB000000);
    if (startX > 0) {
      canvas.drawRect(
          Rect.fromLTRB(0, 0, startX, size.height), shadow);
    }
    if (endX < size.width) {
      canvas.drawRect(
          Rect.fromLTRB(endX, 0, size.width, size.height), shadow);
    }

    // ── Tint selected region ─────────────────────────────────────────────
    canvas.drawRect(
      Rect.fromLTRB(startX, 0, endX, size.height),
      Paint()..color = accent.withValues(alpha: 0.12),
    );

    // ── Handle lines ─────────────────────────────────────────────────────
    final line = Paint()
      ..color = accent
      ..strokeWidth = 2;
    canvas.drawLine(Offset(startX, 0), Offset(startX, size.height), line);
    canvas.drawLine(Offset(endX, 0), Offset(endX, size.height), line);

    // ── Grab tabs (top + bottom of each handle) ───────────────────────────
    _drawTab(canvas, startX, 0, size.height, atTop: true);
    _drawTab(canvas, startX, 0, size.height, atTop: false);
    _drawTab(canvas, endX, 0, size.height, atTop: true);
    _drawTab(canvas, endX, 0, size.height, atTop: false);
  }

  void _drawTab(
      Canvas canvas, double x, double top, double bottom,
      {required bool atTop}) {
    const tabW = 18.0;
    const tabH = 20.0;
    const r = 5.0;

    final tabTop = atTop ? top : bottom - tabH;
    final rect = Rect.fromLTWH(x - tabW / 2, tabTop, tabW, tabH);

    // Rounded on the outer corners, square on the inner edge
    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: atTop ? const Radius.circular(r) : Radius.zero,
      topRight: atTop ? const Radius.circular(r) : Radius.zero,
      bottomLeft: atTop ? Radius.zero : const Radius.circular(r),
      bottomRight: atTop ? Radius.zero : const Radius.circular(r),
    );
    canvas.drawRRect(rrect, Paint()..color = accent);

    // Grip lines
    final grip = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final midY = tabTop + tabH / 2;
    canvas.drawLine(Offset(x - 4, midY - 2.5), Offset(x + 4, midY - 2.5), grip);
    canvas.drawLine(Offset(x - 4, midY + 2.5), Offset(x + 4, midY + 2.5), grip);
  }

  @override
  bool shouldRepaint(_TrimPainter old) =>
      old.trimStart != trimStart || old.trimEnd != trimEnd || old.accent != accent;
}

// ── Small helpers ─────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Text(
      text,
      style: TextStyle(
        color: c.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  final String text;
  final bool dim;
  final double fontSize;
  const _TimeLabel(this.text, {this.dim = false, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Text(
      text,
      style: TextStyle(
        color: dim ? c.textMuted : c.textSecondary,
        fontSize: fontSize,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
