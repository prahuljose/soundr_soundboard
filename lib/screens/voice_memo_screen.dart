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

import '../services/haptics.dart';
import '../services/waveforms.dart';
import '../theme/app_colors.dart';
import '../widgets/permission_denied_card.dart';
import '../widgets/voice_memo_peaks.dart';
import '../widgets/voice_memo_record_panel.dart';
import '../widgets/voice_memo_tiles.dart';
import 'clip_editor_screen.dart';

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
  // When non-null, the recording-controls card is replaced with the
  // permission-denied card. Memo list below stays accessible.
  PermissionStatus? _micDenied;

  List<double> _ampHistory = List.filled(30, 0.0);

  // Memos
  List<_Memo> _memos = [];

  /// The open (expanded) memo, if any. Only it has a player.
  String? _activeId;

  /// Whether opening [_activeId] should start playback straight away.
  bool _autoplay = false;
  final Set<String> _requestedPeaks = {};

  // Search
  bool _searching = false;
  String _query = '';
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

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
    _searchFocus.dispose();
    _searchCtrl.dispose();
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
      if (mounted) setState(() => _micDenied = status);
      return;
    }
    if (mounted) setState(() => _micDenied = null);

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

    // Close its player (if open) before the file goes away.
    if (_activeId == memo.id && mounted) setState(() => _activeId = null);
    _memos.remove(memo);
    await _saveMemos();
    try {
      await File(memo.path).delete();
    } catch (_) {}
    if (mounted) setState(() {});
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

  /// Opens the clip editor on a copy of this memo. The editor saves the clip
  /// itself (and pops `true`); the soundboard reloads its clips on its side.
  Future<void> _addToSoundboard(_Memo memo) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ClipEditorScreen(filePath: memo.path)),
    );
    if (saved == true && mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text('“${memo.name}” added to your soundboard')),
      );
    }
  }

  void _open(_Memo memo, {required bool play}) {
    Haptics.light();
    setState(() {
      _activeId = memo.id;
      _autoplay = play;
    });
  }

  // ── Search ─────────────────────────────────────────────────────────────────

  void _startSearch() {
    Haptics.selection();
    setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searching) _searchFocus.requestFocus();
    });
  }

  void _endSearch() {
    _searchFocus.unfocus();
    _searchCtrl.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  List<_Memo> get _visibleMemos {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _memos;
    return _memos.where((m) => m.name.toLowerCase().contains(q)).toList();
  }

  // ── Waveforms ──────────────────────────────────────────────────────────────

  static const _rowBars = 10;

  List<double> _rowLevels(_Memo memo) {
    final cached = VoiceMemoPeaks.peek(memo.path, _rowBars);
    if (cached != null) return cached;
    if (_requestedPeaks.add(memo.path)) {
      VoiceMemoPeaks.of(memo.path, bars: _rowBars).then((_) {
        if (mounted) setState(() {});
      });
    }
    return Waveforms.placeholder(memo.path, _rowBars);
  }

  // ── Format helpers ─────────────────────────────────────────────────────────

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final hour = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final minute = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    final time = '$hour:$minute $ampm';

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final daysAgo = today.difference(day).inDays;
    final String date;
    if (daysAgo == 0) {
      date = 'Today';
    } else if (daysAgo == 1) {
      date = 'Yesterday';
    } else if (daysAgo > 1 && daysAgo < 7) {
      date = weekdays[d.weekday - 1];
    } else if (d.year == now.year) {
      date = '${months[d.month - 1]} ${d.day}';
    } else {
      date = '${months[d.month - 1]} ${d.day}, ${d.year}';
    }
    return '$date · $time';
  }

  static String _formatDuration(int sec) {
    final m = sec ~/ 60;
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// "4 memos · 6 min · stored only on this phone"
  String _summary() {
    final n = _memos.length;
    final total = _memos.fold<int>(0, (a, m) => a + m.durationSec);
    final String length;
    if (total < 60) {
      length = '$total sec';
    } else if (total < 3600) {
      length = '${(total / 60).round()} min';
    } else {
      final h = total ~/ 3600;
      final m = ((total % 3600) / 60).round();
      length = m == 0 ? '$h h' : '$h h $m min';
    }
    final count = n == 1 ? '1 memo' : '$n memos';
    return n == 0
        ? 'Stored only on this phone'
        : '$count · $length · stored only on this phone';
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final visible = _visibleMemos;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.scaffoldBg,
        surfaceTintColor: Colors.transparent,
        title: _searching
            ? Container(
                height: 44,
                decoration: BoxDecoration(
                  color: c.surfaceCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: c.border),
                ),
                alignment: Alignment.center,
                child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(color: c.textPrimary, fontSize: 16),
                  cursorColor: Theme.of(context).colorScheme.primary,
                  decoration: InputDecoration(
                    hintText: 'Search memos',
                    hintStyle: TextStyle(color: c.textSecondary, fontSize: 16),
                    prefixIcon:
                        Icon(Icons.search_rounded, size: 20, color: c.textSecondary),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              )
            : Text(
                'Voice memos',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
        iconTheme: IconThemeData(color: c.textPrimary),
        systemOverlayStyle:
            dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              onPressed: _searching ? _endSearch : _startSearch,
              tooltip: _searching ? 'Close search' : 'Search memos',
              icon: Icon(
                _searching ? Icons.close_rounded : Icons.search_rounded,
                size: 20,
              ),
              style: IconButton.styleFrom(
                foregroundColor: c.textPrimary,
                backgroundColor: c.surfaceCard,
                fixedSize: const Size(44, 44),
                minimumSize: const Size(44, 44),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: c.border),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
              child: Text(
                _summary(),
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ),
            Expanded(
              child: _memos.isEmpty
                  ? _EmptyState(
                      icon: Icons.mic_none_rounded,
                      title: 'No memos yet',
                      message:
                          'Tap the record button below to start.',
                    )
                  : visible.isEmpty
                      ? _EmptyState(
                          icon: Icons.search_off_rounded,
                          title: 'No matches',
                          message: 'No memo names contain “${_query.trim()}”.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                          itemCount: visible.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) {
                            final memo = visible[i];
                            if (memo.id == _activeId) {
                              return _MemoPlayer(
                                key: ValueKey('player-${memo.id}'),
                                memo: memo,
                                subtitle: _formatDate(memo.createdAt),
                                autoplay: _autoplay,
                                onCollapse: () =>
                                    setState(() => _activeId = null),
                                onRename: () => _renameMemo(memo),
                                onShare: () => _shareMemo(memo),
                                onDelete: () => _deleteMemo(memo),
                                onAddToSoundboard: () => _addToSoundboard(memo),
                              );
                            }
                            return VoiceMemoRow(
                              key: ValueKey('row-${memo.id}'),
                              title: memo.name,
                              subtitle: _formatDate(memo.createdAt),
                              duration: _formatDuration(memo.durationSec),
                              levels: _rowLevels(memo),
                              onPlay: () => _open(memo, play: true),
                              onOpen: () => _open(memo, play: false),
                            );
                          },
                        ),
            ),
            // Record button — replaced by the permission card when denied.
            if (_micDenied != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: PermissionDeniedCard(
                  permission: Permission.microphone,
                  icon: Icons.mic_rounded,
                  permissionLabel: 'Microphone',
                  purpose:
                      'Voice memos are recorded using your microphone and saved on this device only. '
                      'Nothing is uploaded or shared automatically.',
                  onGranted: () {
                    if (mounted) setState(() => _micDenied = null);
                  },
                ),
              )
            else
              VoiceMemoRecordPanel(
                state: _processing
                    ? VoiceMemoRecordState.saving
                    : _recording
                        ? VoiceMemoRecordState.recording
                        : VoiceMemoRecordState.idle,
                elapsed: _elapsed,
                levels: _ampHistory,
                onTap: () {
                  Haptics.medium();
                  _recording ? _stopRecording() : _startRecording();
                },
              ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: kVoiceMemoTint.withValues(alpha: 0.14),
                border: Border.all(color: kVoiceMemoTint.withValues(alpha: 0.35)),
              ),
              child: Icon(icon, color: voiceMemoTintText(context), size: 28),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textSecondary, fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Open memo (player) ───────────────────────────────────────────────────────

/// The expanded, current memo. Owns its [PlayerController]; only one exists at
/// a time, so opening another memo releases this one's player.
class _MemoPlayer extends StatefulWidget {
  final _Memo memo;
  final String subtitle;
  final bool autoplay;
  final VoidCallback onCollapse;
  final VoidCallback onRename;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback onAddToSoundboard;

  const _MemoPlayer({
    super.key,
    required this.memo,
    required this.subtitle,
    required this.autoplay,
    required this.onCollapse,
    required this.onRename,
    required this.onShare,
    required this.onDelete,
    required this.onAddToSoundboard,
  });

  @override
  State<_MemoPlayer> createState() => _MemoPlayerState();
}

class _MemoPlayerState extends State<_MemoPlayer> {
  static const _bars = 48;
  static const _speeds = [1.0, 1.5, 2.0];

  final PlayerController _playerCtrl = PlayerController();
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int>? _positionSub;
  bool _prepared = false;
  PlayerState _playerState = PlayerState.stopped;

  int _positionMs = 0;
  int _durationMs = 0;
  double _speed = 1.0;
  // Hidden if the platform player refuses a rate change.
  bool _speedSupported = true;
  late List<double> _levels;

  // True once playback has reached the end (paused at EOF via FinishMode.pause).
  // Next play/pause press will rewind to 0 first.
  bool _atEnd = false;
  // Set immediately before a user-initiated pause, so the state listener can
  // distinguish manual pauses from natural EOF transitions.
  bool _manualPause = false;

  int get _totalMs =>
      _durationMs > 0 ? _durationMs : widget.memo.durationSec * 1000;

  @override
  void initState() {
    super.initState();
    final path = widget.memo.path;
    _levels = VoiceMemoPeaks.peek(path, _bars) ??
        Waveforms.placeholder(path, _bars);
    VoiceMemoPeaks.of(path, bars: _bars).then((levels) {
      if (mounted) setState(() => _levels = levels);
    });
    _prepare();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _playerCtrl.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    _stateSub = _playerCtrl.onPlayerStateChanged.listen((state) {
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

    _positionSub = _playerCtrl.onCurrentDurationChanged.listen((pos) {
      if (mounted) setState(() => _positionMs = pos);
    });

    try {
      // The waveform is drawn from VoiceMemoPeaks, so skip the package's
      // (whole-file) extraction.
      await _playerCtrl.preparePlayer(
        path: widget.memo.path,
        shouldExtractWaveform: false,
      );
      if (!mounted) return;
      setState(() => _prepared = true);

      // Best-effort: tell the player to pause at EOF instead of stopping.
      // If this fails we fall back to the re-prepare path in _togglePlayPause.
      try {
        await _playerCtrl.setFinishMode(finishMode: FinishMode.pause);
      } catch (_) {}

      // Best-effort: pull total duration for the time display.
      try {
        final dur = await _playerCtrl.getDuration(DurationType.max);
        if (mounted && dur > 0) setState(() => _durationMs = dur);
      } catch (_) {}

      if (widget.autoplay && mounted) await _togglePlayPause();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load audio: $e')),
        );
      }
    }
  }

  Future<void> _applySpeed() async {
    if (_speed == 1.0) return;
    try {
      await _playerCtrl.setRate(_speed);
    } catch (_) {}
  }

  /// Returns the player to a "ready to play from 0" state.
  /// - If state is `paused` (FinishMode.pause worked): just `seekTo(0)`.
  /// - If state is `stopped` (FinishMode.stop fallback): native resources are
  ///   freed at EOF, so we re-prepare without re-extracting the waveform.
  Future<bool> _rewindForReplay() async {
    if (_playerState == PlayerState.stopped) {
      try {
        await _playerCtrl.preparePlayer(
          path: widget.memo.path,
          shouldExtractWaveform: false,
        );
        try {
          await _playerCtrl.setFinishMode(finishMode: FinishMode.pause);
        } catch (_) {}
        await _applySpeed();
      } catch (_) {
        return false;
      }
    } else {
      try {
        await _playerCtrl.seekTo(0);
      } catch (_) {}
    }
    _atEnd = false;
    if (mounted) setState(() => _positionMs = 0);
    return true;
  }

  Future<void> _togglePlayPause() async {
    if (!_prepared) return;
    Haptics.light();
    try {
      if (_playerState == PlayerState.playing) {
        _manualPause = true;
        await _playerCtrl.pausePlayer();
        return;
      }
      if (_atEnd) {
        final ok = await _rewindForReplay();
        if (!ok) return;
      }
      // Otherwise startPlayer() resumes from the current position.
      await _playerCtrl.startPlayer();
      await _applySpeed();
    } catch (_) {}
  }

  /// Seek to [fraction] (0..1) of the memo. Uses _durationMs (or the recorded
  /// duration as fallback) — sidesteps the audio_waveforms package's broken
  /// internal maxDuration calculation.
  void _seek(double fraction) {
    if (!_prepared) return;
    final totalMs = _totalMs;
    if (totalMs <= 0) return;
    final targetMs = (fraction.clamp(0.0, 1.0) * totalMs).toInt();
    _playerCtrl.seekTo(targetMs).catchError((_) {});
    _atEnd = false;
    setState(() => _positionMs = targetMs);
  }

  /// Always seeks to 0; restarts playback if currently playing,
  /// otherwise plays from the start.
  Future<void> _restart() async {
    if (!_prepared) return;
    try {
      if (_playerState == PlayerState.playing) {
        _manualPause = true;
        await _playerCtrl.pausePlayer();
      }
      final ok = await _rewindForReplay();
      if (!ok) return;
      await _playerCtrl.startPlayer();
      await _applySpeed();
    } catch (_) {}
  }

  Future<void> _cycleSpeed() async {
    Haptics.selection();
    final prev = _speed;
    final next = _speeds[(_speeds.indexOf(prev) + 1) % _speeds.length];
    setState(() => _speed = next);
    var ok = true;
    try {
      ok = await _playerCtrl.setRate(next);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) {
      setState(() {
        _speed = 1.0;
        _speedSupported = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Playback speed isn’t available on this phone')),
      );
    }
  }

  Future<void> _pauseIfPlaying() async {
    if (_playerState != PlayerState.playing) return;
    _manualPause = true;
    try {
      await _playerCtrl.pausePlayer();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final playing = _playerState == PlayerState.playing;
    return VoiceMemoPlayerCard(
      title: widget.memo.name,
      subtitle: widget.subtitle,
      ready: _prepared,
      playing: playing,
      atEnd: _atEnd,
      positionMs: _atEnd && !playing ? _totalMs : _positionMs,
      totalMs: _totalMs,
      levels: _levels,
      speed: _speedSupported ? _speed : null,
      onCycleSpeed: _prepared ? _cycleSpeed : null,
      onPlayPause: _togglePlayPause,
      onSeek: _seek,
      onRestart: _restart,
      onCollapse: () async {
        await _pauseIfPlaying();
        widget.onCollapse();
      },
      onAddToSoundboard: () async {
        await _pauseIfPlaying();
        widget.onAddToSoundboard();
      },
      onShare: widget.onShare,
      onRename: widget.onRename,
      onDelete: () async {
        await _pauseIfPlaying();
        widget.onDelete();
      },
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
