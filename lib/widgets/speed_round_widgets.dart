import 'dart:math';

import 'package:flutter/material.dart';

import '../models/sound_model.dart';
import '../theme/app_colors.dart';

const _tabular = [FontFeature.tabularFigures()];

/// Category dot colour for a sound — the same palette the soundboard's
/// SoundButton uses, so a sound reads as "the same thing" across screens.
Color speedRoundSoundColor(BuildContext context, SoundModel sound) {
  if (sound.customColor != null) return Color(sound.customColor!);
  return switch (sound.category) {
    'Instruments' => const Color(0xFFFAC775),
    'Memes' => const Color(0xFFFF7272),
    'Reactions' => const Color(0xFF64C8FF),
    'Effects' => const Color(0xFF5DCAA5),
    'UI' => const Color(0xFF9F8FF0),
    'Music' => const Color(0xFFFF9FF0),
    'Animals' => const Color(0xFF7DDB86),
    'Gaming' => const Color(0xFF7B73FF),
    'Anime' => const Color(0xFFFF9F7F),
    'Cartoons' => const Color(0xFFFFD166),
    'My Clips' => Theme.of(context).colorScheme.primary,
    _ => const Color(0xFF888780),
  };
}

bool _isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// Trophy gold, a touch deeper in light mode so it holds up on white.
Color speedRoundGold(BuildContext context) =>
    _isDark(context) ? const Color(0xFFFFC857) : const Color(0xFFE0A100);

Color _streakText(BuildContext context) =>
    _isDark(context) ? const Color(0xFFFFCF99) : const Color(0xFFA85A12);

const _streakTint = Color(0xFFFFB86B);

Color speedRoundCorrect(BuildContext context) =>
    _isDark(context) ? const Color(0xFF5DD39E) : const Color(0xFF1E9E63);

Color speedRoundWrong(BuildContext context) =>
    _isDark(context) ? const Color(0xFFFF7A85) : const Color(0xFFD9364A);

