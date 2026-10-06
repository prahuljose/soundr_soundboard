import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_colors.dart';
import 'waveform_bars.dart';

/// Reverse Challenge colours, tuned for contrast in light and dark mode.
class ReversePalette {
  /// Fills and graphics (record button, waveforms, step dots).
  final Color tint;

  /// Tint for text and icons on cards (≥ 4.5:1).
  final Color tintText;

  /// Text and icons on a [tint] fill.
  final Color onTint;

  /// Recording in progress.
  final Color rec;

  final Color star;
  final bool dark;

  const ReversePalette._(
    this.tint,
    this.tintText,
    this.onTint,
    this.rec,
    this.star,
    this.dark,
  );

  static ReversePalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const ReversePalette._(
            Color(0xFF8FA8FF),
            Color(0xFF8FA8FF),
            Color(0xFF0F1736),
            Color(0xFFF25454),
            Color(0xFFFFC94D),
            true,
          )
        : const ReversePalette._(
            Color(0xFF4F69D9),
            Color(0xFF3B54C4),
            Colors.white,
            Color(0xFFD63C3C),
            Color(0xFFC07F00),
            false,
          );
  }

  /// A soft wash of the tint for card backgrounds.
  Color get wash => tint.withValues(alpha: dark ? 0.13 : 0.09);
}

