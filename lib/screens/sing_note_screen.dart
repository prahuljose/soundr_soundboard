import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../services/clip_repository.dart';
import '../services/guitar_tuning.dart' show midiToHz, noteName;
import '../services/haptics.dart';
import '../services/pitch_detector.dart';
import '../services/reference_tone.dart';
import '../services/sing_note_game.dart';
import '../theme/app_colors.dart';
import '../widgets/permission_denied_card.dart';
import '../widgets/share_card.dart';
import '../widgets/sing_note_widgets.dart';

const _kRate = 44100;
const _kPrefBest = 'sing_note_best';

/// How long the reference tone plays before it's your turn.
const _kListen = Duration(milliseconds: 1800);

/// After the tone, the mic keeps being ignored this long (its tail and the
/// room's echo would otherwise count as singing).
const _kMuteTailMs = 250;

/// How long the tick / "time's up" stays before the next note.
const _kFeedback = Duration(milliseconds: 1100);
const _kFeedbackSkip = Duration(milliseconds: 500);

enum _Phase { intro, listen, sing, feedback, results }

/// Sing the Note: the app plays a note, you sing or hum it back, and a live
/// meter shows how close you are. Hold it in tune to fill the ring. Eight
/// notes a round, scored out of 100.
class SingNoteScreen extends StatefulWidget {
  /// Feeds 16-bit PCM at 44.1 kHz instead of the microphone (tests). Also
  /// turns off the real tone and saved scores.
  @visibleForTesting
  final Stream<Uint8List>? debugAudio;

  /// The round's notes (MIDI) instead of a random pick (tests).
  @visibleForTesting
  final List<int>? debugNotes;

  /// Personal best to show instead of the saved one (tests).
  @visibleForTesting
  final int? debugBest;

  const SingNoteScreen({
    super.key,
    this.debugAudio,
    this.debugNotes,
    this.debugBest,
  });

  @override
  State<SingNoteScreen> createState() => _SingNoteScreenState();
}

