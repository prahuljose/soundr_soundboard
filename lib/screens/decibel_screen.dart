import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'package:share_plus/share_plus.dart';

import '../services/haptics.dart';
import '../theme/app_colors.dart';
import '../widgets/decibel_gauge.dart';
import '../widgets/decibel_history_chart.dart';
import '../widgets/permission_denied_card.dart';

// ── Audio config ────────────────────────────────────────────────────────────
const _kSampleRate = 44100;
const _kChannels = 1;

const _kBinMs = 500;
const _kHistorySeconds = 60;
const _kMaxBins = (_kHistorySeconds * 1000) ~/ _kBinMs;

// Base offset: dBFS → estimated dB SPL. User calibration is ADDED to this.
const _kDbBaseOffset = 94.0;

// Peak-hold behaviour
const _kPeakHoldHoldMs = 2000;
const _kPeakDecayDbPerSec = 6.0;

// Session log
const _kMaxSavedSessions = 30;
const _kMinSessionDurationSec = 5;

// Threshold-alert
const _kAlertSustainedMs = 3000;
const _kAlertCooldownSec = 10;

// ── Look ────────────────────────────────────────────────────────────────────
const _kTint = Color(0xFFFFB86B); // decibel tool tint
const _kMint = Color(0xFF7FE0C2); // quiet end of the scale
const _kPink = Color(0xFFFF8FA3); // loud end / alerts

// Gauge spans this range; readings outside it pin the arc to an end.
const _kGaugeMinDb = 30.0;
const _kGaugeMaxDb = 120.0;

// Chart reference line.
const _kRiskDb = 85.0;

/// Reference points shown under the chart.
const _kReferenceScale = <(int, String)>[
  (30, 'Whisper, quiet library'),
  (60, 'Normal conversation'),
  (85, 'Hearing risk after long exposure'),
  (100, 'Motorbike, loud concert'),
];

/// Tint colours are pale; text drawn in one on a light ground needs a darker
/// shade to stay readable.
Color _ink(BuildContext context, Color tint) =>
    Theme.of(context).brightness == Brightness.light
        ? Color.lerp(tint, Colors.black, 0.45)!
        : tint;

/// Dark ink for content sitting on a tint fill.
Color _onTint(Color tint) => Color.lerp(tint, Colors.black, 0.78)!;

const _tabular = [FontFeature.tabularFigures()];

/// Button label style. Built from the theme so it keeps the app font (a bare
/// TextStyle in a ButtonStyle would replace it).
TextStyle _buttonText(BuildContext context, double size, FontWeight weight) =>
    Theme.of(context).textTheme.labelLarge!.copyWith(
          fontSize: size,
          fontWeight: weight,
        );

// A-weighting filter cascade for fs = 44.1 kHz.
// Bilinear-transformed IEC 61672 A-curve, 4-section cascade.
// Each entry: [b0, b1, b2, a1, a2]  (a0 = 1).
// Approximation only — phone mics aren't certified anyway.
const List<List<double>> _kAWeightingSections = [
  [1.0, -2.0, 1.0, -1.990047, 0.990072],
  [1.0, -2.0, 1.0, -1.967628, 0.967792],
  [1.0,  1.0, 0.0, -0.852858, 0.000000],
  [1.0,  2.0, 1.0,  0.508808, 0.071406],
];
const double _kAWeightingGain = 1.2589; // ≈ +2 dB normalisation at 1 kHz

// ── Preferences model ───────────────────────────────────────────────────────
class _DecibelPrefs {
  double calibrationOffset; // ±20 dB
  bool aWeighting;
  bool alertEnabled;
  int alertThresholdDb; // 50..110

  _DecibelPrefs({
    this.calibrationOffset = 0.0,
    this.aWeighting = false,
    this.alertEnabled = false,
    this.alertThresholdDb = 80,
  });

  _DecibelPrefs copyWith({
    double? calibrationOffset,
    bool? aWeighting,
    bool? alertEnabled,
    int? alertThresholdDb,
  }) =>
      _DecibelPrefs(
        calibrationOffset: calibrationOffset ?? this.calibrationOffset,
        aWeighting: aWeighting ?? this.aWeighting,
        alertEnabled: alertEnabled ?? this.alertEnabled,
        alertThresholdDb: alertThresholdDb ?? this.alertThresholdDb,
      );

  Map<String, dynamic> toJson() => {
        'calibrationOffset': calibrationOffset,
        'aWeighting': aWeighting,
        'alertEnabled': alertEnabled,
        'alertThresholdDb': alertThresholdDb,
      };

  factory _DecibelPrefs.fromJson(Map<String, dynamic> j) => _DecibelPrefs(
        calibrationOffset:
            (j['calibrationOffset'] as num?)?.toDouble() ?? 0.0,
        aWeighting: j['aWeighting'] as bool? ?? false,
        alertEnabled: j['alertEnabled'] as bool? ?? false,
        alertThresholdDb:
            (j['alertThresholdDb'] as num?)?.toInt() ?? 80,
      );
}

// ── Saved-session model ─────────────────────────────────────────────────────
class _DbSession {
  final DateTime endedAt;
  final int durationSec;
  final double minDb;
  final double avgDb;
  final double maxDb;
  final List<double> history; // per-bin samples for the sparkline
  final String? name; // user-assigned label; null → show date/time

  _DbSession({
    required this.endedAt,
    required this.durationSec,
    required this.minDb,
    required this.avgDb,
    required this.maxDb,
    required this.history,
    this.name,
  });

  _DbSession copyWith({String? name}) => _DbSession(
        endedAt: endedAt,
        durationSec: durationSec,
        minDb: minDb,
        avgDb: avgDb,
        maxDb: maxDb,
        history: history,
        name: name ?? this.name,
      );

  _DbSession withoutName() => _DbSession(
        endedAt: endedAt,
        durationSec: durationSec,
        minDb: minDb,
        avgDb: avgDb,
        maxDb: maxDb,
        history: history,
        name: null,
      );

