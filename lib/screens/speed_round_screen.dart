import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/sound_model.dart';
import '../services/personal_bests.dart';
import '../services/waveforms.dart';
import '../theme/app_colors.dart';
import '../widgets/share_card.dart';
import '../widgets/speed_round_widgets.dart';

enum _GamePhase { readyUp, playing }

const _tabular = [FontFeature.tabularFigures()];

/// Pre-fills a game in progress (or a finished one) so goldens can render the
/// in-game layout without audio, timers or the database. Never used by the
/// app itself.
@visibleForTesting
class SpeedRoundDebugSeed {
  /// Index into the screen's first four sounds, which become the options.
  final int targetIndex;
  final int? chosenIndex;
  final int score;
  final int streak;
  final int questionsAnswered;
  final double timeLeft;
  final int? scoreGained;
  final bool gameOver;
  final int? bestScore;
  final bool isNewBest;

  /// Stay on the pre-game screen instead of seeding a question.
  final bool ready;

  const SpeedRoundDebugSeed({
    this.ready = false,
    this.targetIndex = 0,
    this.chosenIndex,
    this.score = 0,
    this.streak = 0,
    this.questionsAnswered = 0,
    this.timeLeft = 5,
    this.scoreGained,
    this.gameOver = false,
    this.bestScore,
    this.isNewBest = false,
  });
}

class SpeedRoundScreen extends StatefulWidget {
  final List<SoundModel> sounds;
  final Map<String, AudioSource> preloaded;

  @visibleForTesting
  final SpeedRoundDebugSeed? debugSeed;

  const SpeedRoundScreen({
    super.key,
    required this.sounds,
    required this.preloaded,
    this.debugSeed,
  });

  @override
  State<SpeedRoundScreen> createState() => _SpeedRoundScreenState();
}