class _SingNoteScreenState extends State<SingNoteScreen>
    with WidgetsBindingObserver {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  // Voice settings: 70 Hz–1 kHz covers a low hum to a high soprano note, and
  // a breathy or quiet voice is less cleanly periodic than a plucked string.
  late final PitchDetector _detector = PitchDetector(
    sampleRate: _kRate,
    minHz: 70,
    maxHz: 1000,
    minClarity: 0.8,
    silenceRms: 0.008,
    onReading: _onPitch,
  );

  _Phase _phase = _Phase.intro;
  List<int> _notes = const [];
  int _index = 0;
  final List<SingNoteResult> _results = [];
  SingNoteTracker? _tracker;
  SingOutcome? _lastOutcome;
  int _listenToken = 0;
  Timer? _timer;

  PermissionStatus? _micDenied;
  String? _error;
  bool _listening = false;
  bool _starting = false;
  bool _interrupted = false; // app went to the background mid-round

  int? _best;
  int _score = 0;
  bool _newBest = false;

  bool get _real => widget.debugAudio == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _best = widget.debugBest;
    _loadBest();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    if (_real) ReferenceTone.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final playing =
        _phase == _Phase.listen ||
        _phase == _Phase.sing ||
        _phase == _Phase.feedback;
    if (state == AppLifecycleState.paused) {
      if (!playing) return;
      // Release the mic and hold the round where it is.
      _timer?.cancel();
      if (_real) ReferenceTone.stop();
      _interrupted = true;
      _stopMic();
    } else if (state == AppLifecycleState.resumed && _interrupted) {
      _interrupted = false;
      _resume();
    }
  }

  Future<void> _resume() async {
    if (!await _startMic() || !mounted) return;
    if (_phase == _Phase.feedback) {
      _advance();
    } else {
      _listen(); // hear the note again, free of charge
    }
  }

  Future<void> _loadBest() async {
    if (!_real) return;
    try {
      final best = await ClipRepository.getInt(_kPrefBest);
      if (mounted && best != null) setState(() => _best = best);
    } catch (_) {}
  }

  // ── Microphone ──────────────────────────────────────────────────────────

  /// Opens the mic if it isn't already; false if that didn't work.
  Future<bool> _startMic() async {
    if (_listening) return true;
    if (_starting) return false;
    _starting = true;
    try {
      return await _open();
    } finally {
      _starting = false;
    }
  }

  Future<bool> _open() async {
    final Stream<Uint8List> stream;
    try {
      final debug = widget.debugAudio;
      if (debug != null) {
        stream = debug;
      } else {
        final status = await Permission.microphone.request();
        if (!mounted) return false;
        if (!status.isGranted) {
          setState(() => _micDenied = status);
          return false;
        }
        stream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: _kRate,
            numChannels: 1,
            // Voice processing bends a held note; keep it raw.
            autoGain: false,
            echoCancel: false,
            noiseSuppress: false,
            androidConfig: AndroidRecordConfig(
              audioSource: AndroidAudioSource.voiceRecognition,
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t open the microphone.');
      return false;
    }
    if (!mounted) return false;
    _detector.reset();
    _sub = stream.listen(
      _detector.addPcm16,
      onError: (Object _) {
        if (mounted) setState(() => _error = 'The microphone stopped.');
      },
    );
    setState(() {
      _listening = true;
      _micDenied = null;
      _error = null;
    });
    return true;
  }

  Future<void> _stopMic() async {
    _listening = false;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    if (_real) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
  }

  // ── Round ───────────────────────────────────────────────────────────────

  Future<void> _startRound() async {
    if (_starting) return;
    Haptics.light();
    if (!await _startMic() || !mounted) return;
    _notes = widget.debugNotes ?? SingNoteGame.pickNotes(Random());
    _index = 0;
    _results.clear();
    _newBest = false;
    _beginNote();
  }

  void _beginNote() {
    _tracker = SingNoteTracker(targetMidi: _notes[_index]);
    _lastOutcome = null;
    _listen();
  }

  /// Plays the note; the mic is ignored until it's over.
  void _listen({bool replay = false}) {
    _timer?.cancel();
    if (_real) ReferenceTone.play(midiToHz(_notes[_index]));
    setState(() {
      _phase = _Phase.listen;
      _listenToken++;
    });
    _timer = Timer(_kListen, () => _beginSing(replay: replay));
  }

  void _beginSing({bool replay = false}) {
    if (!mounted) return;
    if (_real) ReferenceTone.stop();
    _tracker!.begin(_detector.audioMs + _kMuteTailMs, replay: replay);
    setState(() => _phase = _Phase.sing);
  }

  void _onPitch(PitchReading? r) {
    if (_phase != _Phase.sing || !mounted) return;
    final t = _tracker!;
    final was = t.status;
    t.add(r?.hz, _detector.audioMs);
    if (t.done) {
      _finishNote(SingOutcome.success);
    } else if (t.timedOut) {
      _finishNote(SingOutcome.timeout);
    } else {
      if (t.status == SingStatus.inTune && was != SingStatus.inTune) {
        Haptics.selection();
      }
      setState(() {});
    }
  }

  void _finishNote(SingOutcome outcome) {
    _timer?.cancel();
    final result = _tracker!.result(outcome);
    _results.add(result);
    if (outcome == SingOutcome.success) {
      Haptics.medium();
    } else {
      Haptics.light();
    }
    setState(() {
      _lastOutcome = outcome;
      _phase = _Phase.feedback;
    });
    _timer = Timer(
      outcome == SingOutcome.skipped ? _kFeedbackSkip : _kFeedback,
      _advance,
    );
  }

  void _advance() {
    if (!mounted) return;
    if (_index + 1 < _notes.length) {
      _index++;
      _beginNote();
    } else {
      _showResults();
    }
  }

  void _hearAgain() {
    if (_phase != _Phase.sing) return;
    Haptics.light();
    _listen(replay: true);
  }

  void _skip() {
    if (_phase != _Phase.sing && _phase != _Phase.listen) return;
    if (_real) ReferenceTone.stop();
    _finishNote(SingOutcome.skipped);
  }

  void _showResults() {
    _stopMic();
    final score = SingNoteGame.total(_results, count: _notes.length);
    final newBest = score > (_best ?? 0);
    if (newBest) Haptics.heavy();
    setState(() {
      _score = score;
      _newBest = newBest;
      if (newBest) _best = score;
      _phase = _Phase.results;
    });
    if (newBest && _real) {
      ClipRepository.setInt(_kPrefBest, score).catchError((_) {});
    }
  }

  void _share() {
    final hits = _results.where((r) => r.grade == SingGrade.hit).length;
    showShareCardSheet(
      context,
      fileName: 'soundr-sing-the-note-$_score',
      shareText:
          'I scored $_score/100 in Soundr’s Sing the Note 🎤 '
          'Can you sing in tune?',
      card: ShareCard(
        eyebrow: 'Sing the Note',
        emoji: '🎤',
        value: '$_score',
        unit: 'out of 100',
        badge: _newBest ? '🏆  New personal best' : null,
        stats: [
          '$hits of ${_notes.length} notes hit',
          '⭐' * SingNoteGame.stars(_score),
        ],
        tagline: 'Can you sing\nin tune?',
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Sing the Note',
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
                        'The game listens to you sing through the microphone. '
                        'Audio is processed on your phone — nothing is recorded or sent.',
                    onGranted: () {
                      if (!mounted) return;
                      setState(() => _micDenied = null);
                      if (_phase == _Phase.intro) {
                        _startRound();
                      } else {
                        _resume();
                      }
                    },
                  ),
                ),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: switch (_phase) {
                  _Phase.intro => _Intro(
                    key: const ValueKey('intro'),
                    best: _best,
                    error: _error,
                    onStart: _startRound,
                  ),
                  _Phase.results => _Results(
                    key: const ValueKey('results'),
                    score: _score,
                    best: _best,
                    newBest: _newBest,
                    results: _results,
                    onShare: _share,
                    onAgain: _startRound,
                  ),
                  _ => _buildPlay(c),
                },
              ),
      ),
    );
  }

  Widget _buildPlay(AppColors c) {
    final t = _tracker!;
    final midi = _notes[_index];
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final p = SingPalette.of(context);

    final SingStageMode mode = switch (_phase) {
      _Phase.listen => SingStageMode.listen,
      _Phase.feedback =>
        _lastOutcome == SingOutcome.success
            ? SingStageMode.hit
            : SingStageMode.missed,
      _ => SingStageMode.sing,
    };

    final (String text, IconData? icon, SingCue cue) = switch (_phase) {
      _Phase.listen => ('Listen…', Icons.volume_up_rounded, SingCue.neutral),
      _Phase.feedback => switch (_lastOutcome) {
        SingOutcome.success => (
          (t.meanAbsCents ?? 99) <= 8 ? 'Spot on!' : 'Nice!',
          Icons.check_rounded,
          SingCue.good,
        ),
        SingOutcome.skipped => (
          'Skipped',
          Icons.skip_next_rounded,
          SingCue.bad,
        ),
        _ => (
          _results.last.grade == SingGrade.close ? 'So close!' : 'Time’s up',
          Icons.timer_off_outlined,
          SingCue.bad,
        ),
      },
      _ when _error != null => (_error!, Icons.mic_off_rounded, SingCue.bad),
      _ => switch (t.status) {
        SingStatus.waiting => (
          'Now sing or hum it',
          Icons.mic_rounded,
          SingCue.neutral,
        ),
        SingStatus.low => ('Too low', Icons.arrow_upward_rounded, SingCue.warn),
        SingStatus.high => (
          'Too high',
          Icons.arrow_downward_rounded,
          SingCue.warn,
        ),
        SingStatus.inTune => ('Hold it…', null, SingCue.good),
      },
    };

    final singing = _phase == _Phase.sing;
    return Padding(
      key: const ValueKey('play'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        children: [
          SingRoundHeader(
            index: _index,
            count: _notes.length,
            grades: [for (final r in _results) r.grade],
          ),
          const SizedBox(height: 12),
          SingTimeBar(left: t.timeLeft, visible: singing),
          const SizedBox(height: 8),
          Expanded(
            child: Semantics(
              label: 'Target note ${noteName(midi)}',
              child: SingStage(
                note: noteName(midi),
                mode: mode,
                status: t.status,
                cents: t.cents,
                progress: t.progress,
                listenFor: _kListen,
                listenToken: _listenToken,
                nearMiss:
                    _phase == _Phase.feedback &&
                    _results.last.grade == SingGrade.close,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SingGuidance(text: text, icon: icon, cue: cue),
          const SizedBox(height: 8),
          Text(
            'Any octave works — pick what’s comfortable',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: singing ? _hearAgain : null,
                    icon: const Icon(Icons.volume_up_rounded, size: 20),
                    label: const Text('Hear it again'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textPrimary,
                      side: BorderSide(color: c.border),
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
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 52,
                child: TextButton(
                  onPressed: _phase == _Phase.feedback ? null : _skip,
                  style: TextButton.styleFrom(
                    foregroundColor: p.tintText,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: TextStyle(
                      fontFamily: font,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: const Text('Skip'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Start ───────────────────────────────────────────────────────────────────

class _Intro extends StatelessWidget {
  final int? best;
  final String? error;
  final VoidCallback onStart;

  const _Intro({
    super.key,
    required this.best,
    required this.error,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxHeight < 620;
        final disc = compact ? 96.0 : 144.0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Container(
                width: disc,
                height: disc,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.wash,
                  border: Border.all(
                    color: p.tint.withValues(alpha: p.dark ? 0.45 : 0.7),
                    width: 2,
                  ),
                ),
                child: Icon(
                  Icons.mic_external_on_rounded,
                  size: disc * 0.46,
                  color: p.tintText,
                ),
              ),
              SizedBox(height: compact ? 14 : 26),
              Text(
                'Sing the Note',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Listen to a note, then sing or hum it back.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 16,
                  height: 1.35,
                ),
              ),
              SizedBox(height: compact ? 14 : 26),
              const Row(
                children: [
                  Expanded(
                    child: _Step(
                      icon: Icons.volume_up_rounded,
                      title: 'Listen',
                      text: 'to the note',
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: _Step(
                      icon: Icons.mic_rounded,
                      title: 'Sing',
                      text: 'or hum it',
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: _Step(
                      icon: Icons.donut_large_rounded,
                      title: 'Hold',
                      text: 'to fill the ring',
                    ),
                  ),
                ],
              ),
              const Spacer(flex: 3),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: p.bad, fontSize: 14),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: SingBestPill(best: best),
                ),
              SizedBox(
                width: double.infinity,
                height: 58,
                child: FilledButton.icon(
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow_rounded, size: 26),
                  label: const Text('Start'),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.tint,
                    foregroundColor: p.onTint,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    textStyle: TextStyle(
                      fontFamily: font,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '8 notes · about a minute',
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Step extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;

  const _Step({required this.icon, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 12),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 22, color: p.tintText),
          const SizedBox(height: 6),
          Text(
            title,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

// ── Results ─────────────────────────────────────────────────────────────────

class _Results extends StatelessWidget {
  final int score;
  final int? best;
  final bool newBest;
  final List<SingNoteResult> results;
  final VoidCallback onShare;
  final VoidCallback onAgain;

  const _Results({
    super.key,
    required this.score,
    required this.best,
    required this.newBest,
    required this.results,
    required this.onShare,
    required this.onAgain,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    final textStyle = TextStyle(
      fontFamily: font,
      fontSize: 15,
      fontWeight: FontWeight.w700,
    );
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxHeight < 620;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      SingScoreCard(
                        score: score,
                        stars: SingNoteGame.stars(score),
                        message: SingNoteGame.message(score),
                        best: best,
                        newBest: newBest,
                        compact: compact,
                      ),
                      const SizedBox(height: 12),
                      SingResultRow(
                        notes: [
                          for (final r in results)
                            (note: noteName(r.midi), grade: r.grade),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: onShare,
                        icon: const Icon(Icons.ios_share_rounded, size: 19),
                        label: const Text('Share'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.textPrimary,
                          side: BorderSide(color: c.border),
                          shape: shape,
                          textStyle: textStyle,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: FilledButton.icon(
                        onPressed: onAgain,
                        icon: const Icon(Icons.replay_rounded, size: 20),
                        label: const Text('Play again'),
                        style: FilledButton.styleFrom(
                          backgroundColor: p.tint,
                          foregroundColor: p.onTint,
                          shape: shape,
                          textStyle: textStyle,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
