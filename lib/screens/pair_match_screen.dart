import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/sound_model.dart';
import '../theme/app_colors.dart';

enum _CardState { faceDown, faceUp, matched }

enum _Difficulty { easy, medium, hard }

class _Card {
  final SoundModel sound;
  final int index;
  _CardState state;
  _Card({required this.sound, required this.index}) : state = _CardState.faceDown;
}

class PairMatchScreen extends StatefulWidget {
  final List<SoundModel> sounds;
  final Map<String, AudioSource> preloaded;

  const PairMatchScreen({
    super.key,
    required this.sounds,
    required this.preloaded,
  });

  @override
  State<PairMatchScreen> createState() => _PairMatchScreenState();
}

class _PairMatchScreenState extends State<PairMatchScreen> {
  late final List<SoundModel> _loadedSounds;
  final _rng = Random();

  _Difficulty? _difficulty; // null = on difficulty picker screen

  List<_Card> _grid = [];
  int _moves = 0;
  int _matchedPairs = 0;
  bool _locked = false;
  _Card? _firstFlipped;

  bool _timerStarted = false;
  int _elapsedSeconds = 0;
  Timer? _timer;
  bool _won = false;

  // Difficulty config: (pairs, columns)
  static const _config = {
    _Difficulty.easy:   (pairs: 4,  columns: 4),
    _Difficulty.medium: (pairs: 6,  columns: 4),
    _Difficulty.hard:   (pairs: 10, columns: 5),
  };

  int get _pairCount => _config[_difficulty!]!.pairs;
  int get _columns => _config[_difficulty!]!.columns;

  @override
  void initState() {
    super.initState();
    _loadedSounds = widget.sounds
        .where((s) => widget.preloaded[s.id] != null)
        .toList();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _selectDifficulty(_Difficulty d) {
    setState(() => _difficulty = d);
    _setupGrid();
  }

  void _setupGrid() {
    final available = List<SoundModel>.from(_loadedSounds)..shuffle(_rng);
    final chosen = available.take(_pairCount).toList();
    final doubled = [...chosen, ...chosen]..shuffle(_rng);

    _grid = List.generate(doubled.length, (i) => _Card(sound: doubled[i], index: i));
    _moves = 0;
    _matchedPairs = 0;
    _firstFlipped = null;
    _locked = false;
    _timerStarted = false;
    _elapsedSeconds = 0;
    _won = false;
    _timer?.cancel();
  }

  void _startTimer() {
    _timerStarted = true;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsedSeconds++);
    });
  }

  Future<void> _playSound(SoundModel sound) async {
    final source = widget.preloaded[sound.id];
    if (source == null) return;
    try {
      await SoLoud.instance.play(source);
    } catch (_) {}
  }

  Future<void> _playSoundById(String id) async {
    final source = widget.preloaded[id];
    if (source == null) return;
    try {
      await SoLoud.instance.play(source);
    } catch (_) {}
  }

  void _onCardTap(_Card card) {
    if (_locked) return;
    if (card.state != _CardState.faceDown) return;

    if (!_timerStarted) _startTimer();

    setState(() => card.state = _CardState.faceUp);
    _playSound(card.sound);

    if (_firstFlipped == null) {
      _firstFlipped = card;
      return;
    }

    final first = _firstFlipped!;
    _firstFlipped = null;
    _moves++;

    if (first.sound.id == card.sound.id) {
      setState(() {
        first.state = _CardState.matched;
        card.state = _CardState.matched;
        _matchedPairs++;
      });
      if (_matchedPairs == _pairCount) {
        _timer?.cancel();
        _playSoundById('s90');
        Future.delayed(const Duration(milliseconds: 400), () {
          if (mounted) setState(() => _won = true);
        });
      }
    } else {
      _locked = true;
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        setState(() {
          first.state = _CardState.faceDown;
          card.state = _CardState.faceDown;
          _locked = false;
        });
      });
    }
  }

  void _playAgain() {
    setState(() {
      _setupGrid();
      _won = false;
    });
  }

  void _changeDifficulty() {
    _timer?.cancel();
    setState(() => _difficulty = null);
  }

  String _formatTime(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        backgroundColor: c.surfaceCard,
        foregroundColor: c.textPrimary,
        elevation: 0,
        title: Row(
          children: [
            Icon(Icons.grid_on_rounded, color: accent, size: 22),
            const SizedBox(width: 8),
            Text(
              'Pair Match',
              style: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
          ],
        ),
        actions: [
          if (_difficulty != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Row(
                children: [
                  Icon(Icons.touch_app_rounded, color: c.textSecondary, size: 18),
                  const SizedBox(width: 4),
                  Text(
                    '$_moves',
                    style: TextStyle(
                      color: c.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.tune_rounded, color: c.textSecondary, size: 20),
              tooltip: 'Change difficulty',
              onPressed: _changeDifficulty,
            ),
          ],
        ],
      ),
      body: _difficulty == null
          ? _buildDifficultyPicker(c, accent)
          : Stack(
              children: [
                Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        _formatTime(_elapsedSeconds),
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: GridView.builder(
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _grid.length,
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: _columns,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 0.85,
                          ),
                          itemBuilder: (context, i) {
                            final card = _grid[i];
                            return GestureDetector(
                              onTap: () => _onCardTap(card),
                              child: _MatchCard(card: card, accent: accent, colors: c),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
                if (_won)
                  _WinOverlay(
                    moves: _moves,
                    elapsedSeconds: _elapsedSeconds,
                    difficulty: _difficulty!,
                    accent: accent,
                    colors: c,
                    onPlayAgain: _playAgain,
                    onChangeDifficulty: _changeDifficulty,
                  ),
              ],
            ),
    );
  }

  Widget _buildDifficultyPicker(AppColors c, Color accent) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
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
                child: Text('🃏', style: TextStyle(fontSize: 42)),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Pair Match',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Flip cards to reveal sounds. Find all matching pairs by ear.',
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textSecondary, fontSize: 14, height: 1.5),
            ),
            const SizedBox(height: 36),
            ..._Difficulty.values.map((d) => _DifficultyTile(
                  difficulty: d,
                  accent: accent,
                  colors: c,
                  onTap: () => _selectDifficulty(d),
                )),
          ],
        ),
      ),
    );
  }
}

