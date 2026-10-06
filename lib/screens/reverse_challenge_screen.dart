import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../services/clip_player.dart';
import '../services/clip_repository.dart';
import '../services/haptics.dart';
import '../services/mic_clip_recorder.dart';
import '../services/reverse_score.dart';
import '../services/wav.dart';
import '../theme/app_colors.dart';
import '../widgets/permission_denied_card.dart';
import '../widgets/reverse_challenge_widgets.dart';
import '../widgets/share_card.dart' show soundrPlayStoreUrl;
import 'clip_editor_screen.dart';

const _kRate = MicClipRecorder.sampleRate;
const _kPrefBest = 'reverse_best';
const _kPhraseMax = Duration(seconds: 6);
const _kAttemptMax = Duration(seconds: 8);

/// Bars in the live level strip: one per 125 ms of the maximum length.
const _kSlot = Duration(milliseconds: 125);

/// Phrases to suggest in step 1.
const reversePhrases = [
  'Banana pancakes',
  'Hello, how are you?',
  'I love pizza',
  'Soundr is awesome',
  'Happy birthday to you',
  'Red lorry, yellow lorry',
  'Peanut butter sandwich',
  'Good morning, sunshine',
  'Where are my keys?',
  'Rock and roll',
  'See you later, alligator',
  'Chocolate milkshake',
  'Let’s go to the beach',
  'My cat is a genius',
  'Supercalifragilistic',
  'Twinkle, twinkle, little star',
  'Pass the salt, please',
  'Never gonna give up',
  'Abracadabra',
  'Pineapple on pizza',
];

enum _Step { phrase, copy, reveal }

// Player tags.
const _tOriginal = 'original';
const _tOriginalReversed = 'originalReversed';
const _tAttemptReversed = 'attemptReversed';
const _tAttempt = 'attempt';

/// Reverse Audio Challenge: record a phrase, hear it backwards, copy the
/// backwards sounds, and hear your copy flipped back — if you copied well,
/// it sounds like the original. Scored 0–100.
class ReverseChallengeScreen extends StatefulWidget {
  /// Supplies 16-bit PCM at 44.1 kHz instead of the microphone, one stream
  /// per recording, and skips the permission request and saved best (tests).
  @visibleForTesting
  final Stream<Uint8List> Function()? debugMic;

  /// First suggested phrase (tests); random otherwise.
  @visibleForTesting
  final int? debugPhrase;

  /// Plays clips instead of a [ClipPlayer] on SoLoud (tests, where the
  /// native audio library isn't loaded). The screen disposes it.
  @visibleForTesting
  final ClipPlayer? debugPlayer;

  const ReverseChallengeScreen({
    super.key,
    this.debugMic,
    this.debugPhrase,
    this.debugPlayer,
  });

  @override
  State<ReverseChallengeScreen> createState() => _ReverseChallengeScreenState();
}