/// 44×44 rounded-square icon button used in the game header.
class SpeedRoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const SpeedRoundIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: c.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 20, color: c.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// "31 pts" score pill on the right of the header.
class SpeedRoundScorePill extends StatelessWidget {
  final int score;
  const SpeedRoundScorePill({super.key, required this.score});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.border),
      ),
      alignment: Alignment.center,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$score',
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFeatures: _tabular,
              ),
            ),
            TextSpan(
              text: ' pts',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Orange "7 in a row · 2× points" pill.
class SpeedRoundStreakPill extends StatelessWidget {
  final int streak;
  final double multiplier;

  /// Overrides the generated "N in a row · M× points" text.
  final String? label;

  const SpeedRoundStreakPill({
    super.key,
    required this.streak,
    required this.multiplier,
    this.label,
  });

  static String formatMultiplier(double m) =>
      m == m.roundToDouble() ? '${m.round()}×' : '$m×';

  @override
  Widget build(BuildContext context) {
    final dark = _isDark(context);
    final fg = _streakText(context);
    final text =
        label ??
        (multiplier > 1
            ? '$streak in a row · ${formatMultiplier(multiplier)} points'
            : '$streak in a row · 1.5× at 3');
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: _streakTint.withValues(alpha: dark ? 0.14 : 0.18),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(
          color: _streakTint.withValues(alpha: dark ? 0.45 : 0.7),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.local_fire_department_rounded, size: 16, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: _tabular,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small green "+12 pts" chip flashed after a correct answer.
class SpeedRoundGainChip extends StatelessWidget {
  final int gained;
  const SpeedRoundGainChip({super.key, required this.gained});

  @override
  Widget build(BuildContext context) {
    final green = speedRoundCorrect(context);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: green.withValues(alpha: 0.5)),
      ),
      alignment: Alignment.center,
      child: Text(
        '+$gained pts',
        style: TextStyle(
          color: green,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          fontFeatures: _tabular,
        ),
      ),
    );
  }
}

/// The countdown ring with the replay button inside it.
class SpeedRoundRing extends StatelessWidget {
  final double size;

  /// Fraction of the question's time still left, 0..1.
  final Animation<double> remaining;
  final double secondsLeft;
  final List<double> levels;
  final bool enabled;
  final VoidCallback onReplay;

  const SpeedRoundRing({
    super.key,
    required this.size,
    required this.remaining,
    required this.secondsLeft,
    required this.levels,
    required this.enabled,
    required this.onReplay,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final warn = _isDark(context) ? _streakTint : const Color(0xFFE07B12);
    // Proportions from the 250px design: 12px stroke, 26px inset.
    final scale = size / 250;
    final stroke = 12 * scale;
    final inset = 26 * scale;
    final low = secondsLeft <= 1.5;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: remaining,
                builder: (_, _) => CustomPaint(
                  painter: _RingPainter(
                    value: remaining.value.clamp(0.0, 1.0),
                    track: c.surfaceElevated,
                    arc: low ? warn : accent,
                    stroke: stroke,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            left: inset,
            top: inset,
            right: inset,
            bottom: inset,
            child: Semantics(
              button: true,
              label: 'Replay the sound',
              child: Material(
                color: c.surfaceCard,
                shape: CircleBorder(side: BorderSide(color: c.borderSubtle)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: enabled ? onReplay : null,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            secondsLeft.clamp(0, 99).toStringAsFixed(1),
                            style: TextStyle(
                              color: low ? warn : c.textPrimary,
                              fontSize: 40,
                              height: 1.1,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -1,
                              fontFeatures: _tabular,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _MiniWave(levels: levels, color: accent),
                          const SizedBox(height: 12),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.replay_rounded,
                                size: 15,
                                color: enabled ? c.textSecondary : c.textMuted,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'Tap to replay',
                                style: TextStyle(
                                  color: enabled
                                      ? c.textSecondary
                                      : c.textMuted,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color track;
  final Color arc;
  final double stroke;

  _RingPainter({
    required this.value,
    required this.track,
    required this.arc,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = (min(size.width, size.height) - stroke) / 2;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, r, p..color = track);
    if (value <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r),
      -pi / 2,
      2 * pi * value,
      false,
      p..color = arc,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value ||
      old.track != track ||
      old.arc != arc ||
      old.stroke != stroke;
}

/// 16 short rounded bars — a thumbnail of the sound being played.
class _MiniWave extends StatelessWidget {
  final List<double> levels;
  final Color color;
  const _MiniWave({required this.levels, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < levels.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Container(
              width: 3,
              height: 5 + 25 * levels[i].clamp(0.0, 1.0),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One of the four answer buttons.
class SpeedRoundOption extends StatelessWidget {
  final SoundModel sound;
  final bool isTarget;
  final bool isChosen;
  final bool answered;
  final VoidCallback onTap;

  const SpeedRoundOption({
    super.key,
    required this.sound,
    required this.isTarget,
    required this.isChosen,
    required this.answered,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final green = speedRoundCorrect(context);
    final red = speedRoundWrong(context);

    var border = c.border;
    var bg = c.surfaceCard;
    var width = 1.0;
    IconData? mark;
    Color? markColor;
    var dim = false;

    if (answered) {
      if (isTarget) {
        border = green;
        bg = Color.alphaBlend(green.withValues(alpha: 0.14), c.surfaceCard);
        width = 2;
        mark = Icons.check_circle_rounded;
        markColor = green;
      } else if (isChosen) {
        border = red;
        bg = Color.alphaBlend(red.withValues(alpha: 0.14), c.surfaceCard);
        width = 2;
        mark = Icons.cancel_rounded;
        markColor = red;
      } else {
        dim = true;
      }
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: dim ? 0.5 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 76,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: border, width: width),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: answered ? null : onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 15 - width),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: speedRoundSoundColor(context, sound),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      sound.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (mark != null) ...[
                    const SizedBox(width: 6),
                    Icon(mark, size: 20, color: markColor),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
