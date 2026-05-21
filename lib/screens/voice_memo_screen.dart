import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';

import '../theme/app_colors.dart';

// ── Data model ───────────────────────────────────────────────────────────────

class _Memo {
  final String id;
  String name;
  final String path;
  final int durationSec;
  final DateTime createdAt;

  _Memo({
    required this.id,
    required this.name,
    required this.path,
    required this.durationSec,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'durationSec': durationSec,
        'createdAt': createdAt.toIso8601String(),
      };

  factory _Memo.fromJson(Map<String, dynamic> j) => _Memo(
        id: j['id'] as String,
        name: j['name'] as String,
        path: j['path'] as String,
        durationSec: j['durationSec'] as int,
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

// ── Screen ───────────────────────────────────────────────────────────────────

class VoiceMemoScreen extends StatefulWidget {
  const VoiceMemoScreen({super.key});

  @override
  State<VoiceMemoScreen> createState() => _VoiceMemoScreenState();
}

class _VoiceMemoScreenState extends State<VoiceMemoScreen> {
  // Recording
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _streamSub;
  IOSink? _pcmSink;
  Completer<void>? _streamDone;

  bool _recording = false;
  bool _processing = false;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;

  List<double> _ampHistory = List.filled(30, 0.0);

  // Memos
  List<_Memo> _memos = [];

  // Paths
  late Directory _memosDir;
  late File _indexFile;

  @override
  void initState() {
    super.initState();
    _initStorage();
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _streamSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ── Storage ────────────────────────────────────────────────────────────────

  Future<void> _initStorage() async {
    final docDir = await getApplicationDocumentsDirectory();
    _memosDir = Directory(p.join(docDir.path, 'voice_memos'));
    _indexFile = File(p.join(docDir.path, 'voice_memo_index.json'));
    if (!await _memosDir.exists()) {
      await _memosDir.create(recursive: true);
    }
    await _loadMemos();
  }

  Future<void> _loadMemos() async {
    if (!await _indexFile.exists()) return;
    try {
      final raw = await _indexFile.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      final parsed = list
          .map((e) => _Memo.fromJson(e as Map<String, dynamic>))
          .where((m) => File(m.path).existsSync())
          .toList();
      if (mounted) setState(() => _memos = parsed);
    } catch (_) {
      // Corrupt index — start fresh
    }
  }

  Future<void> _saveMemos() async {
    final json = jsonEncode(_memos.map((m) => m.toJson()).toList());
    await _indexFile.writeAsString(json);
  }

  // ── WAV builder ────────────────────────────────────────────────────────────

  static Future<void> _buildWavFile(String pcmPath, String wavPath) async {
    const sampleRate = 44100, channels = 1, bitsPerSample = 16;
    final pcm = await File(pcmPath).readAsBytes();
    final dataSize = pcm.length;
    final header = ByteData(44);
    void str(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    header.setUint32(4, 36 + dataSize, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(
        28, sampleRate * channels * bitsPerSample ~/ 8, Endian.little);
    header.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    str(36, 'data');
    header.setUint32(40, dataSize, Endian.little);
    final out = File(wavPath).openWrite();
    out.add(header.buffer.asUint8List());
    out.add(pcm);
    await out.flush();
    await out.close();
  }

  // ── Recording ──────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
      return;
    }

    if (!await _memosDir.exists()) {
      await _memosDir.create(recursive: true);
    }

    final ts = DateTime.now().millisecondsSinceEpoch.toString();
    final pcmPath = p.join(_memosDir.path, 'tmp_$ts.pcm');
    final pcmFile = File(pcmPath);
    _pcmSink = pcmFile.openWrite();
    _streamDone = Completer<void>();

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
      ),
    );

    _streamSub = stream.listen(
      (chunk) {
        _pcmSink?.add(chunk);
        // Compute RMS amplitude
        double sum = 0.0;
        final samples = chunk.length ~/ 2;
        if (samples > 0) {
          final bd = ByteData.sublistView(chunk);
          for (var i = 0; i < samples; i++) {
            final s = bd.getInt16(i * 2, Endian.little) / 32768.0;
            sum += s * s;
          }
          final rms = sqrt(sum / samples);
          final normalized = (rms * 4.0).clamp(0.0, 1.0);
          setState(() {
            _ampHistory = [..._ampHistory.skip(1), normalized];
          });
        }
      },
      onDone: () {
        if (!(_streamDone?.isCompleted ?? true)) {
          _streamDone?.complete();
        }
      },
      onError: (e) {
        if (!(_streamDone?.isCompleted ?? true)) {
          _streamDone?.completeError(e);
        }
      },
    );

    _elapsed = Duration.zero;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });

    setState(() {
      _recording = true;
      _ampHistory = List.filled(30, 0.0);
    });

    // Store pcmPath for stop
    _currentPcmPath = pcmPath;
    _currentTs = ts;
  }