class _SpeedRoundScreenState extends State<SpeedRoundScreen>
    with SingleTickerProviderStateMixin {
  static const _roundDuration = 5.0;
  static const _minSounds = 8;
  static const _waveBars = 16;

  late final List<SoundModel> _loadedSounds;
  final _rng = Random();

  _GamePhase _gamePhase = _GamePhase.readyUp;

  // Game state
  int _score = 0;
  int _streak = 0;
  int _questionsAnswered = 0;
  SoundModel? _target;
  List<SoundModel> _options = [];
  bool _answered = false;
  SoundModel? _chosen;
  double _scoreGained = 0;
  bool _showScoreGained = false;
  bool _gameOver = false;
  int _maxStreak = 0;
  List<double> _targetLevels = const [];

  // Personal best
  int? _bestScore;
  bool _isNewBest = false;

  // Timer
  double _timeLeft = _roundDuration;
  Timer? _countdownTimer;
  late final AnimationController _timerController;
  late final Animation<double> _remaining;
  SoundHandle? _currentHandle;

  @override
  void initState() {
    super.initState();
    final seed = widget.debugSeed;
    _loadedSounds = seed != null
        ? List.of(widget.sounds)
        : widget.sounds.where((s) => widget.preloaded[s.id] != null).toList();

    _timerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _remaining = ReverseAnimation(_timerController);

    if (seed != null) {
      _applySeed(seed);
      return;
    }
    PersonalBests.speedRoundScore().then((best) {
      if (mounted) setState(() => _bestScore = best);
    });
  }

  void _applySeed(SpeedRoundDebugSeed seed) {
    _bestScore = seed.bestScore;
    if (seed.ready || _loadedSounds.length < 4) return;
    _gamePhase = _GamePhase.playing;
    _options = _loadedSounds.take(4).toList();
    _target = _options[seed.targetIndex];
    _targetLevels = Waveforms.placeholder(_target!.id, _waveBars);
    _chosen = seed.chosenIndex == null ? null : _options[seed.chosenIndex!];
    _answered = seed.chosenIndex != null || seed.gameOver;
    _score = seed.score;
    _streak = seed.streak;
    _maxStreak = seed.streak;
    _questionsAnswered = seed.questionsAnswered;
    _timeLeft = seed.timeLeft;
    _timerController.value = 1 - seed.timeLeft / _roundDuration;
    _scoreGained = (seed.scoreGained ?? 0).toDouble();
    _showScoreGained = seed.scoreGained != null;
    _gameOver = seed.gameOver;
    _isNewBest = seed.isNewBest;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _timerController.dispose();
    _stopCurrentSound();
    super.dispose();
  }

  void _stopCurrentSound() {
    if (_currentHandle != null) {
      try {
        SoLoud.instance.stop(_currentHandle!);
      } catch (_) {}
      _currentHandle = null;
    }
  }

  Future<void> _playTarget() async {
    _stopCurrentSound();
    final source = widget.preloaded[_target?.id];
    if (source == null) return;
    try {
      _currentHandle = await SoLoud.instance.play(source);
    } catch (_) {}
  }

  void _startGame() {
    setState(() {
      _gamePhase = _GamePhase.playing;
      _score = 0;
      _streak = 0;
      _questionsAnswered = 0;
      _gameOver = false;
      _maxStreak = 0;
      _isNewBest = false;
    });
    _nextQuestion();
  }

  void _nextQuestion() {
    _stopCurrentSound();
    _countdownTimer?.cancel();

    final shuffled = List<SoundModel>.from(_loadedSounds)..shuffle(_rng);
    final target = shuffled[0];
    _target = target;
    final wrongs = shuffled.sublist(1, 4);
    final opts = [...wrongs, target]..shuffle(_rng);

    setState(() {
      _options = opts;
      _answered = false;
      _chosen = null;
      _showScoreGained = false;
      _timeLeft = _roundDuration;
      _targetLevels =
          Waveforms.peek(target, bars: _waveBars) ??
          Waveforms.placeholder(target.id, _waveBars);
    });
    if (Waveforms.peek(target, bars: _waveBars) == null) {
      Waveforms.of(target, bars: _waveBars).then((levels) {
        if (mounted && _target?.id == target.id) {
          setState(() => _targetLevels = levels);
        }
      });
    }

    _timerController
      ..reset()
      ..forward();

    Future.microtask(_playTarget);

    _countdownTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _timeLeft -= 0.1;
        if (_timeLeft <= 0) {
          _timeLeft = 0;
          t.cancel();
          _onTimerExpired();
        }
      });
    });
  }

  void _onTimerExpired() {
    if (_answered) return;
    _stopCurrentSound();
    setState(() {
      _answered = true;
      _streak = 0;
      _gameOver = true;
    });
    _playSound('s35');
    _recordResult();
  }

  Future<void> _recordResult() async {
    final isNewBest = await PersonalBests.recordSpeedRound(
      score: _score,
      streak: _maxStreak,
    );
    if (!mounted) return;
    setState(() {
      _isNewBest = isNewBest;
      if (isNewBest) _bestScore = _score;
    });
  }

  void _shareScore() {
    showShareCardSheet(
      context,
      fileName: 'soundr-speed-round-$_score',
      shareText:
          'I scored $_score in Soundr’s Speed Round ⚡ '
          'Can you beat it?',
      card: ShareCard(
        eyebrow: 'Speed Round',
        emoji: '⚡',
        value: '$_score',
        unit: _score == 1 ? 'point' : 'points',
        badge: _isNewBest ? '🏆  New personal best' : null,
        stats: [
          '$_questionsAnswered correct',
          if (_maxStreak >= 3) '🔥 $_maxStreak streak',
        ],
        tagline: 'Can you beat\nmy score?',
      ),
    );
  }

  Future<void> _playSound(String id) async {
    final source = widget.preloaded[id];
    if (source == null) return;
    try {
      await SoLoud.instance.play(source);
    } catch (_) {}
  }

  void _onOptionTap(SoundModel option) {
    if (_answered) return;
    _countdownTimer?.cancel();
    _timerController.stop();

    final isCorrect = option.id == _target!.id;

    if (!isCorrect) {
      _stopCurrentSound();
      setState(() {
        _answered = true;
        _chosen = option;
        _streak = 0;
        _gameOver = true;
      });
      _playSound('s35');
      _recordResult();
      return;
    }

    _streak++;
    _maxStreak = max(_maxStreak, _streak);
    final multiplier = _streak >= 7
        ? 2.0
        : _streak >= 3
        ? 1.5
        : 1.0;
    final gained =
        (max(1, (_timeLeft / _roundDuration * 10).round()) * multiplier);

    setState(() {
      _answered = true;
      _chosen = option;
      _score = (_score + gained).round();
      _scoreGained = gained;
      _showScoreGained = true;
      _questionsAnswered++;
    });

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) _nextQuestion();
    });
  }

  double get _multiplier => _streak >= 7
      ? 2.0
      : _streak >= 3
      ? 1.5
      : 1.0;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    if (_loadedSounds.length < _minSounds) return _buildErrorState(c);

    final playing = _gamePhase == _GamePhase.playing;
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      body: Stack(
        children: [
          Positioned.fill(
            child: SafeArea(
              child: Column(
                children: [
                  _buildHeader(c, showScore: playing),
                  Expanded(
                    child: playing
                        ? _buildGame(c, accent)
                        : _buildReadyUp(c, accent),
                  ),
                ],
              ),
            ),
          ),
          // The result card dims the whole screen, header included; the
          // system back gesture still leaves the game.
          if (playing && _gameOver)
            Positioned.fill(
              child: _GameOverOverlay(
                score: _score,
                questionsAnswered: _questionsAnswered,
                timedOut: _chosen == null,
                answer: _target,
                picked: _chosen,
                onPlayAnswer: () {
                  final id = _target?.id;
                  if (id != null) _playSound(id);
                },
                bestScore: _bestScore,
                isNewBest: _isNewBest,
                accent: accent,
                colors: c,
                onShare: _shareScore,
                onPlayAgain: () => setState(() {
                  _gamePhase = _GamePhase.readyUp;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(AppColors c, {required bool showScore}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            SpeedRoundIconButton(
              icon: Icons.close_rounded,
              tooltip: 'Quit game',
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Speed Round',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (showScore) SpeedRoundScorePill(score: _score),
          ],
        ),
      ),
    );
  }

  Widget _buildBestRow(AppColors c) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.emoji_events_outlined,
          size: 17,
          color: speedRoundGold(context),
        ),
        const SizedBox(width: 7),
        Text(
          'Personal best',
          style: TextStyle(color: c.textSecondary, fontSize: 13),
        ),
        const SizedBox(width: 6),
        Text(
          _bestScore == null ? '—' : '$_bestScore',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontFeatures: _tabular,
          ),
        ),
      ],
    );
  }

  Widget _buildReadyUp(AppColors c, Color accent) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
              decoration: BoxDecoration(
                color: c.surfaceCard,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: accent.withValues(alpha: 0.35),
                        width: 2,
                      ),
                    ),
                    child: Icon(Icons.bolt_rounded, color: accent, size: 48),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Name that sound',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'A sound plays — pick the right name from 4 options '
                    'before time runs out. Answer faster for more points.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const SpeedRoundStreakPill(
                    streak: 0,
                    multiplier: 2,
                    label: 'Build a streak for up to 2× points',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            _buildBestRow(c),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed: _startGame,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                child: const Text(
                  "Let's go →",
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStreakSlot() {
    final showStreak = _streak >= 2;
    final gain = _showScoreGained
        ? SpeedRoundGainChip(
            key: ValueKey('gain$_questionsAnswered'),
            gained: _scoreGained.round(),
          )
        : const SizedBox.shrink(key: ValueKey('nogain'));
    return SizedBox(
      height: 34,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: showStreak
                ? SpeedRoundStreakPill(
                    key: const ValueKey('streak'),
                    streak: _streak,
                    multiplier: _multiplier,
                  )
                : const SizedBox.shrink(key: ValueKey('nostreak')),
          ),
          if (showStreak && _showScoreGained) const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: gain,
          ),
        ],
      ),
    );
  }

  Widget _buildGame(AppColors c, Color accent) {
    if (_target == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        // Everything except the ring is fixed height; the ring shrinks on
        // short screens (down to 180) before the column starts to scroll.
        const fixed = 22 + 34 + 22 + 22 + 20 + 12 + 76 * 2 + 10 + 20 + 20 + 24;
        final ring = (box.maxHeight - fixed).clamp(180.0, 250.0);
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    const SizedBox(height: 22),
                    _buildStreakSlot(),
                    const SizedBox(height: 22),
                    SpeedRoundRing(
                      size: ring,
                      remaining: _remaining,
                      secondsLeft: _timeLeft,
                      levels: _targetLevels,
                      enabled: !_answered,
                      onReplay: _playTarget,
                    ),
                    const SizedBox(height: 22),
                    Text(
                      'Which sound is this?',
                      style: TextStyle(color: c.textSecondary, fontSize: 15),
                    ),
                    const SizedBox(height: 12),
                    for (var row = 0; row < 2; row++) ...[
                      if (row > 0) const SizedBox(height: 10),
                      Row(
                        children: [
                          for (var col = 0; col < 2; col++) ...[
                            if (col > 0) const SizedBox(width: 10),
                            Expanded(child: _option(_options[row * 2 + col])),
                          ],
                        ],
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Spacer(),
                    _buildBestRow(c),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _option(SoundModel opt) => SpeedRoundOption(
    sound: opt,
    isTarget: opt.id == _target!.id,
    isChosen: _chosen?.id == opt.id,
    answered: _answered,
    onTap: () => _onOptionTap(opt),
  );

  Widget _buildErrorState(AppColors c) {
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(c, showScore: false),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: c.surfaceCard,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: c.border),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 48,
                          color: c.iconSecondary,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Not enough sounds loaded',
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Speed Round needs at least $_minSounds loaded sounds. '
                          'Only ${_loadedSounds.length} are available.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
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

class _GameOverOverlay extends StatelessWidget {
  final int score;
  final int questionsAnswered;
  final bool timedOut;
  final SoundModel? answer;
  final SoundModel? picked;
  final VoidCallback onPlayAnswer;
  final int? bestScore;
  final bool isNewBest;
  final Color accent;
  final AppColors colors;
  final VoidCallback onPlayAgain;
  final VoidCallback onShare;

  const _GameOverOverlay({
    required this.score,
    required this.questionsAnswered,
    required this.timedOut,
    required this.answer,
    required this.picked,
    required this.onPlayAnswer,
    required this.bestScore,
    required this.isNewBest,
    required this.accent,
    required this.colors,
    required this.onPlayAgain,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final red = speedRoundWrong(context);
    final gold = speedRoundGold(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      color: Colors.black.withValues(alpha: dark ? 0.65 : 0.4),
      alignment: Alignment.center,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            decoration: BoxDecoration(
              color: colors.surfaceCard,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: red.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                    border: Border.all(color: red.withValues(alpha: 0.4)),
                  ),
                  child: Icon(
                    timedOut ? Icons.timer_off_rounded : Icons.close_rounded,
                    color: red,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  timedOut ? 'Time\'s up!' : 'Wrong answer!',
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (answer case final a?) ...[
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'THE ANSWER WAS',
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ),
                  SpeedRoundAnswerCard(sound: a, onPlay: onPlayAnswer),
                  if (picked case final p? when p.id != a.id) ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'You picked ',
                          style: TextStyle(color: colors.textSecondary, fontSize: 13),
                        ),
                        Text(p.emoji, style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    'You ran out of time.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.textSecondary, fontSize: 14),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _StatChip(
                        label: 'Score',
                        value: '$score',
                        unit: 'pts',
                        accent: accent,
                        colors: colors,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _StatChip(
                        label: 'Correct',
                        value: '$questionsAnswered',
                        accent: accent,
                        colors: colors,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (isNewBest)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: gold.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: gold.withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.emoji_events_rounded, size: 16, color: gold),
                        const SizedBox(width: 6),
                        Text(
                          'New personal best!',
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (bestScore != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.emoji_events_outlined, size: 16, color: gold),
                      const SizedBox(width: 6),
                      Text(
                        'Personal best ',
                        style: TextStyle(
                          color: colors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '$bestScore',
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          fontFeatures: _tabular,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: onPlayAgain,
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text(
                      'Try Again',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                if (score > 0) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: onShare,
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: const Text(
                        'Share score',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.textPrimary,
                        side: BorderSide(color: colors.border),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color accent;
  final AppColors colors;

  const _StatChip({
    required this.label,
    required this.value,
    this.unit,
    required this.accent,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: colors.scaffoldBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: colors.borderSubtle),
      ),
      child: Column(
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: TextStyle(
                    color: colors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    fontFeatures: _tabular,
                  ),
                ),
                if (unit != null)
                  TextSpan(
                    text: ' $unit',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(color: colors.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