  Map<String, dynamic> toJson() => {
        'endedAt': endedAt.toIso8601String(),
        'durationSec': durationSec,
        'minDb': minDb,
        'avgDb': avgDb,
        'maxDb': maxDb,
        'history': history,
        if (name != null) 'name': name,
      };

  factory _DbSession.fromJson(Map<String, dynamic> j) => _DbSession(
        endedAt: DateTime.parse(j['endedAt'] as String),
        durationSec: (j['durationSec'] as num).toInt(),
        minDb: (j['minDb'] as num).toDouble(),
        avgDb: (j['avgDb'] as num).toDouble(),
        maxDb: (j['maxDb'] as num).toDouble(),
        history: (j['history'] as List?)
                ?.cast<num>()
                .map((n) => n.toDouble())
                .toList() ??
            const [],
        name: j['name'] as String?,
      );
}

String _formatDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
  final m = d.minute.toString().padLeft(2, '0');
  final am = d.hour < 12 ? 'AM' : 'PM';
  return '${months[d.month - 1]} ${d.day} · $h:$m $am';
}

String _formatDuration(int sec) {
  if (sec < 60) return '${sec}s';
  final m = sec ~/ 60;
  final s = sec % 60;
  if (m < 60) return s == 0 ? '${m}m' : '${m}m ${s}s';
  final h = m ~/ 60;
  final mm = m % 60;
  return mm == 0 ? '${h}h' : '${h}h ${mm}m';
}

// ── A-weighting filter ──────────────────────────────────────────────────────
class _Biquad {
  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  _Biquad({
    required this.b0,
    required this.b1,
    required this.b2,
    required this.a1,
    required this.a2,
  });

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  void reset() {
    _x1 = _x2 = _y1 = _y2 = 0;
  }
}

class _AWeightingFilter {
  final List<_Biquad> _sections;

  _AWeightingFilter()
      : _sections = _kAWeightingSections
            .map((c) => _Biquad(
                  b0: c[0],
                  b1: c[1],
                  b2: c[2],
                  a1: c[3],
                  a2: c[4],
                ))
            .toList();

  double process(double x) {
    var y = x;
    for (final s in _sections) {
      y = s.process(y);
    }
    return y * _kAWeightingGain;
  }

  void reset() {
    for (final s in _sections) {
      s.reset();
    }
  }
}

/// Pre-fills the screen's state so goldens can show a measuring session
/// without a microphone. Never used by the app itself.
@visibleForTesting
class DecibelDebugSeed {
  final bool running;
  final bool paused;
  final bool saved;
  final bool micDenied;
  final bool alertActive;
  final List<double> history;
  final double currentDb;
  final double peakDb;
  final int activeSeconds;
  final Map<String, dynamic>? prefs;
  final List<Map<String, dynamic>> sessions;

  const DecibelDebugSeed({
    this.running = false,
    this.paused = false,
    this.saved = false,
    this.micDenied = false,
    this.alertActive = false,
    this.history = const [],
    this.currentDb = 0,
    this.peakDb = 0,
    this.activeSeconds = 0,
    this.prefs,
    this.sessions = const [],
  });
}

// ─── Screen ─────────────────────────────────────────────────────────────────
class DecibelScreen extends StatefulWidget {
  @visibleForTesting
  final DecibelDebugSeed? debugSeed;

  const DecibelScreen({super.key, this.debugSeed});

  @override
  State<DecibelScreen> createState() => _DecibelScreenState();
}

class _DecibelScreenState extends State<DecibelScreen> {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _streamSub;
  Timer? _uiTimer;

  bool _running = false;
  String? _error;
  // When non-null, the body renders the permission-denied card instead of
  // the meter. Set when mic permission is denied; cleared on grant.
  PermissionStatus? _micDenied;

  // Bin accumulator
  double _binSumSq = 0;
  int _binSamples = 0;
  DateTime _binStart = DateTime.now();

  // Session state
  double _currentDb = 0;
  double _minDb = double.infinity;
  double _maxDb = double.negativeInfinity;
  double _sumDb = 0;
  int _binCount = 0;
  DateTime? _sessionStart;
  final List<double> _history = [];

  // Pause / resume: measured time excludes paused stretches.
  int _activeMs = 0;
  DateTime? _runStart;
  // The current session has been written to the log.
  bool _saved = false;

  // Peak hold
  double _peakHoldDb = 0;
  DateTime _peakHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // Threshold alert
  DateTime? _aboveThresholdSince;
  DateTime? _lastAlertAt;
  bool _alertActive = false;
  Timer? _alertFadeTimer;

  // Filter
  final _AWeightingFilter _aFilter = _AWeightingFilter();

  // Persistence
  _DecibelPrefs _prefs = _DecibelPrefs();
  List<_DbSession> _sessions = [];

  @override
  void initState() {
    super.initState();
    final seed = widget.debugSeed;
    if (seed != null) {
      _applySeed(seed);
      return;
    }
    _loadPrefs();
    _loadSessions();
  }

  void _applySeed(DecibelDebugSeed seed) {
    if (seed.prefs != null) _prefs = _DecibelPrefs.fromJson(seed.prefs!);
    _sessions = seed.sessions.map(_DbSession.fromJson).toList();
    if (seed.micDenied) _micDenied = PermissionStatus.denied;
    _history.addAll(seed.history);
    for (final b in seed.history) {
      _sumDb += b;
      _binCount++;
      _minDb = min(_minDb, b);
      _maxDb = max(_maxDb, b);
    }
    _currentDb = seed.currentDb;
    _peakHoldDb = seed.peakDb;
    _alertActive = seed.alertActive;
    if (seed.running || seed.paused || seed.saved) {
      _sessionStart = DateTime.now();
      _activeMs = seed.activeSeconds * 1000;
    }
    _running = seed.running;
    _saved = seed.saved;
  }