  String _currentPcmPath = '';
  String _currentTs = '';

  Future<void> _stopRecording() async {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    final capturedElapsed = _elapsed;

    setState(() => _processing = true);

    await _recorder.stop();

    // Wait for stream to finish flushing (3s timeout)
    try {
      await _streamDone?.future.timeout(const Duration(seconds: 3));
    } catch (_) {}

    await _streamSub?.cancel();
    _streamSub = null;
    await _pcmSink?.flush();
    await _pcmSink?.close();
    _pcmSink = null;

    final pcmPath = _currentPcmPath;
    final ts = _currentTs;

    final wavPath = p.join(_memosDir.path, '$ts.wav');

    try {
      await _buildWavFile(pcmPath, wavPath);
    } catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _processing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save recording: $e')),
        );
      }
      return;
    }

    // Delete temp PCM
    try {
      await File(pcmPath).delete();
    } catch (_) {}

    final memo = _Memo(
      id: ts,
      name: 'Memo ${_memos.length + 1}',
      path: wavPath,
      durationSec: capturedElapsed.inSeconds,
      createdAt: DateTime.now(),
    );

    _memos.insert(0, memo);
    await _saveMemos();

    setState(() {
      _recording = false;
      _processing = false;
      _elapsed = Duration.zero;
      _ampHistory = List.filled(30, 0.0);
    });
  }

  // ── Memo actions ───────────────────────────────────────────────────────────

  Future<void> _deleteMemo(_Memo memo) async {
    final c = Theme.of(context).extension<AppColors>()!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text('Delete memo?', style: TextStyle(color: c.textPrimary)),
        content: Text(
          'This will permanently delete "${memo.name}".',
          style: TextStyle(color: c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _memos.remove(memo);
    await _saveMemos();
    try {
      await File(memo.path).delete();
    } catch (_) {}
    setState(() {});
  }

  Future<void> _renameMemo(_Memo memo) async {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    // _MemoRenameDialog owns the TextEditingController and FocusNode,
    // so their lifecycle is properly tied to the dialog widget and cleaned
    // up (unfocus → dispose) before the route element is deactivated.
    // This prevents the _dependents.isEmpty assertion that fires when
    // autofocus TextField focus nodes aren't cleaned up on dismiss.
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _MemoRenameDialog(
        initialName: memo.name,
        colors: c,
        accent: accent,
      ),
    );

    if (newName != null && mounted) {
      memo.name = newName;
      await _saveMemos();
      setState(() {});
    }
  }

  void _shareMemo(_Memo memo) {
    Share.shareXFiles([XFile(memo.path)], subject: memo.name);
  }

  // ── Format helpers ─────────────────────────────────────────────────────────

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    return '${months[d.month - 1]} ${d.day} · $hour:$minute $ampm';
  }

  static String _formatDuration(int sec) {
    final m = sec ~/ 60;
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.scaffoldBg,
        surfaceTintColor: Colors.transparent,
        title: Text('Voice Memos', style: TextStyle(color: c.textPrimary)),
        iconTheme: IconThemeData(color: c.textPrimary),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Recording card
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: _buildRecordingCard(c, accent),
            ),
            // Memo list
            Expanded(
              child: _memos.isEmpty
                  ? Center(
                      child: Text(
                        'No recordings yet.\nTap the mic to start.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textMuted, height: 1.6),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: _memos.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final memo = _memos[i];
                        return _MemoRow(
                          key: ValueKey(memo.id),
                          memo: memo,
                          colors: c,
                          accent: accent,
                          formatDate: _formatDate,
                          formatDuration: _formatDuration,
                          onDelete: () => _deleteMemo(memo),
                          onRename: () => _renameMemo(memo),
                          onShare: () => _shareMemo(memo),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingCard(AppColors c, Color accent) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      child: _processing
          ? _buildProcessingState(c)
          : _recording
              ? _buildRecordingState(c, accent)
              : _buildIdleState(c, accent),
    );
  }

  Widget _buildIdleState(AppColors c, Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _startRecording,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.12),
              border: Border.all(color: accent.withValues(alpha: 0.4), width: 2),
            ),
            child: Icon(Icons.mic_rounded, color: accent, size: 36),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Tap to record',
          style: TextStyle(color: c.textSecondary, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildRecordingState(AppColors c, Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Amplitude bars
        SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(_ampHistory.length, (i) {
              final amp = _ampHistory[i];
              final height = 6.0 + amp * 42.0;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  width: 4,
                  height: height,
                  decoration: BoxDecoration(
                    color: Color.lerp(
                      accent.withValues(alpha: 0.35),
                      accent,
                      amp,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 14),
        // Elapsed time
        Text(
          _formatDuration(_elapsed.inSeconds),
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 16),
        // Stop button
        _PulsingButton(
          onTap: _stopRecording,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.red,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.4),
                  blurRadius: 12,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.stop_rounded, color: Colors.white, size: 32),
          ),
        ),
      ],
    );
  }

  Widget _buildProcessingState(AppColors c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation(
              Theme.of(context).colorScheme.primary),
          strokeWidth: 2.5,
        ),
        const SizedBox(height: 14),
        Text('Saving…', style: TextStyle(color: c.textSecondary, fontSize: 14)),
      ],
    );
  }
}