class _DifficultyTile extends StatelessWidget {
  final _Difficulty difficulty;
  final Color accent;
  final AppColors colors;
  final VoidCallback onTap;

  const _DifficultyTile({
    required this.difficulty,
    required this.accent,
    required this.colors,
    required this.onTap,
  });

  static const _meta = {
    _Difficulty.easy:   (label: 'Easy',   emoji: '🟢', sub: '4 pairs · 4 columns'),
    _Difficulty.medium: (label: 'Medium', emoji: '🟡', sub: '6 pairs · 4 columns'),
    _Difficulty.hard:   (label: 'Hard',   emoji: '🔴', sub: '10 pairs · 5 columns'),
  };

  @override
  Widget build(BuildContext context) {
    final m = _meta[difficulty]!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration(
            color: colors.surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              Text(m.emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.label,
                      style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      m.sub,
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textMuted, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _MatchCard extends StatelessWidget {
  final _Card card;
  final Color accent;
  final AppColors colors;

  const _MatchCard({required this.card, required this.accent, required this.colors});

  @override
  Widget build(BuildContext context) {
    final isFaceDown = card.state == _CardState.faceDown;
    final isMatched = card.state == _CardState.matched;

    Color bgColor = isFaceDown ? colors.surfaceCard : colors.surfaceElevated;
    Color borderColor = isFaceDown ? colors.border : colors.borderSubtle;
    double borderWidth = 1;

    if (isMatched) {
      bgColor = accent.withValues(alpha: 0.08);
      borderColor = accent;
      borderWidth = 2;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: isFaceDown
          ? Center(
              child: Text(
                '?',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(card.sound.emoji, style: const TextStyle(fontSize: 20)),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    card.sound.name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isMatched ? accent : colors.textPrimary,
                      fontSize: 8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _WinOverlay extends StatelessWidget {
  final int moves;
  final int elapsedSeconds;
  final _Difficulty difficulty;
  final Color accent;
  final AppColors colors;
  final VoidCallback onPlayAgain;
  final VoidCallback onChangeDifficulty;

  const _WinOverlay({
    required this.moves,
    required this.elapsedSeconds,
    required this.difficulty,
    required this.accent,
    required this.colors,
    required this.onPlayAgain,
    required this.onChangeDifficulty,
  });

  String _formatTime(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.6),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 32),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: colors.surfaceCard,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: accent.withValues(alpha: 0.4), width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🎉', style: TextStyle(fontSize: 48)),
              const SizedBox(height: 12),
              Text(
                'You matched them all!',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Stat(label: 'Time', value: _formatTime(elapsedSeconds), accent: accent, colors: colors),
                  _Stat(label: 'Moves', value: '$moves', accent: accent, colors: colors),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onPlayAgain,
                  style: FilledButton.styleFrom(
                    backgroundColor: accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: const Text(
                    'Play Again',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: onChangeDifficulty,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: Text(
                    'Change Difficulty',
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
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

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  final AppColors colors;

  const _Stat({required this.label, required this.value, required this.accent, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: TextStyle(color: accent, fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(color: colors.textSecondary, fontSize: 13)),
      ],
    );
  }
}