String? _font(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium?.fontFamily;

// ── Step header ─────────────────────────────────────────────────────────────

/// 1 Record · 2 Copy it backwards · 3 Reveal, with the current step
/// highlighted and finished ones ticked.
class ReverseStepHeader extends StatelessWidget {
  /// 0, 1 or 2.
  final int step;

  const ReverseStepHeader({super.key, required this.step});

  static const labels = ['Record', 'Copy it backwards', 'Reveal'];

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    const dur = Duration(milliseconds: 300);

    Widget line(bool on, {bool hidden = false}) => Expanded(
      child: AnimatedContainer(
        duration: dur,
        height: 2,
        color: hidden ? Colors.transparent : (on ? p.tint : c.border),
      ),
    );

    return Semantics(
      label: 'Step ${step + 1} of 3: ${labels[step]}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 3; i++)
              Expanded(
                child: Column(
                  children: [
                    Row(
                      children: [
                        line(step >= i, hidden: i == 0),
                        _StepDot(index: i, state: (i - step).sign),
                        line(step > i, hidden: i == 2),
                      ],
                    ),
                    const SizedBox(height: 6),
                    AnimatedDefaultTextStyle(
                      duration: dur,
                      style: TextStyle(
                        fontFamily: _font(context),
                        color: i == step
                            ? c.textPrimary
                            : (i < step ? p.tintText : c.textSecondary),
                        fontSize: 12.5,
                        fontWeight: i == step
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      child: Text(
                        labels[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  final int index;

  /// -1 done, 0 current, 1 to come.
  final int state;

  const _StepDot({required this.index, required this.state});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    final filled = state <= 0;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: 28,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? p.tint : c.surfaceCard,
        border: Border.all(color: filled ? p.tint : c.border, width: 1.5),
        boxShadow: state == 0
            ? [
                BoxShadow(
                  color: p.tint.withValues(alpha: p.dark ? 0.35 : 0.3),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ]
            : const [],
      ),
      alignment: Alignment.center,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, a) =>
            ScaleTransition(scale: a, child: child),
        child: state < 0
            ? Icon(
                Icons.check_rounded,
                key: const ValueKey('done'),
                size: 17,
                color: p.onTint,
              )
            : Text(
                '${index + 1}',
                key: ValueKey('n$state'),
                style: TextStyle(
                  fontFamily: _font(context),
                  color: filled ? p.onTint : c.textSecondary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
      ),
    );
  }
}

// ── Phrase suggestion ───────────────────────────────────────────────────────

/// "Try saying" card with a shuffle button.
class ReversePhraseCard extends StatelessWidget {
  final String phrase;
  final VoidCallback? onShuffle;

  const ReversePhraseCard({super.key, required this.phrase, this.onShuffle});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    return Material(
      color: p.wash,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.tint.withValues(alpha: p.dark ? 0.3 : 0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onShuffle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 8, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TRY SAYING',
                      style: TextStyle(
                        color: p.tintText,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      transitionBuilder: (child, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 0.25),
                            end: Offset.zero,
                          ).animate(a),
                          child: child,
                        ),
                      ),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...previous, ?current],
                      ),
                      child: Text(
                        '“$phrase”',
                        key: ValueKey(phrase),
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Another phrase',
                onPressed: onShuffle,
                icon: Icon(Icons.shuffle_rounded, color: p.tintText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Recording ───────────────────────────────────────────────────────────────

/// Big round record button. While recording it turns into a stop button,
/// a halo breathes with the mic [level] and an arc fills up to the
/// automatic stop.
class ReverseRecordButton extends StatefulWidget {
  final bool recording;
  final ValueListenable<double> level;

  /// 0..1 of the maximum length, while recording.
  final double progress;
  final VoidCallback? onTap;
  final String idleLabel;
  final double size;

  const ReverseRecordButton({
    super.key,
    required this.recording,
    required this.level,
    required this.progress,
    required this.onTap,
    required this.idleLabel,
    this.size = 108,
  });

  @override
  State<ReverseRecordButton> createState() => _ReverseRecordButtonState();
}

class _ReverseRecordButtonState extends State<ReverseRecordButton>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  double _level = 0; // smoothed
  double _on = 0; // 0 idle → 1 recording
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    widget.level.addListener(_kick);
    _on = widget.recording ? 1 : 0;
  }

  @override
  void didUpdateWidget(ReverseRecordButton old) {
    super.didUpdateWidget(old);
    if (old.level != widget.level) {
      old.level.removeListener(_kick);
      widget.level.addListener(_kick);
    }
    _kick();
  }

  void _kick() {
    if (!mounted) return;
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration now) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : (now - _last).inMicroseconds / 1e6;
    _last = now;
    double ease(double from, double to, double speed) =>
        from + (to - from) * (1 - exp(-dt * speed));
    final rec = widget.recording;
    final lt = rec ? widget.level.value : 0.0;
    // Fast attack, slower release, like a VU meter.
    final l = ease(_level, lt, lt > _level ? 22 : 7);
    final o = ease(_on, rec ? 1 : 0, 10);
    final pt = rec ? widget.progress : 0.0;
    final pr = pt < _progress ? pt : ease(_progress, pt, 14);
    final settled =
        !rec && l < 0.005 && (o - 0).abs() < 0.005 && pr < 0.005;
    setState(() {
      _level = settled ? 0 : l;
      _on = settled ? 0 : o;
      _progress = settled ? 0 : pr;
    });
    if (settled) _ticker.stop();
  }

  @override
  void dispose() {
    widget.level.removeListener(_kick);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    final s = widget.size;
    final outer = s + 56;
    final fill = Color.lerp(p.tint, p.rec, _on)!;
    return Semantics(
      button: true,
      label: widget.recording ? 'Stop recording' : widget.idleLabel,
      excludeSemantics: true,
      child: SizedBox(
        width: outer,
        height: outer,
        child: CustomPaint(
          painter: _RecordHaloPainter(
            level: _level,
            on: _on,
            progress: _progress,
            radius: s / 2,
            halo: fill,
            track: c.border,
            arc: p.rec,
            dark: p.dark,
          ),
          child: Center(
            child: AnimatedScale(
              scale: widget.onTap == null ? 0.94 : 1,
              duration: const Duration(milliseconds: 200),
              child: Material(
                color: widget.onTap == null
                    ? fill.withValues(alpha: 0.45)
                    : fill,
                shape: const CircleBorder(),
                elevation: 0,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onTap,
                  child: SizedBox(
                    width: s,
                    height: s,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, a) =>
                          ScaleTransition(scale: a, child: child),
                      child: widget.recording
                          ? Icon(
                              Icons.stop_rounded,
                              key: const ValueKey('stop'),
                              size: s * 0.42,
                              color: Colors.white,
                            )
                          : Icon(
                              Icons.mic_rounded,
                              key: const ValueKey('mic'),
                              size: s * 0.4,
                              color: p.onTint,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordHaloPainter extends CustomPainter {
  final double level, on, progress, radius;
  final Color halo, track, arc;
  final bool dark;

  _RecordHaloPainter({
    required this.level,
    required this.on,
    required this.progress,
    required this.radius,
    required this.halo,
    required this.track,
    required this.arc,
    required this.dark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    // Soft halo, always faintly there so the button reads as the thing to
    // tap; it swells with the voice while recording.
    final grow = 4 + on * (6 + 18 * level);
    canvas.drawCircle(
      centre,
      radius + grow,
      Paint()..color = halo.withValues(alpha: (dark ? 0.16 : 0.13) + 0.1 * on * level),
    );
    if (on > 0.01) {
      final r = radius + 10;
      final rect = Rect.fromCircle(center: centre, radius: r);
      canvas.drawCircle(
        centre,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = track.withValues(alpha: track.a * on),
      );
      if (progress > 0) {
        canvas.drawArc(
          rect,
          -pi / 2,
          2 * pi * progress.clamp(0.0, 1.0),
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round
            ..color = arc.withValues(alpha: on),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RecordHaloPainter o) =>
      o.level != level ||
      o.on != on ||
      o.progress != progress ||
      o.halo != halo ||
      o.track != track ||
      o.arc != arc;
}

/// A row of bars that fills left to right as you record, one bar per
/// slice of the maximum length, so you can see how long you've got left.
class ReverseLevelStrip extends StatelessWidget {
  final List<double> levels; // one per slot, 0..1
  final int filled; // slots recorded so far
  final bool recording;
  final double height;

  const ReverseLevelStrip({
    super.key,
    required this.levels,
    required this.filled,
    required this.recording,
    this.height = 40,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    return ExcludeSemantics(
      child: WaveformBars(
        levels: levels,
        progress: levels.isEmpty ? 0 : filled / levels.length,
        activeColor: recording ? p.rec : p.tint,
        idleColor: c.border,
        height: height,
      ),
    );
  }
}

// ── Clips ───────────────────────────────────────────────────────────────────

/// A playable clip: play/stop button, waveform with a playhead, label and
/// length. [big] is the hero version used in step 2.
class ReverseClipTile extends StatelessWidget {
  final String label;
  final String? caption;
  final IconData icon;
  final List<double> levels;
  final Duration duration;

  /// Playhead 0..1 while this clip plays, else null.
  final double? progress;
  final VoidCallback? onTap;
  final bool big;
  final bool highlight;

  const ReverseClipTile({
    super.key,
    required this.label,
    required this.levels,
    required this.duration,
    required this.progress,
    required this.onTap,
    this.caption,
    this.icon = Icons.play_arrow_rounded,
    this.big = false,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    final playing = progress != null;
    final secs = duration.inMilliseconds / 1000;
    final btn = big ? 60.0 : 44.0;
    final active = playing || highlight;
    return Semantics(
      button: true,
      label: '${playing ? 'Stop' : 'Play'} $label',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        decoration: BoxDecoration(
          color: active ? p.wash : c.surfaceCard,
          borderRadius: BorderRadius.circular(big ? 22 : 18),
          border: Border.all(
            color: active
                ? p.tint.withValues(alpha: p.dark ? 0.45 : 0.5)
                : c.borderSubtle,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(big ? 22 : 18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                big ? 14 : 10,
                big ? 14 : 9,
                big ? 16 : 14,
                big ? 14 : 9,
              ),
              child: Row(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: btn,
                    height: btn,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: playing || big ? p.tint : p.wash,
                    ),
                    child: Icon(
                      playing ? Icons.stop_rounded : icon,
                      size: btn * 0.52,
                      color: playing || big ? p.onTint : p.tintText,
                    ),
                  ),
                  SizedBox(width: big ? 14 : 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: big ? 16 : 14.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${secs.toStringAsFixed(1)} s',
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 12.5,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (caption != null)
                          Text(
                            caption!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 12.5,
                            ),
                          ),
                        SizedBox(height: big ? 8 : 5),
                        WaveformBars(
                          levels: levels,
                          progress: progress ?? 0,
                          activeColor: p.tint,
                          idleColor: active
                              ? p.tint.withValues(alpha: 0.35)
                              : c.textSecondary.withValues(alpha: 0.45),
                          height: big ? 48 : 26,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Score ───────────────────────────────────────────────────────────────────

/// The big reveal: stars, a count-up score and a verdict.
class ReverseScoreCard extends StatelessWidget {
  final int score;
  final int stars;
  final String message;
  final int? best;
  final bool newBest;
  final bool compact;

  const ReverseScoreCard({
    super.key,
    required this.score,
    required this.stars,
    required this.message,
    required this.best,
    required this.newBest,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    return Semantics(
      label:
          'Match score $score out of 100, $stars ${stars == 1 ? 'star' : 'stars'}. $message'
          '${newBest ? ' New personal best.' : (best != null ? ' Best $best.' : '')}',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(16, compact ? 14 : 18, 16, compact ? 14 : 18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: p.tint.withValues(alpha: p.dark ? 0.3 : 0.35)),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              p.tint.withValues(alpha: p.dark ? 0.2 : 0.14),
              p.tint.withValues(alpha: p.dark ? 0.06 : 0.04),
            ],
          ),
        ),
        child: TweenAnimationBuilder<double>(
          // Restart the reveal for every new score.
          key: ValueKey(Object.hash(score, message, newBest)),
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 1400),
          builder: (context, t, _) {
            final count = Curves.easeOutCubic.transform((t / 0.65).clamp(0.0, 1.0));
            final starRow = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++)
                  _Star(
                    on: i < stars,
                    // Each star pops in turn as the count passes it.
                    t: ((t - 0.25 - i * 0.15) / 0.3).clamp(0.0, 1.0),
                    color: p.star,
                    off: c.border,
                    size: compact ? 26 : 36,
                    lift: i == 1 && !compact ? 6 : 0,
                  ),
              ],
            );
            final number = Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${(score * count).round()}',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: compact ? 50 : 68,
                    fontWeight: FontWeight.w800,
                    height: 1.05,
                    letterSpacing: -2,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '/ 100',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: compact ? 14 : 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            );
            final verdict = Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.tintText,
                fontSize: compact ? 19 : 20,
                fontWeight: FontWeight.w800,
              ),
            );
            final fade = ((t - 0.45) / 0.3).clamp(0.0, 1.0);
            if (compact) {
              // Side by side, to leave room for the compare list.
              return Row(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [starRow, number],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Opacity(
                      opacity: fade,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          verdict,
                          const SizedBox(height: 8),
                          _BestPill(best: best, newBest: newBest, short: true),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                starRow,
                const SizedBox(height: 6),
                number,
                Opacity(
                  opacity: fade,
                  child: Column(
                    children: [
                      verdict,
                      const SizedBox(height: 10),
                      _BestPill(best: best, newBest: newBest),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Star extends StatelessWidget {
  final bool on;
  final double t; // 0..1 pop-in
  final Color color, off;
  final double size, lift;

  const _Star({
    required this.on,
    required this.t,
    required this.color,
    required this.off,
    required this.size,
    required this.lift,
  });

  @override
  Widget build(BuildContext context) {
    final pop = on ? Curves.elasticOut.transform(t) : 1.0;
    return Padding(
      padding: EdgeInsets.only(left: 2, right: 2, bottom: lift),
      child: Transform.scale(
        scale: on ? 0.4 + 0.6 * pop : 0.85,
        child: Icon(
          on && t > 0 ? Icons.star_rounded : Icons.star_outline_rounded,
          size: size,
          color: on && t > 0 ? color : off,
        ),
      ),
    );
  }
}

class _BestPill extends StatelessWidget {
  final int? best;
  final bool newBest;
  final bool short;

  const _BestPill({required this.best, required this.newBest, this.short = false});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = ReversePalette.of(context);
    final text = newBest
        ? (short ? 'New best!' : 'New personal best!')
        : (best == null ? 'First try' : '${short ? 'Best' : 'Personal best'}  $best');
    final col = newBest ? p.star : c.textSecondary;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: newBest
            ? p.star.withValues(alpha: p.dark ? 0.16 : 0.12)
            : c.surfaceElevated.withValues(alpha: p.dark ? 0.7 : 0.8),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.emoji_events_rounded, size: 16, color: col),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: newBest ? (p.dark ? p.star : const Color(0xFF8A5A00)) : c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