class _ReverseChallengeScreenState extends State<ReverseChallengeScreen>
    with WidgetsBindingObserver {
  final _rnd = Random();
  late final ClipPlayer _player = widget.debugPlayer ?? ClipPlayer();

  _Step _step = _Step.phrase;
  late int _phrase =
      widget.debugPhrase ?? _rnd.nextInt(reversePhrases.length);

  // Clips (silence trimmed).
  Float64List? _original, _originalReversed, _attempt, _attemptReversed;
  List<double> _originalBars = const [], _originalReversedBars = const [];
  List<double> _attemptBars = const [], _attemptReversedBars = const [];

  // Recording.
  MicClipRecorder? _rec;
  bool _starting = false, _stopping = false;
  final _level = ValueNotifier<double>(0);
  Duration _elapsed = Duration.zero;
  List<double> _live = const [];
  PermissionStatus? _micDenied;

  // Result.
  int? _score;
  int? _best; // before this round's score
  bool _newBest = false;

  Timer? _autoPlay;

  bool get _recording => _rec != null;
  Duration get _maxLength =>
      _step == _Step.phrase ? _kPhraseMax : _kAttemptMax;
  int get _slots => _maxLength.inMilliseconds ~/ _kSlot.inMilliseconds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _live = List.filled(_slots, 0);
    _loadBest();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoPlay?.cancel();
    _rec?.dispose();
    _player.dispose();
    _level.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Don't keep the mic or a speaker going in the background.
      _autoPlay?.cancel();
      _player.stop();
      if (_recording) _cancelRecording();
    }
  }

  Future<void> _loadBest() async {
    if (widget.debugMic != null) return;
    try {
      final best = await ClipRepository.getInt(_kPrefBest);
      if (mounted && best != null) setState(() => _best = best);
    } catch (_) {}
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<bool> _micAllowed() async {
    if (widget.debugMic != null) return true;
    final status = await Permission.microphone.request();
    if (!mounted) return false;
    if (!status.isGranted) {
      setState(() => _micDenied = status);
      return false;
    }
    return true;
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    if (_recording || _starting) return;
    _starting = true;
    try {
      _autoPlay?.cancel();
      await _player.stop();
      if (!await _micAllowed()) return;
      Haptics.medium();
      final rec = MicClipRecorder(
        maxLength: _maxLength,
        onAutoStop: _stopRecording,
        debugStream: widget.debugMic?.call(),
      );
      rec.level.addListener(() => _level.value = rec.level.value);
      rec.elapsed.addListener(() => _onElapsed(rec));
      setState(() {
        _rec = rec;
        _elapsed = Duration.zero;
        _live = List.filled(_slots, 0);
      });
      try {
        await rec.start();
      } catch (_) {
        if (!mounted) return;
        _discard(rec);
        _snack('Couldn’t open the microphone — try again');
      }
    } finally {
      _starting = false;
    }
  }

  void _onElapsed(MicClipRecorder rec) {
    if (!mounted || _rec != rec) return;
    final e = rec.elapsed.value;
    final slot = (e.inMilliseconds ~/ _kSlot.inMilliseconds)
        .clamp(0, _live.length - 1);
    final live = _live;
    if (rec.level.value > live[slot]) live[slot] = rec.level.value;
    setState(() => _elapsed = e);
  }

  void _discard(MicClipRecorder rec) {
    rec.dispose();
    _level.value = 0;
    setState(() {
      _rec = null;
      _elapsed = Duration.zero;
    });
  }

  void _cancelRecording() {
    final rec = _rec;
    if (rec != null) _discard(rec);
  }

  Future<void> _stopRecording() async {
    final rec = _rec;
    if (rec == null || _stopping) return;
    _stopping = true;
    try {
      final raw = await rec.stop();
      if (!mounted) return;
      _discard(rec);
      Haptics.medium();
      final clip = ReverseScore.trimSilence(raw, sampleRate: _kRate);
      if (ReverseScore.soundSeconds(clip, sampleRate: _kRate) < 0.25) {
        _snack('Didn’t catch that — try again a little louder');
        return;
      }
      if (_step == _Step.phrase) {
        _setPhraseClip(clip);
      } else if (_step == _Step.copy) {
        _setAttemptClip(clip);
      }
    } finally {
      _stopping = false;
    }
  }

  void _setPhraseClip(Float64List clip) {
    final rev = ReverseScore.reverse(clip);
    setState(() {
      _original = clip;
      _originalReversed = rev;
      _originalBars = peakEnvelope(clip, 40);
      _originalReversedBars = peakEnvelope(rev, 48);
      _step = _Step.copy;
      _live = List.filled(_slots, 0);
    });
    _playSoon(_tOriginalReversed, const Duration(milliseconds: 450));
  }

  void _setAttemptClip(Float64List clip) {
    final original = _original;
    if (original == null) return;
    final rev = ReverseScore.reverse(clip);
    final score = ReverseScore.compare(original, rev, sampleRate: _kRate);
    final best = _best;
    final newBest = best == null || score > best;
    setState(() {
      _attempt = clip;
      _attemptReversed = rev;
      _attemptBars = peakEnvelope(clip, 40);
      _attemptReversedBars = peakEnvelope(rev, 40);
      _score = score;
      _newBest = newBest;
      _step = _Step.reveal;
    });
    if (newBest) {
      _best = score;
      if (widget.debugMic == null) {
        ClipRepository.setInt(_kPrefBest, score).catchError((_) {});
      }
    }
    if (ReverseScore.stars(score) == 3) {
      Haptics.heavy();
    }
    _playSoon(_tAttemptReversed, const Duration(milliseconds: 700));
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  Float64List? _clip(String tag) => switch (tag) {
    _tOriginal => _original,
    _tOriginalReversed => _originalReversed,
    _tAttemptReversed => _attemptReversed,
    _tAttempt => _attempt,
    _ => null,
  };

  void _playSoon(String tag, Duration delay) {
    _autoPlay?.cancel();
    _autoPlay = Timer(delay, () {
      if (mounted && !_recording) _play(tag);
    });
  }

  void _play(String tag) {
    final clip = _clip(tag);
    if (clip == null) return;
    _player.play(clip, tag: tag, sampleRate: _kRate);
  }

  void _togglePlay(String tag) {
    if (_recording) return;
    _autoPlay?.cancel();
    Haptics.light();
    if (_player.playing.value == tag) {
      _player.stop();
    } else {
      _play(tag);
    }
  }

  // ── Navigation between steps ──────────────────────────────────────────────

  void _shufflePhrase() {
    Haptics.selection();
    setState(() {
      var next = _phrase;
      while (next == _phrase) {
        next = _rnd.nextInt(reversePhrases.length);
      }
      _phrase = next;
    });
  }

  void _rerecordPhrase() {
    Haptics.light();
    _autoPlay?.cancel();
    _player.stop();
    _cancelRecording();
    setState(() {
      _step = _Step.phrase;
      _live = List.filled(_slots, 0);
    });
  }

  void _tryAgain() {
    Haptics.light();
    _autoPlay?.cancel();
    _player.stop();
    setState(() {
      _step = _Step.copy;
      _live = List.filled(_slots, 0);
    });
  }

  void _newPhrase() {
    _rerecordPhrase();
    _shufflePhrase();
  }

  // ── Share / save ──────────────────────────────────────────────────────────

  Future<String?> _writeAttempt() async {
    final clip = _attemptReversed;
    if (clip == null) return null;
    try {
      return await Wav.writeTemp(
        clip,
        name: 'Reverse challenge ${DateTime.now().millisecondsSinceEpoch}',
        sampleRate: _kRate,
      );
    } catch (_) {
      _snack('Couldn’t save the clip — try again');
      return null;
    }
  }

  Future<void> _share() async {
    Haptics.light();
    _autoPlay?.cancel();
    await _player.stop();
    final path = await _writeAttempt();
    if (path == null) return;
    try {
      await Share.shareXFiles(
        [XFile(path, mimeType: 'audio/wav')],
        text:
            'I said it backwards, then flipped it — ${_score ?? 0}/100 in '
            'Soundr’s Reverse Challenge. Can you tell what I said?\n'
            '$soundrPlayStoreUrl',
      );
    } catch (_) {
      _snack('Couldn’t share the clip — try again');
    }
  }

  Future<void> _addToSoundboard() async {
    Haptics.light();
    _autoPlay?.cancel();
    await _player.stop();
    final path = await _writeAttempt();
    if (path == null || !mounted) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ClipEditorScreen(filePath: path)),
    );
    if (saved == true && mounted) _snack('Added to your soundboard');
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Reverse Challenge',
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
                        'The challenge records short clips of your voice to '
                        'play them backwards. They stay on your phone unless '
                        'you share them.',
                    onGranted: () {
                      if (mounted) setState(() => _micDenied = null);
                    },
                  ),
                ),
              )
            : Column(
                children: [
                  ReverseStepHeader(step: _step.index),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => AnimatedSwitcher(
                        duration: const Duration(milliseconds: 320),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, a) => FadeTransition(
                          opacity: a,
                          child: SlideTransition(
                            position: Tween(
                              begin: const Offset(0.06, 0),
                              end: Offset.zero,
                            ).animate(a),
                            child: child,
                          ),
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(_step),
                          child: _page(box.maxHeight < 600),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _page(bool compact) {
    final Widget body = switch (_step) {
      _Step.phrase => _phrasePage(compact),
      _Step.copy => _copyPage(compact),
      _Step.reveal => _revealPage(compact),
    };
    return CustomScrollView(
      slivers: [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: body,
          ),
        ),
      ],
    );
  }

  Widget _title(String title, String subtitle, {bool compact = false}) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: compact ? 22 : 24,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(color: c.textSecondary, fontSize: 14.5, height: 1.3),
        ),
      ],
    );
  }

  /// Level strip, record button and timer.
  Widget _recorder({required String idleLabel, required bool compact}) {
    final c = Theme.of(context).extension<AppColors>()!;
    final max = _maxLength;
    final secs = _elapsed.inMilliseconds / 1000;
    final filled = (_elapsed.inMilliseconds / _kSlot.inMilliseconds).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ReverseLevelStrip(
          levels: _live,
          filled: _recording ? filled : 0,
          recording: _recording,
          height: compact ? 32 : 40,
        ),
        SizedBox(height: compact ? 4 : 10),
        ReverseRecordButton(
          recording: _recording,
          level: _level,
          progress: _elapsed.inMilliseconds / max.inMilliseconds,
          onTap: _toggleRecording,
          idleLabel: idleLabel,
          size: compact ? 92 : 108,
        ),
        SizedBox(height: compact ? 2 : 6),
        SizedBox(
          height: 24,
          child: _recording
              ? Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${secs.toStringAsFixed(1)} s',
                        style: TextStyle(
                          color: ReversePalette.of(context).rec,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      TextSpan(
                        text: '  of ${max.inSeconds} s · tap to stop',
                        style: TextStyle(color: c.textSecondary),
                      ),
                    ],
                  ),
                  style: const TextStyle(
                    fontSize: 15,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                )
              : Text(
                  '$idleLabel · up to ${max.inSeconds} s',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _phrasePage(bool compact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(
          'Say something',
          'Record a short phrase — you’ll hear it backwards.',
          compact: compact,
        ),
        SizedBox(height: compact ? 12 : 18),
        ReversePhraseCard(
          phrase: reversePhrases[_phrase],
          onShuffle: _recording ? null : _shufflePhrase,
        ),
        const Spacer(),
        SizedBox(height: compact ? 8 : 16),
        _recorder(idleLabel: 'Tap to record', compact: compact),
        const Spacer(),
      ],
    );
  }

  Widget _copyPage(bool compact) {
    final rev = _originalReversed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _title(
          'Copy it backwards',
          'Listen a few times, then copy the sounds.',
          compact: compact,
        ),
        SizedBox(height: compact ? 12 : 18),
        if (rev != null)
          _ClipFor(
            player: _player,
            tag: _tOriginalReversed,
            builder: (progress) => ReverseClipTile(
              big: true,
              label: 'Your phrase, backwards',
              caption: 'Tap to listen again',
              levels: _originalReversedBars,
              duration: _duration(rev),
              progress: progress,
              onTap: _recording ? null : () => _togglePlay(_tOriginalReversed),
            ),
          ),
        const Spacer(),
        SizedBox(height: compact ? 8 : 16),
        _recorder(idleLabel: 'Record your copy', compact: compact),
        const Spacer(),
        Center(
          child: TextButton.icon(
            onPressed: _recording ? null : _rerecordPhrase,
            icon: const Icon(Icons.restart_alt_rounded, size: 20),
            label: const Text('Re-record phrase'),
            style: _textButtonStyle(),
          ),
        ),
      ],
    );
  }

  Widget _revealPage(bool compact) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    final score = _score ?? 0;
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    Widget tile(String tag, String label, List<double> bars, IconData icon) {
      final clip = _clip(tag);
      if (clip == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _ClipFor(
          player: _player,
          tag: tag,
          builder: (progress) => ReverseClipTile(
            label: label,
            icon: icon,
            levels: bars,
            duration: _duration(clip),
            progress: progress,
            onTap: () => _togglePlay(tag),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReverseScoreCard(
          score: score,
          stars: ReverseScore.stars(score),
          message: ReverseScore.message(score),
          best: _best,
          newBest: _newBest,
          compact: compact,
        ),
        SizedBox(height: compact ? 12 : 18),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            'Compare',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ),
        tile(_tOriginal, 'Original', _originalBars, Icons.play_arrow_rounded),
        tile(
          _tAttemptReversed,
          'Your attempt, reversed',
          _attemptReversedBars,
          Icons.play_arrow_rounded,
        ),
        tile(
          _tAttempt,
          'Your attempt as recorded',
          _attemptBars,
          Icons.play_arrow_rounded,
        ),
        const Spacer(),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: _newPhrase,
                  icon: const Icon(Icons.shuffle_rounded, size: 20),
                  label: const Text('New phrase'),
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
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 52,
                child: FilledButton.icon(
                  onPressed: _tryAgain,
                  icon: const Icon(Icons.replay_rounded, size: 20),
                  label: const Text('Try again'),
                  style: FilledButton.styleFrom(
                    backgroundColor: p.tint,
                    foregroundColor: p.onTint,
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
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: _share,
              icon: const Icon(Icons.ios_share_rounded, size: 19),
              label: const Text('Share'),
              style: _textButtonStyle(),
            ),
            TextButton.icon(
              onPressed: _addToSoundboard,
              icon: const Icon(Icons.add_circle_outline_rounded, size: 19),
              label: const Text('Add to soundboard'),
              style: _textButtonStyle(),
            ),
          ],
        ),
      ],
    );
  }

  ButtonStyle _textButtonStyle() {
    final p = ReversePalette.of(context);
    return TextButton.styleFrom(
      foregroundColor: p.tintText,
      minimumSize: const Size(0, 44),
      textStyle: TextStyle(
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        fontSize: 14.5,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  static Duration _duration(Float64List clip) =>
      Duration(microseconds: clip.length * 1000000 ~/ _kRate);
}

/// Rebuilds [builder] with this clip's playhead (null when it isn't the
/// one playing).
class _ClipFor extends StatelessWidget {
  final ClipPlayer player;
  final String tag;
  final Widget Function(double? progress) builder;

  const _ClipFor({
    required this.player,
    required this.tag,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Object?>(
      valueListenable: player.playing,
      builder: (context, playing, _) => ValueListenableBuilder<double?>(
        valueListenable: player.progress,
        builder: (context, progress, _) =>
            builder(playing == tag ? (progress ?? 0) : null),
      ),
    );
  }
}