// ── Pulsing stop button ───────────────────────────────────────────────────────

class _PulsingButton extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;

  const _PulsingButton({required this.child, required this.onTap});

  @override
  State<_PulsingButton> createState() => _PulsingButtonState();
}

class _PulsingButtonState extends State<_PulsingButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 1.0, end: 1.08).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: GestureDetector(onTap: widget.onTap, child: widget.child),
    );
  }
}

// ── Memo row ─────────────────────────────────────────────────────────────────

class _MemoRow extends StatefulWidget {
  final _Memo memo;
  final AppColors colors;
  final Color accent;
  final String Function(DateTime) formatDate;
  final String Function(int) formatDuration;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onShare;

  const _MemoRow({
    super.key,
    required this.memo,
    required this.colors,
    required this.accent,
    required this.formatDate,
    required this.formatDuration,
    required this.onDelete,
    required this.onRename,
    required this.onShare,
  });

  @override
  State<_MemoRow> createState() => _MemoRowState();
}

class _MemoRowState extends State<_MemoRow> {
  PlayerController? _playerCtrl;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int>? _positionSub;
  bool _expanded = false;
  bool _prepared = false;
  bool _preparing = false;
  PlayerState _playerState = PlayerState.stopped;

  int _positionMs = 0;
  int _durationMs = 0;