  @override
  void dispose() {
    _alertFadeTimer?.cancel();
    _uiTimer?.cancel();
    _streamSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // ── Preferences persistence ───────────────────────────────────────────────
  Future<File> _prefsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/decibel_prefs.json');
  }

  Future<void> _loadPrefs() async {
    try {
      final f = await _prefsFile();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _prefs = _DecibelPrefs.fromJson(
            jsonDecode(raw) as Map<String, dynamic>);
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final f = await _prefsFile();
      await f.writeAsString(jsonEncode(_prefs.toJson()));
    } catch (_) {}
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// A session has been started and not yet saved (it may be paused).
  bool get _sessionOpen => _sessionStart != null && !_saved;
  bool get _paused => !_running && _sessionOpen;

  int get _activeSeconds {
    var ms = _activeMs;
    if (_runStart != null) {
      ms += DateTime.now().difference(_runStart!).inMilliseconds;
    }
    return ms ~/ 1000;
  }

  /// Starts measuring. With [resume], carries on the paused session instead
  /// of starting a fresh one.
  Future<void> _start({bool resume = false}) async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (!status.isGranted) {
      setState(() {
        _micDenied = status;
        _error = null;
      });
      return;
    }
    setState(() => _micDenied = null);

    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _kSampleRate,
          numChannels: _kChannels,
        ),
      );
      if (resume) {
        _binSumSq = 0;
        _binSamples = 0;
        _binStart = DateTime.now();
        _aFilter.reset();
        _aboveThresholdSince = null;
      } else {
        _resetSession();
        _sessionStart = DateTime.now();
      }
      _runStart = DateTime.now();
      _streamSub = stream.listen(
        _onAudio,
        onError: (e) {
          if (mounted) setState(() => _error = e.toString());
        },
      );
      _uiTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
        if (!mounted) return;
        _tickPeakDecay();
        _checkThresholdAlert();
        setState(() {});
      });
      setState(() {
        _running = true;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  /// Stops the microphone but keeps the session's numbers so it can be
  /// resumed or saved.
  Future<void> _pause() async {
    _uiTimer?.cancel();
    _uiTimer = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _streamSub?.cancel();
    _streamSub = null;
    if (_runStart != null) {
      _activeMs += DateTime.now().difference(_runStart!).inMilliseconds;
      _runStart = null;
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _alertActive = false;
    });
  }

  void _togglePause() {
    Haptics.light();
    if (_running) {
      _pause();
    } else {
      _start(resume: true);
    }
  }

  Future<void> _saveSession() async {
    if (_activeSeconds < _kMinSessionDurationSec || _binCount == 0) {
      _snack('Measure for at least $_kMinSessionDurationSec seconds to save a session.');
      return;
    }
    if (_running) await _pause();
    if (!mounted) return;
    if (!_recordSessionIfEligible()) return;
    Haptics.medium();
    setState(() => _saved = true);
    _snack('Session saved', actionLabel: 'View', onAction: _openSessions);
  }

  void _snack(String text, {String? actionLabel, VoidCallback? onAction}) {
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      action: actionLabel == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction!),
    ));
  }

  void _resetSession() {
    _binSumSq = 0;
    _binSamples = 0;
    _binStart = DateTime.now();
    _currentDb = 0;
    _minDb = double.infinity;
    _maxDb = double.negativeInfinity;
    _sumDb = 0;
    _binCount = 0;
    _history.clear();
    _peakHoldDb = 0;
    _peakHoldUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _sessionStart = null;
    _activeMs = 0;
    _runStart = null;
    _saved = false;
    _aFilter.reset();
    _aboveThresholdSince = null;
    _lastAlertAt = null;
    _alertActive = false;
    _alertFadeTimer?.cancel();
  }

  // ── Audio ─────────────────────────────────────────────────────────────────
  void _onAudio(Uint8List chunk) {
    final n = chunk.length ~/ 2;
    if (n == 0) return;

    var sumSq = 0.0;
    if (_prefs.aWeighting) {
      // Normalise → A-filter → accumulate squared output → rescale to int domain
      // so the downstream RMS / dB code stays unchanged.
      for (var i = 0; i < n * 2; i += 2) {
        var s = chunk[i] | (chunk[i + 1] << 8);
        if (s > 32767) s -= 65536;
        final x = s / 32768.0;
        final y = _aFilter.process(x);
        sumSq += y * y;
      }
      sumSq *= 32768.0 * 32768.0;
    } else {
      for (var i = 0; i < n * 2; i += 2) {
        var s = chunk[i] | (chunk[i + 1] << 8);
        if (s > 32767) s -= 65536;
        sumSq += s * s;
      }
    }

    final chunkRms = sqrt(sumSq / n) / 32768.0;
    _currentDb = _rmsToDb(chunkRms);

    if (_currentDb > _peakHoldDb) {
      _peakHoldDb = _currentDb;
      _peakHoldUntil =
          DateTime.now().add(const Duration(milliseconds: _kPeakHoldHoldMs));
    }

    _binSumSq += sumSq;
    _binSamples += n;

    final now = DateTime.now();
    if (now.difference(_binStart).inMilliseconds >= _kBinMs && _binSamples > 0) {
      final binRms = sqrt(_binSumSq / _binSamples) / 32768.0;
      final binDb = _rmsToDb(binRms);
      _history.add(binDb);
      if (_history.length > _kMaxBins) _history.removeAt(0);
      _sumDb += binDb;
      _binCount++;
      if (binDb < _minDb) _minDb = binDb;
      if (binDb > _maxDb) _maxDb = binDb;
      _binSumSq = 0;
      _binSamples = 0;
      _binStart = now;
    }
  }

  void _tickPeakDecay() {
    final now = DateTime.now();
    if (now.isAfter(_peakHoldUntil) && _peakHoldDb > _currentDb) {
      const dt = 0.06;
      _peakHoldDb =
          max(_currentDb, _peakHoldDb - _kPeakDecayDbPerSec * dt);
    }
  }

  void _checkThresholdAlert() {
    if (!_prefs.alertEnabled) {
      _aboveThresholdSince = null;
      return;
    }
    final avg = _recentAvgDb;
    final now = DateTime.now();
    if (avg >= _prefs.alertThresholdDb) {
      _aboveThresholdSince ??= now;
      final sustained =
          now.difference(_aboveThresholdSince!).inMilliseconds >=
              _kAlertSustainedMs;
      final cooledDown = _lastAlertAt == null ||
          now.difference(_lastAlertAt!).inSeconds >= _kAlertCooldownSec;
      if (sustained && cooledDown) {
        Haptics.heavy();
        _lastAlertAt = now;
        _alertActive = true;
        _alertFadeTimer?.cancel();
        _alertFadeTimer = Timer(const Duration(seconds: 3), () {
          if (!mounted) return;
          setState(() => _alertActive = false);
        });
      }
    } else {
      _aboveThresholdSince = null;
    }
  }

  double _rmsToDb(double rms) {
    if (rms < 1e-7) return 0;
    final dbfs = 20 * log(rms) / ln10;
    return (dbfs + _kDbBaseOffset + _prefs.calibrationOffset)
        .clamp(0.0, 140.0);
  }

  double get _recentAvgDb {
    if (_history.length >= 4) {
      final tail = _history.sublist(max(0, _history.length - 20));
      return tail.reduce((a, b) => a + b) / tail.length;
    }
    return _currentDb;
  }

  String _categoryFor(double db) {
    if (db < 30) return 'Very quiet';
    if (db < 50) return 'Quiet';
    if (db < 65) return 'Conversational';
    if (db < 80) return 'Loud';
    if (db < 100) return 'Very loud';
    return 'Dangerous';
  }

  // ── Session persistence ───────────────────────────────────────────────────
  Future<File> _sessionsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/decibel_sessions.json');
  }

  Future<void> _loadSessions() async {
    try {
      final f = await _sessionsFile();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.isEmpty) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _sessions = list.map(_DbSession.fromJson).toList();
      });
    } catch (_) {}
  }

  Future<void> _persistSessions() async {
    try {
      final f = await _sessionsFile();
      await f.writeAsString(
        jsonEncode(_sessions.map((s) => s.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// Adds the current session to the log. Returns false when it was too
  /// short to keep.
  bool _recordSessionIfEligible() {
    if (_sessionStart == null) return false;
    final durationSec = _activeSeconds;
    if (durationSec < _kMinSessionDurationSec || _binCount == 0) return false;

    final session = _DbSession(
      endedAt: DateTime.now(),
      durationSec: durationSec,
      minDb: _minDb.isFinite ? _minDb : 0,
      avgDb: _sumDb / _binCount,
      maxDb: _maxDb.isFinite ? _maxDb : 0,
      history: List<double>.from(_history),
    );
    _sessions.insert(0, session);
    if (_sessions.length > _kMaxSavedSessions) {
      _sessions = _sessions.sublist(0, _kMaxSavedSessions);
    }
    _persistSessions();
    return true;
  }

  Future<void> _shareSession(_DbSession s) async {
    final csv = StringBuffer('time_sec,db\n');
    for (var i = 0; i < s.history.length; i++) {
      final t = ((i + 1) * _kBinMs / 1000.0).toStringAsFixed(1);
      csv.write('$t,${s.history[i].toStringAsFixed(1)}\n');
    }
    final header = 'Soundr Decibel Session\n'
        'Date: ${_formatDate(s.endedAt)}\n'
        'Duration: ${_formatDuration(s.durationSec)}\n'
        'Min: ${s.minDb.toStringAsFixed(1)} dB  '
        'Avg: ${s.avgDb.toStringAsFixed(1)} dB  '
        'Peak: ${s.maxDb.toStringAsFixed(1)} dB\n\n';
    await Share.share(
      header + csv.toString(),
      subject: 'dB session – ${_formatDate(s.endedAt)}',
    );
  }

  void _renameSession(_DbSession s, String newName) {
    final trimmed = newName.trim();
    final idx = _sessions.indexOf(s);
    if (idx == -1) return;
    setState(() {
      _sessions[idx] =
          trimmed.isEmpty ? s.withoutName() : s.copyWith(name: trimmed);
    });
    _persistSessions();
  }

  void _deleteSession(_DbSession s) {
    setState(() => _sessions.remove(s));
    _persistSessions();
  }

  Future<void> _clearSessions() async {
    setState(() => _sessions = []);
    await _persistSessions();
  }

  void _openSessions() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _SessionsPage(
        sessions: () => _sessions,
        onDelete: _deleteSession,
        onShare: _shareSession,
        onRename: _renameSession,
        onClear: _clearSessions,
      ),
    ));
  }

  // ── Settings sheet ────────────────────────────────────────────────────────
  void _openSettings() {
    final c = Theme.of(context).extension<AppColors>()!;
    showModalBottomSheet(
      context: context,
      backgroundColor: c.surfaceCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SettingsSheet(
        initial: _prefs,
        onChange: (p) {
          setState(() => _prefs = p);
          _savePrefs();
        },
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final hasSession = _binCount > 0;
    final avg = hasSession ? _sumDb / _binCount : 0.0;
    final hasCustomPrefs = _prefs.calibrationOffset != 0.0 ||
        _prefs.aWeighting ||
        _prefs.alertEnabled;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text('Decibel meter',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        backgroundColor: c.scaffoldBg,
        elevation: 0,
        actions: [
          _HeaderButton(label: 'Sessions', onPressed: _openSessions),
          IconButton(
            tooltip: 'Meter settings',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: _micDenied != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: PermissionDeniedCard(
                    permission: Permission.microphone,
                    icon: Icons.mic_rounded,
                    permissionLabel: 'Microphone',
                    purpose:
                        'The decibel meter measures sound levels using your microphone. '
                        'Audio is processed locally — no recording is saved or transmitted.',
                    onGranted: () {
                      if (mounted) setState(() => _micDenied = null);
                    },
                  ),
                ),
              )
            : Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hasCustomPrefs || _alertActive)
                            SizedBox(
                              height: 30,
                              child: Center(
                                child: _alertActive
                                    ? _AlertPill(
                                        thresholdDb: _prefs.alertThresholdDb)
                                    : _ModeBadges(prefs: _prefs),
                              ),
                            ),
                          SizedBox(height: hasCustomPrefs ? 8 : 26),
                          Center(child: _buildGauge(context, c)),
                          const SizedBox(height: 26),

                          // ── Min / Average / Max ─────────────────────────
                          Row(children: [
                            Expanded(
                              child: _StatCard(
                                label: 'Min',
                                value: hasSession
                                    ? _minDb.toStringAsFixed(0)
                                    : '—',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _StatCard(
                                label: 'Average',
                                value: hasSession
                                    ? avg.toStringAsFixed(0)
                                    : '—',
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _StatCard(
                                label: 'Max',
                                value: hasSession
                                    ? _maxDb.toStringAsFixed(0)
                                    : '—',
                                valueColor: _ink(context, _kTint),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 12),

                          // ── Last 30 seconds ─────────────────────────────
                          _Card(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    const Expanded(
                                        child: _SectionLabel(
                                            'LAST 30 SECONDS')),
                                    Text(
                                      _prefs.alertEnabled
                                          ? '85 dB line · alert ${_prefs.alertThresholdDb}'
                                          : '85 dB line',
                                      style: TextStyle(
                                        color: c.textSecondary,
                                        fontSize: 11,
                                        fontFeatures: _tabular,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                ExcludeSemantics(
                                  child: DecibelHistoryChart(
                                    bins: _history,
                                    binMs: _kBinMs,
                                    seconds: 30,
                                    referenceDb: _kRiskDb,
                                    thresholdDb: _prefs.alertEnabled
                                        ? _prefs.alertThresholdDb.toDouble()
                                        : null,
                                    tint: _kTint,
                                    emptyColor: c.border,
                                    thresholdColor: _kPink,
                                    fadedAlpha: Theme.of(context).brightness ==
                                            Brightness.light
                                        ? 0.55
                                        : 0.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          // ── Reference scale ─────────────────────────────
                          _ReferenceCard(
                            currentDb: _running ? _currentDb : null,
                          ),
                          const SizedBox(height: 12),

                          // ── Hearing safety ──────────────────────────────
                          _SafetyCard(
                            db: _running ? _recentAvgDb : 0.0,
                            running: _running,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Phone mics aren\'t calibrated — readings are relative, not certified SPL.',
                            style: TextStyle(
                                color: c.textSecondary, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _buildControls(context, c),
                ],
              ),
      ),
    );
  }

  Widget _buildGauge(BuildContext context, AppColors c) {
    final String number;
    final String caption;
    final String label;
    double? value;
    if (_running) {
      value = _currentDb;
      number = _currentDb.toStringAsFixed(0);
      final cat = _categoryFor(_currentDb);
      caption = 'dB · ${cat.toLowerCase()}';
      label = 'Current level $number decibels, ${cat.toLowerCase()}';
    } else if (_paused) {
      value = _currentDb;
      number = _currentDb.toStringAsFixed(0);
      caption = 'dB · paused';
      label = 'Paused at $number decibels';
    } else if (_saved) {
      number = '—';
      caption = 'Session saved';
      label = 'Session saved. Start to measure again.';
    } else {
      number = '—';
      caption = 'Tap start to begin';
      label = 'Not measuring. Tap start to begin.';
    }
    return DecibelGauge(
      value: value,
      peak: _running && _peakHoldDb > 1 ? _peakHoldDb : null,
      number: number,
      caption: caption,
      minDb: _kGaugeMinDb,
      maxDb: _kGaugeMaxDb,
      tint: _paused ? _kTint.withValues(alpha: 0.5) : _kTint,
      trackColor: c.surfaceElevated,
      numberColor: value == null
          ? c.iconSecondary
          : (_paused ? c.textSecondary : c.textPrimary),
      captionColor: c.textSecondary,
      scaleColor: c.iconSecondary,
      peakColor: c.textPrimary.withValues(alpha: 0.8),
      semanticLabel: label,
    );
  }

  Widget _buildControls(BuildContext context, AppColors c) {
    final onTint = _onTint(_kTint);
    final tintStyle = FilledButton.styleFrom(
      backgroundColor: _kTint,
      foregroundColor: onTint,
      minimumSize: const Size.fromHeight(56),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: _buttonText(context, 15, FontWeight.w800),
    );
    final Widget buttons;
    if (_running || _paused) {
      buttons = Row(children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _togglePause,
            style: OutlinedButton.styleFrom(
              backgroundColor: c.surfaceCard,
              foregroundColor: c.textPrimary,
              minimumSize: const Size.fromHeight(56),
              side: BorderSide(color: c.border),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18)),
              textStyle: _buttonText(context, 15, FontWeight.w700),
            ),
            child: Text(_running ? 'Pause' : 'Resume'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: FilledButton(
            onPressed: _saveSession,
            style: tintStyle,
            child: const Text('Save session'),
          ),
        ),
      ]);
    } else {
      buttons = FilledButton.icon(
        onPressed: () {
          Haptics.light();
          _start();
        },
        style: tintStyle,
        icon: const Icon(Icons.mic_rounded, size: 22),
        label: Text(_saved ? 'Start new session' : 'Start measuring'),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
          ],
          buttons,
        ],
      ),
    );
  }
}

// ── Building blocks ─────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? borderColor;
  const _Card({required this.child, this.padding, this.borderColor});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Container(
      padding: padding,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor ?? c.border),
      ),
      child: child,
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Text(
      text,
      style: TextStyle(
        color: c.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    );
  }
}

/// Outlined text button for the app bar, as in the artboard header.
class _HeaderButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _HeaderButton({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        backgroundColor: c.surfaceCard,
        foregroundColor: c.textPrimary,
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: _buttonText(context, 14, FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatCard({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(color: c.textSecondary, fontSize: 12)),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                color: valueColor ?? c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w600,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Mode badges / alert ─────────────────────────────────────────────────────
class _ModeBadges extends StatelessWidget {
  final _DecibelPrefs prefs;
  const _ModeBadges({required this.prefs});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final scheme = Theme.of(context).colorScheme;
    final chips = <Widget>[
      if (prefs.aWeighting) _chip(context, 'A-weighted', scheme.primary, c),
      if (prefs.calibrationOffset != 0.0)
        _chip(
          context,
          '${prefs.calibrationOffset > 0 ? '+' : ''}${prefs.calibrationOffset.toStringAsFixed(1)} dB cal',
          null,
          c,
        ),
      if (prefs.alertEnabled)
        _chip(context, 'Alert at ${prefs.alertThresholdDb} dB', _kTint, c,
            icon: Icons.notifications_none_rounded),
    ];
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: chips,
    );
  }

  Widget _chip(BuildContext context, String text, Color? tint, AppColors c,
      {IconData? icon}) {
    final fg = tint == null ? c.textSecondary : _ink(context, tint);
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: (tint ?? c.surfaceElevated)
            .withValues(alpha: tint == null ? 0.55 : 0.12),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: tint?.withValues(alpha: 0.35) ?? c.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
        ],
        Text(
          text,
          style: TextStyle(
            color: fg,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            fontFeatures: _tabular,
          ),
        ),
      ]),
    );
  }
}

class _AlertPill extends StatelessWidget {
  final int thresholdDb;
  const _AlertPill({required this.thresholdDb});

  @override
  Widget build(BuildContext context) {
    final fg = _ink(context, _kPink);
    return Semantics(
      liveRegion: true,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _kPink.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kPink.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.notifications_active_rounded, size: 14, color: fg),
            const SizedBox(width: 6),
            Text(
              'Above $thresholdDb dB',
              style: TextStyle(
                color: fg,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Reference scale ─────────────────────────────────────────────────────────
class _ReferenceCard extends StatelessWidget {
  /// Live level, or null when not measuring. The matching row is marked.
  final double? currentDb;
  const _ReferenceCard({required this.currentDb});

  static int _bandOf(double db) {
    if (db >= 100) return 3;
    if (db >= 85) return 2;
    if (db >= 60) return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final colors = [
      _ink(context, _kMint),
      c.textPrimary,
      _ink(context, _kTint),
      _ink(context, _kPink),
    ];
    final now = currentDb == null ? -1 : _bandOf(currentDb!);
    return _Card(
      child: Column(
        children: [
          for (var i = 0; i < _kReferenceScale.length; i++)
            Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: i == now ? _kTint.withValues(alpha: 0.08) : null,
                border: i == 0
                    ? null
                    : Border(top: BorderSide(color: c.border)),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${_kReferenceScale[i].$1}',
                      style: TextStyle(
                        color: colors[i],
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFeatures: _tabular,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _kReferenceScale[i].$2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: c.textSecondary, fontSize: 13.5),
                    ),
                  ),
                  if (i == now)
                    Text(
                      'now',
                      style: TextStyle(
                        color: _ink(context, _kTint),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
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

// ── Hearing-safety card ────────────────────────────────────────────────────
class _SafetyCard extends StatelessWidget {
  final double db;
  final bool running;

  const _SafetyCard({required this.db, required this.running});

  static (String, Color, IconData) _bandFor(double db) {
    if (db < 70) {
      return ('Safe at any duration', _kMint, Icons.check_circle_rounded);
    }
    if (db < 85) {
      return ('Comfortable — extended exposure is fine', _kMint,
          Icons.check_circle_rounded);
    }
    final t = 8.0 / pow(2.0, (db - 85) / 3.0);
    final String label;
    if (t >= 1) {
      label =
          'Safe for ~${t.round()} ${t.round() == 1 ? "hour" : "hours"}';
    } else if (t * 60 >= 1) {
      final mins = (t * 60).round();
      label = 'Safe for ~$mins ${mins == 1 ? "minute" : "minutes"}';
    } else {
      label = 'Damage risk within seconds';
    }
    final Color color;
    final IconData icon;
    if (db < 95) {
      color = _kTint;
      icon = Icons.warning_amber_rounded;
    } else if (db < 110) {
      color = const Color(0xFFFF6B35);
      icon = Icons.warning_rounded;
    } else {
      color = const Color(0xFFE53935);
      icon = Icons.error_rounded;
    }
    return (label, color, icon);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    if (!running) {
      return _Card(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, size: 20, color: c.iconSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Hearing-safety guidance appears when measuring.',
                style: TextStyle(color: c.textSecondary, fontSize: 13.5),
              ),
            ),
          ],
        ),
      );
    }

    final (label, color, icon) = _bandFor(db);
    return _Card(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      borderColor: color.withValues(alpha: 0.45),
      child: Row(
        children: [
          Icon(icon, size: 22, color: _ink(context, color)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionLabel('HEARING SAFETY'),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Based on the recent 10 s average (${db.toStringAsFixed(0)} dB)',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontFeatures: _tabular,
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

// ── Sessions page ───────────────────────────────────────────────────────────
class _SessionsPage extends StatefulWidget {
  /// Reads the screen's live list, so edits made here show straight away.
  final List<_DbSession> Function() sessions;
  final void Function(_DbSession) onDelete;
  final Future<void> Function(_DbSession) onShare;
  final void Function(_DbSession, String) onRename;
  final Future<void> Function() onClear;

  const _SessionsPage({
    required this.sessions,
    required this.onDelete,
    required this.onShare,
    required this.onRename,
    required this.onClear,
  });

  @override
  State<_SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<_SessionsPage> {
  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final c = Theme.of(context).extension<AppColors>()!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text(title, style: TextStyle(color: c.textPrimary)),
        content: Text(body, style: TextStyle(color: c.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              action,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _confirmClear() async {
    final ok = await _confirm(
      title: 'Clear session history?',
      body: 'All saved decibel sessions will be permanently deleted.',
      action: 'Clear',
    );
    if (!ok) return;
    await widget.onClear();
    if (mounted) setState(() {});
  }

  Future<void> _confirmDelete(_DbSession s) async {
    final ok = await _confirm(
      title: 'Delete session?',
      body: 'Remove this entry from the session log.',
      action: 'Delete',
    );
    if (!ok) return;
    widget.onDelete(s);
    if (mounted) setState(() {});
  }

  void _rename(_DbSession s, String name) {
    widget.onRename(s, name);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final sessions = widget.sessions();
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text('Sessions',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        backgroundColor: c.scaffoldBg,
        elevation: 0,
        actions: [
          if (sessions.isNotEmpty)
            IconButton(
              tooltip: 'Clear all sessions',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _confirmClear,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: sessions.isEmpty
            ? _EmptySessions(colors: c)
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 8, 2, 10),
                    child: Row(children: [
                      Expanded(
                        child: _SectionLabel(
                            '${sessions.length} SAVED'),
                      ),
                      Text(
                        'Keeps your last $_kMaxSavedSessions',
                        style:
                            TextStyle(color: c.textSecondary, fontSize: 12),
                      ),
                    ]),
                  ),
                  for (final s in sessions) ...[
                    _SessionTile(
                      key: ValueKey(s.endedAt),
                      session: s,
                      onDelete: () => _confirmDelete(s),
                      onShare: () => widget.onShare(s),
                      onRename: (name) => _rename(s, name),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
      ),
    );
  }
}

class _EmptySessions extends StatelessWidget {
  final AppColors colors;
  const _EmptySessions({required this.colors});

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _kTint.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.graphic_eq_rounded,
                  size: 30, color: _ink(context, _kTint)),
            ),
            const SizedBox(height: 16),
            Text('No saved sessions yet',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                )),
            const SizedBox(height: 6),
            Text(
              'Tap Save session while measuring to keep a record of it here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textSecondary, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionTile extends StatefulWidget {
  final _DbSession session;
  final VoidCallback onDelete;
  final VoidCallback onShare;
  final void Function(String) onRename;

  const _SessionTile({
    super.key,
    required this.session,
    required this.onDelete,
    required this.onShare,
    required this.onRename,
  });

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  bool _expanded = false;

  void _showRenameDialog() {
    final c = Theme.of(context).extension<AppColors>()!;
    final s = widget.session;
    final controller = TextEditingController(text: s.name ?? '');
    final tintInk = _ink(context, _kTint);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text('Name this session',
            style: TextStyle(color: c.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: TextStyle(color: c.textPrimary),
          decoration: InputDecoration(
            hintText: _formatDate(s.endedAt),
            hintStyle: TextStyle(color: c.textMuted),
            counterStyle: TextStyle(color: c.textMuted),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: c.borderSubtle),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: tintInk),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                Text('Cancel', style: TextStyle(color: c.textSecondary)),
          ),
          if (s.name != null)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                widget.onRename(''); // empty → clear name
              },
              child: Text('Reset', style: TextStyle(color: c.textSecondary)),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onRename(controller.text);
            },
            child: Text('Save',
                style:
                    TextStyle(color: tintInk, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final s = widget.session;
    final displayName = s.name ?? _formatDate(s.endedAt);
    final hasCustomName = s.name != null && s.name!.isNotEmpty;
    final tintInk = _ink(context, _kTint);
    final subtitle = hasCustomName
        ? '${_formatDate(s.endedAt)} · ${_formatDuration(s.durationSec)}'
        : _formatDuration(s.durationSec);

    return Material(
      color: c.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            onLongPress: widget.onDelete,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: c.textSecondary, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SessionStat(
                      label: 'avg',
                      value: s.avgDb.toStringAsFixed(0),
                      color: c.textPrimary,
                    ),
                    const SizedBox(width: 14),
                    _SessionStat(
                      label: 'peak',
                      value: s.maxDb.toStringAsFixed(0),
                      color: tintInk,
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 22,
                      color: c.iconSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: c.borderSubtle),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (s.history.isNotEmpty) ...[
                    ExcludeSemantics(
                      child: SizedBox(
                        height: 56,
                        child: ClipRect(
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: _SparklinePainter(
                              history: s.history,
                              accent: _kTint,
                              muted: c.textMuted,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Row(
                    children: [
                      _MiniStat(label: 'min', value: s.minDb.toStringAsFixed(1)),
                      const SizedBox(width: 16),
                      _MiniStat(label: 'avg', value: s.avgDb.toStringAsFixed(1)),
                      const SizedBox(width: 16),
                      _MiniStat(
                        label: 'peak',
                        value: s.maxDb.toStringAsFixed(1),
                        highlight: tintInk,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: _TileAction(
                      icon: Icons.edit_rounded,
                      label: 'Rename',
                      onPressed: _showRenameDialog,
                    ),
                  ),
                  Expanded(
                    child: _TileAction(
                      icon: Icons.ios_share_rounded,
                      label: 'Share',
                      onPressed: widget.onShare,
                    ),
                  ),
                  Expanded(
                    child: _TileAction(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      color: Colors.redAccent,
                      onPressed: widget.onDelete,
                    ),
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

class _TileAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final Color? color;

  const _TileAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color ?? c.textPrimary,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        textStyle: _buttonText(context, 14, FontWeight.w600),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color? highlight;

  const _MiniStat({required this.label, required this.value, this.highlight});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Row(
      children: [
        Text('$label ',
            style: TextStyle(color: c.textSecondary, fontSize: 12)),
        Text(value,
            style: TextStyle(
              color: highlight ?? c.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: _tabular,
            )),
      ],
    );
  }
}

class _SessionStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SessionStat({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(color: c.textSecondary, fontSize: 11)),
        Text(value,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontFeatures: _tabular,
            )),
      ],
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> history;
  final Color accent;
  final Color muted;

  _SparklinePainter({
    required this.history,
    required this.accent,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (history.isEmpty) return;
    const minDb = 0.0;
    const maxDb = 120.0;

    final stepX = size.width / max(history.length, 1);

    // Faint grid at 60 dB
    final gridPaint = Paint()
      ..color = muted.withValues(alpha: 0.18)
      ..strokeWidth = 0.6;
    final y60 =
        size.height - (60 - minDb) / (maxDb - minDb) * size.height;
    canvas.drawLine(Offset(0, y60), Offset(size.width, y60), gridPaint);

    // Filled area under the line for visual weight
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < history.length; i++) {
      final db = history[i];
      final norm =
          ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
      final x = i * stepX;
      final y = size.height - norm * size.height;
      path.lineTo(x, y);
    }
    path.lineTo((history.length - 1) * stepX, size.height);
    path.close();
    canvas.drawPath(
      path,
      Paint()..color = accent.withValues(alpha: 0.18),
    );

    // Line on top
    final linePaint = Paint()
      ..color = accent
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final linePath = Path();
    for (var i = 0; i < history.length; i++) {
      final db = history[i];
      final norm =
          ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
      final x = i * stepX;
      final y = size.height - norm * size.height;
      if (i == 0) {
        linePath.moveTo(x, y);
      } else {
        linePath.lineTo(x, y);
      }
    }
    canvas.drawPath(linePath, linePaint);
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.history != history || old.accent != accent;
}

// ── Settings sheet ──────────────────────────────────────────────────────────
class _SettingsSheet extends StatefulWidget {
  final _DecibelPrefs initial;
  final void Function(_DecibelPrefs) onChange;

  const _SettingsSheet({
    required this.initial,
    required this.onChange,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late _DecibelPrefs _p;

  @override
  void initState() {
    super.initState();
    _p = widget.initial.copyWith();
  }

  void _apply(_DecibelPrefs next) {
    setState(() => _p = next);
    widget.onChange(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final tintInk = _ink(context, _kTint);
    final slider = SliderThemeData(
      activeTrackColor: _kTint,
      inactiveTrackColor: c.surfaceElevated,
      thumbColor: _kTint,
      overlayColor: _kTint.withValues(alpha: 0.18),
      trackHeight: 4,
    );
    final valueStyle = TextStyle(
      color: c.textPrimary,
      fontSize: 15,
      fontWeight: FontWeight.w700,
      fontFeatures: _tabular,
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 10, 20, 12 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: c.handleBar,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Meter settings',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),

            // ── Calibration ────────────────────────────────────────────────
            const _SectionLabel('CALIBRATION'),
            const SizedBox(height: 6),
            Text(
              'Add an offset to every reading so it matches a known reference.',
              style: TextStyle(color: c.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: slider,
                    child: Slider(
                      min: -20,
                      max: 20,
                      divisions: 80,
                      value: _p.calibrationOffset
                          .clamp(-20.0, 20.0)
                          .toDouble(),
                      onChanged: (v) => _apply(
                          _p.copyWith(calibrationOffset: v)),
                    ),
                  ),
                ),
                SizedBox(
                  width: 70,
                  child: Text(
                    '${_p.calibrationOffset >= 0 ? "+" : ""}${_p.calibrationOffset.toStringAsFixed(1)} dB',
                    textAlign: TextAlign.right,
                    style: valueStyle,
                  ),
                ),
              ],
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: tintInk,
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: _p.calibrationOffset == 0
                  ? null
                  : () => _apply(_p.copyWith(calibrationOffset: 0.0)),
              child: const Text(
                'Reset to 0',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 12),

            // ── A-weighting ────────────────────────────────────────────────
            _ToggleRow(
              title: 'A-weighting',
              subtitle:
                  'De-emphasises low rumble and very high treble to match human hearing. Approximate — phone mics aren\'t certified.',
              value: _p.aWeighting,
              onChanged: (v) => _apply(_p.copyWith(aWeighting: v)),
            ),

            const SizedBox(height: 18),
            Divider(color: c.borderSubtle, height: 1),
            const SizedBox(height: 18),

            // ── Threshold alert ────────────────────────────────────────────
            const _SectionLabel('THRESHOLD ALERT'),
            const SizedBox(height: 8),
            _ToggleRow(
              title: 'Buzz when it gets loud',
              subtitle:
                  'Haptic feedback if the 10 s average stays above the threshold for 3 s.',
              value: _p.alertEnabled,
              onChanged: (v) => _apply(_p.copyWith(alertEnabled: v)),
            ),
            const SizedBox(height: 8),
            Opacity(
              opacity: _p.alertEnabled ? 1.0 : 0.5,
              child: IgnorePointer(
                ignoring: !_p.alertEnabled,
                child: Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: slider,
                        child: Slider(
                          min: 50,
                          max: 110,
                          divisions: 60,
                          value: _p.alertThresholdDb.toDouble(),
                          onChanged: (v) => _apply(_p.copyWith(
                              alertThresholdDb: v.round())),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 70,
                      child: Text(
                        '${_p.alertThresholdDb} dB',
                        textAlign: TextAlign.right,
                        style: valueStyle,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _kTint,
                foregroundColor: _onTint(_kTint),
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
                textStyle: _buttonText(context, 15, FontWeight.w800),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return MergeSemantics(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        )),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style:
                            TextStyle(color: c.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: value,
                activeThumbColor: _kTint,
                activeTrackColor: _kTint.withValues(alpha: 0.4),
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
