import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../services/clip_player.dart';
import '../services/haptics.dart';
import '../services/mic_clip_recorder.dart';
import '../services/voice_effects.dart';
import '../services/wav.dart';
import '../theme/app_colors.dart';
import '../widgets/permission_denied_card.dart';
import '../widgets/share_card.dart' show soundrPlayStoreUrl;
import '../widgets/voice_changer_widgets.dart';
import 'clip_editor_screen.dart';

const _kMaxLength = Duration(seconds: 15);
const _kRate = MicClipRecorder.sampleRate;

enum _Phase { idle, recording, ready }

/// Voice changer: record a few seconds, then tap voices to hear yourself as
/// a chipmunk, a robot, in a stadium… and share it or add it to the
/// soundboard.
class VoiceChangerScreen extends StatefulWidget {
  /// Supplies 16-bit PCM at 44.1 kHz for each recording instead of the
  /// microphone, and skips the permission request (tests).
  @visibleForTesting
  final Stream<Uint8List> Function()? debugMic;

  const VoiceChangerScreen({super.key, this.debugMic});

  @override
  State<VoiceChangerScreen> createState() => _VoiceChangerScreenState();
}

class _VoiceChangerScreenState extends State<VoiceChangerScreen>
    with WidgetsBindingObserver {
  late final ClipPlayer _player = widget.debugMic == null
      ? ClipPlayer()
      : _SilentClipPlayer();
  MicClipRecorder? _rec;
  _Phase _phase = _Phase.idle;
  PermissionStatus? _micDenied;
  bool _starting = false;
  bool _stopping = false;
  bool _exporting = false;

  /// Recent input levels while recording, oldest first.
  final List<double> _levels = [];

  /// The current recording; [_takeId] changes with each one so renders of
  /// an older take are dropped.
  Float64List? _take;
  int _takeId = 0;
  List<double> _takePeaks = const [];

  VoiceEffect _selected = VoiceEffect.normal;
  final _rendered = <VoiceEffect, Float64List>{};
  final _renderPeaks = <VoiceEffect, List<double>>{};
  final _jobs = <VoiceEffect, Future<Float64List?>>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.dispose();
    _rec?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      if (_phase == _Phase.recording) _stopRecording();
      _player.stop();
    }
  }

  // ── Recording ───────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (_starting || _phase == _Phase.recording) return;
    _starting = true;
    try {
      if (widget.debugMic == null) {
        final status = await Permission.microphone.request();
        if (!mounted) return;
        if (!status.isGranted) {
          setState(() => _micDenied = status);
          return;
        }
      }
      await _player.stop();
      final rec = MicClipRecorder(
        maxLength: _kMaxLength,
        onAutoStop: _stopRecording,
        debugStream: widget.debugMic?.call(),
      );
      rec.level.addListener(() => _onLevel(rec));
      try {
        await rec.start();
      } catch (_) {
        rec.dispose();
        _snack('Couldn’t open the microphone');
        return;
      }
      if (!mounted) {
        rec.dispose();
        return;
      }
      final old = _rec;
      Haptics.medium();
      setState(() {
        _rec = rec;
        _phase = _Phase.recording;
        _micDenied = null;
        _levels.clear();
        _clearTake();
      });
      old?.dispose();
    } finally {
      _starting = false;
    }
  }

  void _onLevel(MicClipRecorder rec) {
    if (!mounted || rec != _rec || !rec.isRecording) return;
    setState(() {
      _levels.add(rec.level.value);
      if (_levels.length > 60) _levels.removeAt(0);
    });
  }

  Future<void> _stopRecording() async {
    final rec = _rec;
    if (rec == null || !rec.isRecording || _stopping) return;
    _stopping = true;
    final Float64List samples;
    try {
      samples = await rec.stop();
    } finally {
      _stopping = false;
    }
    if (!mounted) return;
    Haptics.light();
    var peak = 0.0;
    for (final v in samples) {
      peak = max(peak, v.abs());
    }
    if (samples.length < _kRate * 0.4 || peak < 0.003) {
      setState(() => _phase = _Phase.idle);
      _snack(
        samples.length < _kRate * 0.4
            ? 'That was too short — hold on a little longer'
            : 'We didn’t hear anything — try again closer to the mic',
      );
      return;
    }
    setState(() {
      _take = samples;
      _takeId++;
      _takePeaks = wavePeaks(samples);
      _selected = VoiceEffect.normal;
      _phase = _Phase.ready;
    });
  }

  void _clearTake() {
    _take = null;
    _takeId++;
    _takePeaks = const [];
    _rendered.clear();
    _renderPeaks.clear();
    _jobs.clear();
  }

  void _onMicTap() {
    if (_phase == _Phase.recording) {
      _stopRecording();
    } else {
      _startRecording();
    }
  }

  void _recordAgain() {
    Haptics.light();
    _player.stop();
    _startRecording();
  }

  // ── Effects ─────────────────────────────────────────────────────────────

  bool _isRendering(VoiceEffect e) =>
      _jobs.containsKey(e) && !_rendered.containsKey(e);

  /// The take with [e] applied, rendered off the UI thread once and cached.
  Future<Float64List?> _render(VoiceEffect e) {
    final done = _rendered[e];
    if (done != null) return Future.value(done);
    final pending = _jobs[e];
    if (pending != null) return pending;
    final job = _doRender(e);
    _jobs[e] = job;
    setState(() {});
    return job;
  }

  Future<Float64List?> _doRender(VoiceEffect e) async {
    final take = _take;
    final id = _takeId;
    if (take == null) return null;
    try {
      final out = await compute(renderVoiceEffect, (
        e,
        take,
      ), debugLabel: 'voice ${e.name}');
      if (!mounted || id != _takeId) return null;
      setState(() {
        _rendered[e] = out;
        _renderPeaks[e] = wavePeaks(out);
      });
      return out;
    } catch (_) {
      if (!mounted || id != _takeId) return null;
      setState(() => _jobs.remove(e));
      _snack('Couldn’t make the ${e.label.toLowerCase()} voice');
      return null;
    }
  }

  Future<void> _tapEffect(VoiceEffect e) async {
    if (_player.playing.value == e) {
      Haptics.light();
      await _player.stop();
      return;
    }
    Haptics.selection();
    setState(() => _selected = e);
    await _player.stop();
    final out = await _render(e);
    if (out == null || !mounted || _selected != e || _phase != _Phase.ready) {
      return;
    }
    await _player.play(out, tag: e, sampleRate: _kRate);
  }

  void _tapCard() {
    if (_player.isPlaying) {
      Haptics.light();
      _player.stop();
    } else {
      _tapEffect(_selected);
    }
  }

  // ── Export ──────────────────────────────────────────────────────────────

  Future<void> _share() async {
    if (_exporting) return;
    Haptics.light();
    final e = _selected;
    setState(() => _exporting = true);
    try {
      final out = await _render(e);
      if (out == null || !mounted) return;
      final path = await Wav.writeTemp(
        out,
        name: 'soundr_${e.name}_voice',
        sampleRate: _kRate,
      );
      await Share.shareXFiles(
        [XFile(path, mimeType: 'audio/wav')],
        text: e == VoiceEffect.normal
            ? 'Made with Soundr\n$soundrPlayStoreUrl'
            : 'My ${e.label.toLowerCase()} voice ${e.emoji} — made with Soundr\n$soundrPlayStoreUrl',
      );
    } catch (_) {
      _snack('Couldn’t share — try again');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _addToSoundboard() async {
    if (_exporting) return;
    Haptics.light();
    final e = _selected;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    setState(() => _exporting = true);
    String? path;
    try {
      final out = await _render(e);
      if (out == null || !mounted) return;
      await _player.stop();
      path = await Wav.writeTemp(
        out,
        name: 'voice_${e.name}_${DateTime.now().millisecondsSinceEpoch}',
        sampleRate: _kRate,
      );
    } catch (_) {
      _snack('Couldn’t save the clip — try again');
      return;
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
    final saved = await nav.push<bool>(
      MaterialPageRoute(builder: (_) => ClipEditorScreen(filePath: path!)),
    );
    if (saved == true && mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e == VoiceEffect.normal
                ? 'Added to your soundboard'
                : '${e.label} voice added to your soundboard',
          ),
        ),
      );
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Voice Changer',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _micDenied != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: PermissionDeniedCard(
                    permission: Permission.microphone,
                    icon: Icons.mic_rounded,
                    permissionLabel: 'Microphone',
                    purpose:
                        'The voice changer records a few seconds of your voice to play it back with effects. '
                        'Everything stays on your phone unless you share it.',
                    onGranted: () {
                      if (!mounted) return;
                      setState(() => _micDenied = null);
                    },
                  ),
                ),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _phase == _Phase.ready
                    ? KeyedSubtree(
                        key: const ValueKey('effects'),
                        child: _buildEffects(c),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('record'),
                        child: _buildRecorder(c),
                      ),
              ),
      ),
    );
  }

  Widget _buildRecorder(AppColors c) {
    final p = VoicePalette.of(context);
    final recording = _phase == _Phase.recording;
    final rec = _rec;
    final elapsed = recording && rec != null
        ? rec.elapsed.value
        : Duration.zero;
    final progress = elapsed.inMilliseconds / _kMaxLength.inMilliseconds;
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxHeight < 560;
        final size = compact ? 124.0 : 148.0;
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: box.maxHeight,
              minWidth: box.maxWidth,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(height: compact ? 8 : 16),
                  SizedBox(
                    height: compact ? 24 : 32,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: recording ? 0 : 1,
                      child: Text(
                        'Record, then pick a voice',
                        style: TextStyle(color: c.textSecondary, fontSize: 14),
                      ),
                    ),
                  ),
                  SizedBox(height: compact ? 4 : 20),
                  VoiceMicButton(
                    recording: recording,
                    level: recording ? (rec?.level.value ?? 0) : 0,
                    progress: progress,
                    size: size,
                    onTap: _onMicTap,
                  ),
                  SizedBox(height: compact ? 8 : 16),
                  Text(
                    recording ? formatClipTime(elapsed) : 'Tap to record',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: recording ? 34 : 26,
                      fontWeight: FontWeight.w800,
                      height: 1.15,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    recording
                        ? 'Tap to stop  ·  up to ${_kMaxLength.inSeconds} s'
                        : 'Say something silly — up to ${_kMaxLength.inSeconds} seconds',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textSecondary, fontSize: 14),
                  ),
                  SizedBox(height: compact ? 14 : 24),
                  SizedBox(
                    width: 240,
                    height: 44,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: recording ? 1 : 0,
                      child: LiveLevelBars(levels: _levels),
                    ),
                  ),
                  SizedBox(height: compact ? 16 : 36),
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: recording ? 0.35 : 1,
                    child: _VoicePreviewStrip(palette: p, colors: c),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEffects(AppColors c) {
    final shownEffect = _rendered.containsKey(_selected)
        ? _selected
        : VoiceEffect.normal;
    final shown = shownEffect == VoiceEffect.normal
        ? _take
        : _rendered[shownEffect];
    final peaks = shownEffect == VoiceEffect.normal
        ? _takePeaks
        : _renderPeaks[shownEffect]!;
    final duration = Duration(
      microseconds: (shown?.length ?? 0) * 1000000 ~/ _kRate,
    );

    return ValueListenableBuilder<Object?>(
      valueListenable: _player.playing,
      builder: (context, playingTag, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: VoiceWaveformCard(
                title: _selected == VoiceEffect.normal
                    ? 'Your recording'
                    : '${_selected.label} voice',
                emoji: _selected == VoiceEffect.normal ? null : _selected.emoji,
                duration: duration,
                peaks: peaks,
                progress: _player.progress,
                playing: playingTag != null && playingTag == shownEffect,
                busy: _isRendering(_selected),
                onTap: _tapCard,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pick a voice',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      playingTag != null ? 'Tap again to stop' : 'Tap to play',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textSecondary, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final cols = box.maxWidth >= 600 ? 4 : 3;
                  final rows = (VoiceEffect.values.length / cols).ceil();
                  const gap = 10.0, padH = 16.0, padV = 4.0;
                  final tileW =
                      (box.maxWidth - 2 * padH - (cols - 1) * gap) / cols;
                  final fit =
                      (box.maxHeight - 2 * padV - (rows - 1) * gap) / rows;
                  final tileH = fit.clamp(64.0, 120.0);
                  return GridView.count(
                    crossAxisCount: cols,
                    padding: const EdgeInsets.symmetric(
                      horizontal: padH,
                      vertical: padV,
                    ),
                    mainAxisSpacing: gap,
                    crossAxisSpacing: gap,
                    childAspectRatio: tileW / tileH,
                    children: [
                      for (final e in VoiceEffect.values)
                        VoiceEffectTile(
                          effect: e,
                          selected: e == _selected,
                          rendering: _isRendering(e),
                          playing: playingTag == e,
                          progress: _player.progress,
                          compact: tileH < 84,
                          onTap: () => _tapEffect(e),
                        ),
                    ],
                  );
                },
              ),
            ),
            _ActionBar(
              exporting: _exporting,
              onRecordAgain: _recordAgain,
              onShare: _share,
              onAdd: _addToSoundboard,
            ),
          ],
        );
      },
    );
  }
}

