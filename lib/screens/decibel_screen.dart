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

import '../theme/app_colors.dart';
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

const _kReferenceMarkers = <(double, String)>[
  (30, 'whisper'),
  (50, 'library'),
  (65, 'talking'),
  (80, 'traffic'),
  (100, 'power tool'),
];

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

// ─── Screen ─────────────────────────────────────────────────────────────────
class DecibelScreen extends StatefulWidget {
  const DecibelScreen({super.key});

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
    _loadPrefs();
    _loadSessions();
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
  Future<void> _start() async {
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
      _resetSession();
      _sessionStart = DateTime.now();
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

  Future<void> _stop() async {
    _uiTimer?.cancel();
    _uiTimer = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _streamSub?.cancel();
    _streamSub = null;
    _recordSessionIfEligible();
    setState(() {
      _running = false;
      _alertActive = false;
    });
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
        HapticFeedback.heavyImpact();
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

  Color _colorFor(double db, Color accent) {
    if (db < 65) return accent;
    if (db < 80) return const Color(0xFFFFB020);
    if (db < 100) return const Color(0xFFFF6B35);
    return const Color(0xFFE53935);
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

  void _recordSessionIfEligible() {
    if (_sessionStart == null) return;
    final durationSec = DateTime.now().difference(_sessionStart!).inSeconds;
    if (durationSec < _kMinSessionDurationSec || _binCount == 0) return;

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
  }

  Future<void> _shareSession(_DbSession s) async {
    final csv = StringBuffer('time_sec,db\n');
    for (var i = 0; i < s.history.length; i++) {
      final t = ((i + 1) * _kBinMs / 1000.0).toStringAsFixed(1);
      csv.write('$t,${s.history[i].toStringAsFixed(1)}\n');
    }
    final header = 'Soundr Decibel Session\n'
        'Date: ${_SessionsCard._formatDate(s.endedAt)}\n'
        'Duration: ${_SessionsCard._formatDuration(s.durationSec)}\n'
        'Min: ${s.minDb.toStringAsFixed(1)} dB  '
        'Avg: ${s.avgDb.toStringAsFixed(1)} dB  '
        'Peak: ${s.maxDb.toStringAsFixed(1)} dB\n\n';
    await Share.share(
      header + csv.toString(),
      subject: 'dB session – ${_SessionsCard._formatDate(s.endedAt)}',
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

  // ── Settings sheet ────────────────────────────────────────────────────────
  void _openSettings() {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    showModalBottomSheet(
      context: context,
      backgroundColor: c.surfaceCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _SettingsSheet(
        initial: _prefs,
        colors: c,
        accent: accent,
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
    final accent = Theme.of(context).colorScheme.primary;
    final db = _running ? _currentDb : 0.0;
    final color = _colorFor(db, accent);
    final hasSession = _binCount > 0;
    final avg = hasSession ? _sumDb / _binCount : 0.0;
    final safetyDb = _running ? _recentAvgDb : 0.0;

    // Mode badges — compact chip strip below the title row
    final hasCustomPrefs = _prefs.calibrationOffset != 0.0 ||
        _prefs.aWeighting ||
        _prefs.alertEnabled;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text('Decibel Meter'),
        backgroundColor: c.scaffoldBg,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune_rounded),
            onPressed: _openSettings,
          ),
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
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 4),
                    if (hasCustomPrefs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: _ModeBadges(
                          prefs: _prefs,
                          colors: c,
                          accent: accent,
                        ),
                      ),
                    const SizedBox(height: 8),

                    // ── Big live number ────────────────────────────────────
                    Center(
                      child: RichText(
                        text: TextSpan(children: [
                          TextSpan(
                            text: db.toStringAsFixed(0),
                            style: TextStyle(
                              color: color,
                              fontSize: 88,
                              fontWeight: FontWeight.w300,
                              letterSpacing: -3,
                              height: 1,
                            ),
                          ),
                          TextSpan(
                            text: '  dB',
                            style: TextStyle(
                              color: c.textMuted,
                              fontSize: 26,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Center(
                      child: Text(
                        _running
                            ? _categoryFor(db)
                            : 'Tap start to begin',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),

                    // ── Alert pulse pill ───────────────────────────────────
                    if (_alertActive) ...[
                      const SizedBox(height: 10),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE53935)
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFFE53935)
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.notifications_active_rounded,
                                size: 14,
                                color: Color(0xFFE53935),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Above ${_prefs.alertThresholdDb} dB',
                                style: const TextStyle(
                                  color: Color(0xFFE53935),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),

                    // ── Reference scale ────────────────────────────────────
                    _ReferenceScale(
                      currentDb: db,
                      running: _running,
                      colors: c,
                      accent: accent,
                    ),
                    const SizedBox(height: 22),

                    // ── 60-second history ──────────────────────────────────
                    _HistoryCard(
                      history: _history,
                      peakHoldDb: _running ? _peakHoldDb : 0,
                      thresholdDb: _prefs.alertEnabled
                          ? _prefs.alertThresholdDb.toDouble()
                          : null,
                      colors: c,
                      accent: accent,
                    ),
                    const SizedBox(height: 12),

                    // ── Min / Avg / Max ────────────────────────────────────
                    Row(
                      children: [
                        Expanded(
                            child: _StatTile(
                          label: 'MIN',
                          value: hasSession
                              ? _minDb.toStringAsFixed(0)
                              : '—',
                          colors: c,
                        )),
                        const SizedBox(width: 10),
                        Expanded(
                            child: _StatTile(
                          label: 'AVG',
                          value: hasSession
                              ? avg.toStringAsFixed(0)
                              : '—',
                          colors: c,
                          highlight: accent,
                        )),
                        const SizedBox(width: 10),
                        Expanded(
                            child: _StatTile(
                          label: 'MAX',
                          value: hasSession
                              ? _maxDb.toStringAsFixed(0)
                              : '—',
                          colors: c,
                        )),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // ── Hearing safety ─────────────────────────────────────
                    _SafetyCard(
                      db: safetyDb,
                      running: _running,
                      colors: c,
                      accent: accent,
                    ),

                    if (_sessions.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _SessionsCard(
                        sessions: _sessions,
                        colors: c,
                        accent: accent,
                        onClear: _confirmClearSessions,
                        onDelete: _confirmDeleteSession,
                        onShare: _shareSession,
                        onRename: _renameSession,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: const TextStyle(
                          color: Colors.redAccent, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                  ],
                  SizedBox(
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _running ? c.surfaceCard : accent,
                        foregroundColor:
                            _running ? c.textPrimary : Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: _running
                              ? BorderSide(color: c.border)
                              : BorderSide.none,
                        ),
                        elevation: 0,
                      ),
                      onPressed: _running ? _stop : _start,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _running
                                ? Icons.stop_rounded
                                : Icons.mic_rounded,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _running ? 'Stop' : 'Start measuring',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Phone mics aren\'t calibrated — readings are relative, not certified SPL.',
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmClearSessions() {
    final c = Theme.of(context).extension<AppColors>()!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text('Clear session history?',
            style: TextStyle(color: c.textPrimary)),
        content: Text(
          'All saved decibel sessions will be permanently deleted.',
          style: TextStyle(color: c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _clearSessions();
            },
            child: const Text(
              'Clear',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteSession(_DbSession s) {
    final c = Theme.of(context).extension<AppColors>()!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surfaceCard,
        title: Text('Delete session?',
            style: TextStyle(color: c.textPrimary)),
        content: Text(
          'Remove this entry from the session log.',
          style: TextStyle(color: c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteSession(s);
            },
            child: const Text(
              'Delete',
              style: TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Mode badges ─────────────────────────────────────────────────────────────
class _ModeBadges extends StatelessWidget {
  final _DecibelPrefs prefs;
  final AppColors colors;
  final Color accent;

  const _ModeBadges({
    required this.prefs,
    required this.colors,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    if (prefs.aWeighting) {
      chips.add(_chip('A-weighted', accent, colors));
    }
    if (prefs.calibrationOffset != 0.0) {
      final sign = prefs.calibrationOffset > 0 ? '+' : '';
      chips.add(_chip(
        '$sign${prefs.calibrationOffset.toStringAsFixed(1)} dB cal',
        colors.textSecondary,
        colors,
      ));
    }
    if (prefs.alertEnabled) {
      chips.add(_chip(
        '⚠ ${prefs.alertThresholdDb} dB',
        const Color(0xFFFFB020),
        colors,
      ));
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 6,
      runSpacing: 4,
      children: chips,
    );
  }

  Widget _chip(String text, Color tint, AppColors c) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tint.withValues(alpha: 0.30)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: tint,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      );
}

// ── Reference scale ─────────────────────────────────────────────────────────
class _ReferenceScale extends StatelessWidget {
  final double currentDb;
  final bool running;
  final AppColors colors;
  final Color accent;

  const _ReferenceScale({
    required this.currentDb,
    required this.running,
    required this.colors,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: CustomPaint(
        painter: _ReferenceScalePainter(
          currentDb: currentDb,
          running: running,
          accent: accent,
          textColor: colors.textMuted,
        ),
      ),
    );
  }
}

class _ReferenceScalePainter extends CustomPainter {
  final double currentDb;
  final bool running;
  final Color accent;
  final Color textColor;

  _ReferenceScalePainter({
    required this.currentDb,
    required this.running,
    required this.accent,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const minDb = 0.0;
    const maxDb = 120.0;
    final trackY = 10.0;

    final trackPaint = Paint()
      ..color = textColor.withValues(alpha: 0.25)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(0, trackY), Offset(size.width, trackY), trackPaint);

    for (final (db, label) in _kReferenceMarkers) {
      final x = ((db - minDb) / (maxDb - minDb)) * size.width;

      final tickPaint = Paint()
        ..color = textColor.withValues(alpha: 0.55)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, trackY - 3), Offset(x, trackY + 3), tickPaint);

      final dbTp = TextPainter(
        text: TextSpan(
          text: db.toInt().toString(),
          style: TextStyle(
            color: textColor.withValues(alpha: 0.85),
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      dbTp.paint(canvas, Offset(x - dbTp.width / 2, trackY + 6));

      final labelTp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: textColor.withValues(alpha: 0.6),
            fontSize: 9,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width / _kReferenceMarkers.length);
      labelTp.paint(canvas, Offset(x - labelTp.width / 2, trackY + 20));
    }

    if (running) {
      final clamped = currentDb.clamp(minDb, maxDb);
      final x = ((clamped - minDb) / (maxDb - minDb)) * size.width;
      final dotPaint = Paint()..color = accent;
      canvas.drawCircle(Offset(x, trackY), 5.5, dotPaint);
      final ringPaint = Paint()
        ..color = accent.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4;
      canvas.drawCircle(Offset(x, trackY), 8, ringPaint);
    }
  }

  @override
  bool shouldRepaint(_ReferenceScalePainter old) =>
      old.currentDb != currentDb ||
      old.running != running ||
      old.accent != accent;
}

// ── History card ────────────────────────────────────────────────────────────
class _HistoryCard extends StatelessWidget {
  final List<double> history;
  final double peakHoldDb;
  final double? thresholdDb;
  final AppColors colors;
  final Color accent;

  const _HistoryCard({
    required this.history,
    required this.peakHoldDb,
    required this.thresholdDb,
    required this.colors,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 140,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: colors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('LAST 60 SECONDS',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  )),
              Text('${history.length ~/ 2}s',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ClipRect(
              child: CustomPaint(
                size: Size.infinite,
                painter: _HistoryPainter(
                  history: history,
                  peakHoldDb: peakHoldDb,
                  thresholdDb: thresholdDb,
                  accent: accent,
                  muted: colors.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryPainter extends CustomPainter {
  final List<double> history;
  final double peakHoldDb;
  final double? thresholdDb;
  final Color accent;
  final Color muted;

  _HistoryPainter({
    required this.history,
    required this.peakHoldDb,
    required this.thresholdDb,
    required this.accent,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const minDb = 0.0;
    const maxDb = 120.0;

    final gridPaint = Paint()
      ..color = muted.withValues(alpha: 0.2)
      ..strokeWidth = 0.6;
    for (final ref in [30.0, 60.0, 90.0]) {
      final y =
          size.height - (ref - minDb) / (maxDb - minDb) * size.height;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (history.isNotEmpty) {
      final barCount = _kMaxBins;
      final barWidth = size.width / barCount;
      final visible = history.length > barCount
          ? history.sublist(history.length - barCount)
          : history;
      final start = barCount - visible.length;

      for (var i = 0; i < visible.length; i++) {
        final db = visible[i];
        final norm = ((db - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
        final h = norm * size.height;
        final x = (start + i) * barWidth;

        Color barColor;
        if (db < 65) {
          barColor = accent;
        } else if (db < 80) {
          barColor = const Color(0xFFFFB020);
        } else if (db < 100) {
          barColor = const Color(0xFFFF6B35);
        } else {
          barColor = const Color(0xFFE53935);
        }

        final paint = Paint()..color = barColor.withValues(alpha: 0.85);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + 0.5, size.height - h, barWidth - 1, h),
            const Radius.circular(1.5),
          ),
          paint,
        );
      }
    }

    // Threshold line — solid, faint red
    if (thresholdDb != null) {
      final norm =
          ((thresholdDb! - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
      final y = size.height - norm * size.height;
      final p = Paint()
        ..color = const Color(0xFFE53935).withValues(alpha: 0.55)
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }

    // Peak-hold dashed line
    if (peakHoldDb > 1) {
      final norm =
          ((peakHoldDb - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
      final y = size.height - norm * size.height;
      final peakPaint = Paint()
        ..color = const Color(0xFFFFB020).withValues(alpha: 0.85)
        ..strokeWidth = 1.4;
      const dashWidth = 5.0;
      const dashGap = 3.5;
      var x = 0.0;
      while (x < size.width) {
        canvas.drawLine(
          Offset(x, y),
          Offset(min(x + dashWidth, size.width), y),
          peakPaint,
        );
        x += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_HistoryPainter old) =>
      old.history != history ||
      old.history.length != history.length ||
      old.peakHoldDb != peakHoldDb ||
      old.thresholdDb != thresholdDb;
}

// ── Stat tile ───────────────────────────────────────────────────────────────
class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final AppColors colors;
  final Color? highlight;

  const _StatTile({
    required this.label,
    required this.value,
    required this.colors,
    this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              )),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                color: highlight ?? colors.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              )),
        ],
      ),
    );
  }
}

// ── Hearing-safety card ────────────────────────────────────────────────────
class _SafetyCard extends StatelessWidget {
  final double db;
  final bool running;
  final AppColors colors;
  final Color accent;

  const _SafetyCard({
    required this.db,
    required this.running,
    required this.colors,
    required this.accent,
  });

  static (String, Color, IconData) _bandFor(double db, Color accent) {
    if (db < 70) {
      return ('Safe at any duration', accent,
          Icons.check_circle_rounded);
    }
    if (db < 85) {
      return ('Comfortable — extended exposure is fine', accent,
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
      color = const Color(0xFFFFB020);
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
    if (!running) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: colors.surfaceCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.borderSubtle),
        ),
        child: Row(
          children: [
            Icon(Icons.shield_outlined,
                size: 20, color: colors.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Hearing-safety guidance appears when measuring.',
                style: TextStyle(
                    color: colors.textSecondary, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    final (label, color, icon) = _bandFor(db, accent);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: colors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('HEARING SAFETY',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    )),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Based on the recent 10 s average (${db.toStringAsFixed(0)} dB)',
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 11,
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

// ── Recent sessions card ────────────────────────────────────────────────────
class _SessionsCard extends StatelessWidget {
  final List<_DbSession> sessions;
  final AppColors colors;
  final Color accent;
  final VoidCallback onClear;
  final void Function(_DbSession) onDelete;
  final void Function(_DbSession) onShare;
  final void Function(_DbSession, String) onRename;

  const _SessionsCard({
    required this.sessions,
    required this.colors,
    required this.accent,
    required this.onClear,
    required this.onDelete,
    required this.onShare,
    required this.onRename,
  });

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final h = d.hour == 0 ? 12 : (d.hour > 12 ? d.hour - 12 : d.hour);
    final m = d.minute.toString().padLeft(2, '0');
    final am = d.hour < 12 ? 'AM' : 'PM';
    return '${months[d.month - 1]} ${d.day} · $h:$m $am';
  }

  static String _formatDuration(int sec) {
    if (sec < 60) return '${sec}s';
    final m = sec ~/ 60;
    final s = sec % 60;
    if (m < 60) return s == 0 ? '${m}m' : '${m}m ${s}s';
    final h = m ~/ 60;
    final mm = m % 60;
    return mm == 0 ? '${h}h' : '${h}h ${mm}m';
  }

  @override
  Widget build(BuildContext context) {
    final visible = sessions.take(7).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: BoxDecoration(
        color: colors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('RECENT SESSIONS',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    )),
              ),
              GestureDetector(
                onTap: onClear,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline_rounded,
                      size: 18, color: colors.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ...visible.map((s) => _SessionRow(
                key: ValueKey(s.endedAt),
                session: s,
                colors: colors,
                accent: accent,
                onLongPress: () => onDelete(s),
                onShare: () => onShare(s),
                onRename: (name) => onRename(s, name),
              )),
          if (sessions.length > visible.length) ...[
            const SizedBox(height: 6),
            Text(
              '+ ${sessions.length - visible.length} more saved',
              style: TextStyle(color: colors.textMuted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionRow extends StatefulWidget {
  final _DbSession session;
  final AppColors colors;
  final Color accent;
  final VoidCallback onLongPress;
  final VoidCallback onShare;
  final void Function(String) onRename;

  const _SessionRow({
    super.key,
    required this.session,
    required this.colors,
    required this.accent,
    required this.onLongPress,
    required this.onShare,
    required this.onRename,
  });

  @override
  State<_SessionRow> createState() => _SessionRowState();
}

class _SessionRowState extends State<_SessionRow> {
  bool _expanded = false;

  void _showRenameDialog() {
    final c = widget.colors;
    final s = widget.session;
    final controller = TextEditingController(
      text: s.name ?? '',
    );
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
            hintText: _SessionsCard._formatDate(s.endedAt),
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
              child: Text('Reset',
                  style: TextStyle(color: c.textMuted)),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onRename(controller.text);
            },
            child: Text('Save',
                style: TextStyle(
                    color: widget.accent, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final displayName = s.name ?? _SessionsCard._formatDate(s.endedAt);
    final hasCustomName = s.name != null && s.name!.isNotEmpty;
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      onLongPress: widget.onLongPress,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.expand_more_rounded
                      : Icons.chevron_right_rounded,
                  size: 16,
                  color: widget.colors.textMuted,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: TextStyle(
                          color: widget.colors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        hasCustomName
                            ? '${_SessionsCard._formatDate(s.endedAt)} · ${_SessionsCard._formatDuration(s.durationSec)}'
                            : _SessionsCard._formatDuration(s.durationSec),
                        style: TextStyle(
                            color: widget.colors.textMuted,
                            fontSize: 11),
                      ),
                    ],
                  ),
                ),
                _SessionStat(
                  label: 'avg',
                  value: s.avgDb.toStringAsFixed(0),
                  color: widget.accent,
                  muted: widget.colors.textMuted,
                ),
                const SizedBox(width: 12),
                _SessionStat(
                  label: 'peak',
                  value: s.maxDb.toStringAsFixed(0),
                  color: widget.colors.textPrimary,
                  muted: widget.colors.textMuted,
                ),
                const SizedBox(width: 4),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 20, right: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (s.history.isNotEmpty) ...[
                      SizedBox(
                        height: 56,
                        child: ClipRect(
                          child: CustomPaint(
                            size: Size.infinite,
                            painter: _SparklinePainter(
                              history: s.history,
                              accent: widget.accent,
                              muted: widget.colors.textMuted,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    Row(
                      children: [
                        _MiniStat(
                          label: 'min',
                          value: s.minDb.toStringAsFixed(1),
                          colors: widget.colors,
                        ),
                        const SizedBox(width: 16),
                        _MiniStat(
                          label: 'avg',
                          value: s.avgDb.toStringAsFixed(1),
                          colors: widget.colors,
                          highlight: widget.accent,
                        ),
                        const SizedBox(width: 16),
                        _MiniStat(
                          label: 'peak',
                          value: s.maxDb.toStringAsFixed(1),
                          colors: widget.colors,
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: _showRenameDialog,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.edit_rounded,
                              size: 15,
                              color: widget.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: widget.onShare,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.ios_share_rounded,
                              size: 15,
                              color: widget.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final AppColors colors;
  final Color? highlight;

  const _MiniStat({
    required this.label,
    required this.value,
    required this.colors,
    this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('$label ',
            style:
                TextStyle(color: colors.textMuted, fontSize: 11)),
        Text(value,
            style: TextStyle(
              color: highlight ?? colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            )),
      ],
    );
  }
}

class _SessionStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final Color muted;

  const _SessionStat({
    required this.label,
    required this.value,
    required this.color,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(label, style: TextStyle(color: muted, fontSize: 9)),
        Text(value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w700,
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
  final AppColors colors;
  final Color accent;
  final void Function(_DecibelPrefs) onChange;

  const _SettingsSheet({
    required this.initial,
    required this.colors,
    required this.accent,
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
    final c = widget.colors;
    final accent = widget.accent;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: c.handleBar,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Settings',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 18),

            // ── Calibration ────────────────────────────────────────────────
            _SectionLabel('CALIBRATION', colors: c),
            const SizedBox(height: 4),
            Text(
              'Add an offset to every reading so it matches a known reference.',
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      activeTrackColor: accent,
                      inactiveTrackColor:
                          c.borderSubtle.withValues(alpha: 0.7),
                      thumbColor: accent,
                      overlayColor: accent.withValues(alpha: 0.18),
                      trackHeight: 3,
                    ),
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
                  width: 64,
                  child: Text(
                    '${_p.calibrationOffset >= 0 ? "+" : ""}${_p.calibrationOffset.toStringAsFixed(1)} dB',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 28),
              ),
              onPressed: () =>
                  _apply(_p.copyWith(calibrationOffset: 0.0)),
              child: Text(
                'Reset to 0',
                style: TextStyle(
                  color: accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 14),

            // ── A-weighting ────────────────────────────────────────────────
            _ToggleRow(
              title: 'A-weighting',
              subtitle:
                  'De-emphasises low rumble and very high treble to match human hearing. Approximate — phone mics aren\'t certified.',
              value: _p.aWeighting,
              accent: accent,
              colors: c,
              onChanged: (v) => _apply(_p.copyWith(aWeighting: v)),
            ),

            const SizedBox(height: 18),
            Divider(color: c.borderSubtle, height: 1),
            const SizedBox(height: 14),

            // ── Threshold alert ────────────────────────────────────────────
            _SectionLabel('THRESHOLD ALERT', colors: c),
            const SizedBox(height: 4),
            _ToggleRow(
              title: 'Buzz when it gets loud',
              subtitle:
                  'Haptic feedback if the 10 s average stays above the threshold for 3 s.',
              value: _p.alertEnabled,
              accent: accent,
              colors: c,
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
                        data: SliderThemeData(
                          activeTrackColor: accent,
                          inactiveTrackColor:
                              c.borderSubtle.withValues(alpha: 0.7),
                          thumbColor: accent,
                          overlayColor: accent.withValues(alpha: 0.18),
                          trackHeight: 3,
                        ),
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
                      width: 56,
                      child: Text(
                        '${_p.alertThresholdDb} dB',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),

            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  backgroundColor: accent.withValues(alpha: 0.12),
                  foregroundColor: accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Done',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final AppColors colors;
  const _SectionLabel(this.text, {required this.colors});

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      );
}

class _ToggleRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final Color accent;
  final AppColors colors;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.accent,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  )),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: TextStyle(
                      color: colors.textSecondary, fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Switch(
          value: value,
          activeThumbColor: Colors.white,
          activeTrackColor: accent,
          inactiveTrackColor: colors.surfaceElevated,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
