import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/sound_model.dart';
import '../theme/app_colors.dart';

enum _GamePhase { readyUp, playing }

class SpeedRoundScreen extends StatefulWidget {
  final List<SoundModel> sounds;
  final Map<String, AudioSource> preloaded;

  const SpeedRoundScreen({
    super.key,
    required this.sounds,
    required this.preloaded,
  });

  @override
  State<SpeedRoundScreen> createState() => _SpeedRoundScreenState();
}

class _SpeedRoundScreenState extends State<SpeedRoundScreen>
    with SingleTickerProviderStateMixin {
  static const _roundDuration = 5.0;
  static const _minSounds = 8;

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

  // Timer
  double _timeLeft = _roundDuration;
  Timer? _countdownTimer;
  late final AnimationController _timerController;
  SoundHandle? _currentHandle;

  @override
  void initState() {
    super.initState();
    _loadedSounds = widget.sounds
        .where((s) => widget.preloaded[s.id] != null)
        .toList();

    _timerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
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
    });
    _nextQuestion();
  }

  void _nextQuestion() {
    _stopCurrentSound();
    _countdownTimer?.cancel();

    final shuffled = List<SoundModel>.from(_loadedSounds)..shuffle(_rng);
    _target = shuffled[0];
    final wrongs = shuffled.sublist(1, 4);
    final opts = [...wrongs, _target!]..shuffle(_rng);

    setState(() {
      _options = opts;
      _answered = false;
      _chosen = null;
      _showScoreGained = false;
      _timeLeft = _roundDuration;
    });

    _timerController
      ..reset()
      ..forward();

    Future.microtask(_playTarget);

    _countdownTimer = Timer.periodic(const Duration(milliseconds: 100), (t) {
      if (!mounted) { t.cancel(); return; }
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
      return;
    }

    _streak++;
    final multiplier = _streak >= 7 ? 2.0 : _streak >= 3 ? 1.5 : 1.0;
    final gained = (max(1, (_timeLeft / _roundDuration * 10).round()) * multiplier);

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

  double get _multiplier => _streak >= 7 ? 2.0 : _streak >= 3 ? 1.5 : 1.0;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    if (_loadedSounds.length < _minSounds) return _buildErrorState(c);

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.surfaceCard,
        foregroundColor: c.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            Icon(Icons.bolt_rounded, color: accent, size: 22),
            const SizedBox(width: 8),
            Text(
              'Speed Round',
              style: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ],
        ),
        actions: [
          if (_gamePhase == _GamePhase.playing)
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$_score pts',
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
        ],
      ),
      body: _gamePhase == _GamePhase.readyUp
          ? _buildReadyUp(c, accent)
          : Stack(
              children: [
                _buildGame(c, accent),
                if (_gameOver)
                  _GameOverOverlay(
                    score: _score,
                    questionsAnswered: _questionsAnswered,
                    accent: accent,
                    colors: c,
                    onPlayAgain: () => setState(() {
                      _gamePhase = _GamePhase.readyUp;
                    }),
                  ),
              ],
            ),
    );
  }

  Widget _buildReadyUp(AppColors c, Color accent) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(color: accent.withValues(alpha: 0.35), width: 2),
              ),
              child: const Center(
                child: Text('👂', style: TextStyle(fontSize: 42)),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Speed Round',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'A sound plays — pick the right name from 4 options before time runs out. Answer faster for more points.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '🔥 Build a streak for a score multiplier',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textMuted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton(
                onPressed: _startGame,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  "Let's go →",
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGame(AppColors c, Color accent) {
    if (_target == null) return const SizedBox.shrink();
    return Column(
      children: [
        LinearProgressIndicator(
          value: _timeLeft / _roundDuration,
          minHeight: 4,
          backgroundColor: c.border,
          valueColor: AlwaysStoppedAnimation(
            _timeLeft > 2.5 ? accent : Colors.orange,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                const SizedBox(height: 36),
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: c.surfaceCard,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: c.border),
                  ),
                  child: Column(
                    children: [
                      const Text('👂', style: TextStyle(fontSize: 48)),
                      const SizedBox(height: 8),
                      Text(
                        'Listen carefully',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: _answered ? null : _playTarget,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.replay_rounded,
                            color: _answered ? c.textMuted : accent,
                            size: 22,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _showScoreGained
                      ? Container(
                          key: const ValueKey('score'),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.green.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '+${_scoreGained.round()} pts',
                            style: const TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        )
                      : Container(
                          key: const ValueKey('streak'),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: _streak > 0
                                ? accent.withValues(alpha: 0.12)
                                : c.surfaceCard,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: _streak > 0 ? accent : c.border),
                          ),
                          child: Text(
                            _streak == 0
                                ? 'No streak'
                                : '🔥 $_streak streak · $_multiplier×',
                            style: TextStyle(
                              color: _streak > 0 ? accent : c.textMuted,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 20),
                GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 1.3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: _options
                      .map((opt) => _OptionCard(
                            sound: opt,
                            isTarget: opt.id == _target!.id,
                            isChosen: _chosen?.id == opt.id,
                            answered: _answered,
                            accent: accent,
                            colors: c,
                            onTap: () => _onOptionTap(opt),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorState(AppColors c) {
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.surfaceCard,
        foregroundColor: c.textPrimary,
        title: const Text('Speed Round'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded, size: 56, color: c.textMuted),
              const SizedBox(height: 16),
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
                'Speed Round needs at least $_minSounds loaded sounds.\n'
                'Only ${_loadedSounds.length} are available.',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.textSecondary, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GameOverOverlay extends StatelessWidget {
  final int score;
  final int questionsAnswered;
  final Color accent;
  final AppColors colors;
  final VoidCallback onPlayAgain;

  const _GameOverOverlay({
    required this.score,
    required this.questionsAnswered,
    required this.accent,
    required this.colors,
    required this.onPlayAgain,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.65),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: colors.surfaceCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.4), width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('⏰', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text(
                'Time\'s up!',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'You ran out of time.',
                style: TextStyle(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _StatChip(label: 'Score', value: '$score pts', accent: accent, colors: colors),
                  _StatChip(label: 'Correct', value: '$questionsAnswered', accent: accent, colors: colors),
                ],
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onPlayAgain,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    'Try Again',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final AppColors colors;

  const _StatChip({
    required this.label,
    required this.value,
    required this.accent,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: accent,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: colors.textSecondary, fontSize: 13)),
      ],
    );
  }
}

class _OptionCard extends StatelessWidget {
  final SoundModel sound;
  final bool isTarget;
  final bool isChosen;
  final bool answered;
  final Color accent;
  final AppColors colors;
  final VoidCallback onTap;

  const _OptionCard({
    required this.sound,
    required this.isTarget,
    required this.isChosen,
    required this.answered,
    required this.accent,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    Color borderColor = colors.border;
    Color bgColor = colors.surfaceCard;

    if (answered) {
      if (isTarget) {
        borderColor = Colors.green;
        bgColor = Colors.green.withValues(alpha: 0.10);
      } else if (isChosen && !isTarget) {
        borderColor = Colors.red;
        bgColor = Colors.red.withValues(alpha: 0.10);
      }
    }

    return GestureDetector(
      onTap: answered ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: borderColor,
              width: answered && (isTarget || isChosen) ? 2 : 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(sound.emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                sound.name,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