/// A row of the voices on the empty screen, hinting at what's to come.
class _VoicePreviewStrip extends StatelessWidget {
  final VoicePalette palette;
  final AppColors colors;

  const _VoicePreviewStrip({required this.palette, required this.colors});

  @override
  Widget build(BuildContext context) {
    final emojis = VoiceEffect.values
        .where((e) => e != VoiceEffect.normal)
        .take(8);
    return ExcludeSemantics(
      child: Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: [
                for (final e in emojis)
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: colors.surfaceCard,
                      border: Border.all(color: colors.borderSubtle),
                    ),
                    child: Text(
                      e.emoji,
                      style: const TextStyle(fontSize: 17, height: 1.15),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${VoiceEffect.values.length - 1} voices to try',
            style: TextStyle(color: colors.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final bool exporting;
  final VoidCallback onRecordAgain;
  final VoidCallback onShare;
  final VoidCallback onAdd;

  const _ActionBar({
    required this.exporting,
    required this.onRecordAgain,
    required this.onShare,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final outlined = OutlinedButton.styleFrom(
      foregroundColor: c.textPrimary,
      side: BorderSide(color: c.border),
      minimumSize: const Size.fromHeight(48),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: TextStyle(
        fontFamily: font,
        fontSize: 14.5,
        fontWeight: FontWeight.w600,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onRecordAgain,
                  icon: const Icon(Icons.mic_rounded, size: 19),
                  label: const Text(
                    'Record again',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: outlined,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: exporting ? null : onShare,
                  icon: const Icon(Icons.share_rounded, size: 19),
                  label: const Text(
                    'Share',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              onPressed: exporting ? null : onAdd,
              icon: const Icon(Icons.library_add_rounded, size: 20),
              label: const Text('Add to soundboard'),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                textStyle: TextStyle(
                  fontFamily: font,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stands in for [ClipPlayer] in tests: SoLoud's FFI isn't loaded under
/// `flutter test`, so this skips audio and just runs the progress clock
/// (counted in ticks, so it follows the test's fake time).
class _SilentClipPlayer extends ClipPlayer {
  Timer? _ticker;

  @override
  Future<void> play(
    Float64List samples, {
    Object tag = true,
    int sampleRate = 44100,
  }) async {
    await stop();
    final totalMs = samples.length * 1000 / sampleRate;
    if (totalMs <= 0) return;
    playing.value = tag;
    progress.value = 0;
    var ms = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: 30), (_) {
      ms += 30;
      if (ms >= totalMs) {
        stop();
      } else {
        progress.value = ms / totalMs;
      }
    });
  }

  @override
  Future<void> stop() async {
    _ticker?.cancel();
    _ticker = null;
    progress.value = null;
    playing.value = null;
  }
}