  // True once playback has reached the end (paused at EOF via FinishMode.pause).
  // Next play/pause press will rewind to 0 first.
  bool _atEnd = false;
  // Set immediately before a user-initiated pause, so the state listener can
  // distinguish manual pauses from natural EOF transitions.
  bool _manualPause = false;

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _playerCtrl?.dispose();
    super.dispose();
  }

  Future<void> _toggleExpand() async {
    if (_expanded) {
      await _playerCtrl?.pausePlayer();
      setState(() => _expanded = false);
      return;
    }

    setState(() => _expanded = true);

    if (!_prepared && !_preparing) {
      _preparing = true;
      _playerCtrl ??= PlayerController();

      _stateSub = _playerCtrl!.onPlayerStateChanged.listen((state) {
        if (!mounted) return;
        final prev = _playerState;
        setState(() => _playerState = state);
        // playing → (paused | stopped) is either a manual pause (resume from
        // current position) or natural EOF (rewind on next play). The
        // _manualPause flag, set right before pausePlayer(), tells them apart.
        if (prev == PlayerState.playing &&
            (state == PlayerState.paused || state == PlayerState.stopped)) {
          if (_manualPause) {
            _manualPause = false;
            _atEnd = false;
          } else {
            _atEnd = true;
          }
        }
        if (state == PlayerState.playing) _atEnd = false;
      });

      _positionSub = _playerCtrl!.onCurrentDurationChanged.listen((pos) {
        if (mounted) setState(() => _positionMs = pos);
      });

      try {
        await _playerCtrl!.preparePlayer(
          path: widget.memo.path,
          shouldExtractWaveform: true,
          noOfSamples: 60,
        );
        // Mark prepared as soon as prepare succeeds — the waveform should render
        // regardless of whether the optional calls below succeed.
        if (mounted) setState(() => _prepared = true);

        // Best-effort: tell the player to pause at EOF instead of stopping.
        // If this fails we fall back to the re-prepare path in _togglePlayPause.
        try {
          await _playerCtrl!.setFinishMode(finishMode: FinishMode.pause);
        } catch (_) {}

        // Best-effort: pull total duration for the time display.
        try {
          final dur = await _playerCtrl!.getDuration(DurationType.max);
          if (mounted) setState(() => _durationMs = dur);
        } catch (_) {}
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not load audio: $e')),
          );
        }
      }
      _preparing = false;
    }
  }

  /// Returns the player to a "ready to play from 0" state.
  /// - If state is `paused` (FinishMode.pause worked): just `seekTo(0)`.
  /// - If state is `stopped` (FinishMode.stop fallback): native resources are
  ///   freed at EOF, so we re-prepare without re-extracting the waveform.
  Future<bool> _rewindForReplay() async {
    if (_playerCtrl == null) return false;
    if (_playerState == PlayerState.stopped) {
      try {
        await _playerCtrl!.preparePlayer(
          path: widget.memo.path,
          shouldExtractWaveform: false,
          noOfSamples: 60,
        );
        try {
          await _playerCtrl!.setFinishMode(finishMode: FinishMode.pause);
        } catch (_) {}
      } catch (_) {
        return false;
      }
    } else {
      try {
        await _playerCtrl!.seekTo(0);
      } catch (_) {}
    }
    _atEnd = false;
    if (mounted) setState(() => _positionMs = 0);
    return true;
  }

  Future<void> _togglePlayPause() async {
    if (_playerCtrl == null || !_prepared) return;
    if (_playerState == PlayerState.playing) {
      _manualPause = true;
      await _playerCtrl!.pausePlayer();
      return;
    }
    if (_atEnd) {
      final ok = await _rewindForReplay();
      if (!ok) return;
    }
    // Otherwise startPlayer() resumes from the current position.
    await _playerCtrl!.startPlayer();
  }

  /// Seek the player based on a tap/drag x-coordinate over the waveform.
  /// Uses _durationMs (or recorded duration as fallback) — sidesteps the
  /// audio_waveforms package's broken internal maxDuration calculation.
  void _seekFromGesture(double dx, double width) {
    if (_playerCtrl == null || !_prepared || width <= 0) return;
    final totalMs = _durationMs > 0 ? _durationMs : widget.memo.durationSec * 1000;
    if (totalMs <= 0) return;
    final proportion = (dx / width).clamp(0.0, 1.0);
    final targetMs = (proportion * totalMs).toInt();
    try {
      _playerCtrl!.seekTo(targetMs);
    } catch (_) {
      return;
    }
    _atEnd = false;
    if (mounted) setState(() => _positionMs = targetMs);
  }

  /// Always seeks to 0; restarts playback if currently playing,
  /// otherwise plays from the start.
  Future<void> _restart() async {
    if (_playerCtrl == null || !_prepared) return;
    final wasPlaying = _playerState == PlayerState.playing;
    if (wasPlaying) {
      _manualPause = true;
      try { await _playerCtrl!.pausePlayer(); } catch (_) {}
    }
    final ok = await _rewindForReplay();
    if (!ok) return;
    await _playerCtrl!.startPlayer();
  }

  String _formatMs(int ms) {
    final totalSec = ms ~/ 1000;
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    final accent = widget.accent;
    final memo = widget.memo;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _expanded ? accent.withValues(alpha: 0.4) : c.border,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Collapsed header
          InkWell(
            onTap: _toggleExpand,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withValues(alpha: 0.12),
                    ),
                    child: Icon(Icons.mic_rounded, color: accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          memo.name,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.formatDate(memo.createdAt),
                          style: TextStyle(color: c.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: c.textMuted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),

          // Expanded section
          if (_expanded) ...[
            Divider(height: 1, color: c.border),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Waveform — tap/drag to seek.
                  // audio_waveforms 1.3.0's built-in seek is broken: it uses
                  // playerController.maxDuration which is computed via
                  // getDuration() (defaulting to DurationType.current = 0),
                  // so every tap seeks to 0. We disable enableSeekGesture and
                  // wrap with our own GestureDetector that uses _durationMs.
                  if (_prepared && _playerCtrl != null)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (details) => _seekFromGesture(
                            details.localPosition.dx,
                            constraints.maxWidth,
                          ),
                          onHorizontalDragUpdate: (details) => _seekFromGesture(
                            details.localPosition.dx,
                            constraints.maxWidth,
                          ),
                          child: AudioFileWaveforms(
                            playerController: _playerCtrl!,
                            size: Size(constraints.maxWidth, 56),
                            waveformType: WaveformType.fitWidth,
                            enableSeekGesture: false,
                            playerWaveStyle: PlayerWaveStyle(
                              fixedWaveColor: accent.withValues(alpha: 0.28),
                              liveWaveColor: accent,
                              waveCap: StrokeCap.round,
                              waveThickness: 2.5,
                              spacing: 5,
                            ),
                          ),
                        );
                      },
                    )
                  else
                    Container(
                      height: 56,
                      alignment: Alignment.center,
                      child: _preparing
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation(accent),
                              ),
                            )
                          : Row(
                              children: List.generate(
                                40,
                                (i) => Expanded(
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 1),
                                    height: 4 +
                                        (sin(i * 0.5).abs() * 32).toDouble(),
                                    decoration: BoxDecoration(
                                      color: c.border,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  const SizedBox(height: 12),

                  // Transport row: Restart + Play/Pause + Time
                  Row(
                    children: [
                      // Restart — always seeks to 0
                      _RestartButton(
                        enabled: _prepared,
                        accent: accent,
                        muted: c.textMuted,
                        border: c.border,
                        onTap: _restart,
                      ),
                      const SizedBox(width: 10),

                      // Play / Pause — large primary action
                      GestureDetector(
                        onTap: _prepared ? _togglePlayPause : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _prepared
                                ? accent
                                : accent.withValues(alpha: 0.4),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.25),
                                blurRadius: 12,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: Icon(
                            _playerState == PlayerState.playing
                                ? Icons.pause_rounded
                                : (_atEnd
                                    ? Icons.replay_rounded
                                    : Icons.play_arrow_rounded),
                            color: Colors.white,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),

                      // Live time display
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            Text(
                              _formatMs(_positionMs),
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                            Text(
                              ' / ',
                              style: TextStyle(
                                color: c.textMuted,
                                fontSize: 14,
                              ),
                            ),
                            Text(
                              _durationMs > 0
                                  ? _formatMs(_durationMs)
                                  : widget.formatDuration(memo.durationSec),
                              style: TextStyle(
                                color: c.textMuted,
                                fontSize: 14,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Separator
                  Divider(height: 1, color: c.border),
                  const SizedBox(height: 6),

                  // Action row
                  Row(
                    children: [
                      _IconBtn(
                        icon: Icons.edit_outlined,
                        color: c.textMuted,
                        onTap: widget.onRename,
                        tooltip: 'Rename',
                      ),
                      _IconBtn(
                        icon: Icons.ios_share_rounded,
                        color: c.textMuted,
                        onTap: widget.onShare,
                        tooltip: 'Share',
                      ),
                      const Spacer(),
                      _IconBtn(
                        icon: Icons.delete_outline_rounded,
                        color: Colors.red.withValues(alpha: 0.7),
                        onTap: widget.onDelete,
                        tooltip: 'Delete',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Small icon button ─────────────────────────────────────────────────────────

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;

  const _IconBtn({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, color: color, size: 20),
        onPressed: onTap,
        splashRadius: 20,
        padding: const EdgeInsets.all(6),
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      ),
    );
  }
}

// ── Rename dialog ─────────────────────────────────────────────────────────────
// A StatefulWidget so it owns the TextEditingController and FocusNode.
// dispose() calls unfocus() before releasing the FocusNode, which clears all
// InheritedElement dependencies and prevents the _dependents.isEmpty crash
// that occurs when autofocus TextFields are dismissed via Navigator.pop.

class _MemoRenameDialog extends StatefulWidget {
  const _MemoRenameDialog({
    required this.initialName,
    required this.colors,
    required this.accent,
  });

  final String initialName;
  final AppColors colors;
  final Color accent;

  @override
  State<_MemoRenameDialog> createState() => _MemoRenameDialogState();
}

class _MemoRenameDialogState extends State<_MemoRenameDialog> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialName);
    _focus = FocusNode();
    // Request focus after the first frame so the route is fully mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.unfocus(); // clears all InheritedElement dependents before dispose
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return AlertDialog(
      backgroundColor: c.surfaceCard,
      title: Text('Rename memo', style: TextStyle(color: c.textPrimary)),
      content: TextField(
        controller: _ctrl,
        focusNode: _focus,
        maxLength: 40,
        style: TextStyle(color: c.textPrimary),
        decoration: InputDecoration(
          hintText: widget.initialName,
          hintStyle: TextStyle(color: c.textMuted),
          counterStyle: TextStyle(color: c.textMuted),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: c.borderSubtle),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: widget.accent),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
        ),
        TextButton(
          onPressed: () {
            final trimmed = _ctrl.text.trim();
            Navigator.pop(context, trimmed.isEmpty ? null : trimmed);
          },
          child: Text(
            'Save',
            style: TextStyle(
              color: widget.accent,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Restart button ────────────────────────────────────────────────────────────

class _RestartButton extends StatelessWidget {
  final bool enabled;
  final Color accent;
  final Color muted;
  final Color border;
  final VoidCallback onTap;

  const _RestartButton({
    required this.enabled,
    required this.accent,
    required this.muted,
    required this.border,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Restart',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.transparent,
            border: Border.all(
              color: enabled ? accent.withValues(alpha: 0.4) : border,
              width: 1.5,
            ),
          ),
          child: Icon(
            Icons.skip_previous_rounded,
            color: enabled ? accent : muted,
            size: 22,
          ),
        ),
      ),
    );
  }
}
