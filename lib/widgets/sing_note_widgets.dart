import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/sing_note_game.dart';
import '../theme/app_colors.dart';

/// Sing the Note colours, tuned for contrast in light and dark mode.
class SingPalette {
  /// Fills and graphics (buttons, the voice ball, rings).
  final Color tint;

  /// Tint for text and icons on cards (≥ 4.5:1).
  final Color tintText;

  /// Text and icons on a [tint] fill.
  final Color onTint;

  /// On the note.
  final Color good;

  /// Text and icons on a [good] fill.
  final Color onGood;

  /// Missed.
  final Color bad;
  final Color star;
  final bool dark;

  const SingPalette._(
    this.tint,
    this.tintText,
    this.onTint,
    this.good,
    this.onGood,
    this.bad,
    this.star,
    this.dark,
  );

  static SingPalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const SingPalette._(
            Color(0xFFFFB86B),
            Color(0xFFFFB86B),
            Color(0xFF2B1700),
            Color(0xFF5FD08A),
            Color(0xFF062412),
            Color(0xFFF27A7A),
            Color(0xFFFFC94D),
            true,
          )
        : const SingPalette._(
            Color(0xFFE8922E),
            Color(0xFF9A5200),
            Color(0xFF2B1700),
            Color(0xFF16804A),
            Colors.white,
            Color(0xFFC0392B),
            Color(0xFFC07F00),
            false,
          );
  }

  /// A soft wash of the tint for card backgrounds.
  Color get wash => tint.withValues(alpha: dark ? 0.13 : 0.11);

  Color forGrade(SingGrade g) => switch (g) {
    SingGrade.hit => good,
    SingGrade.close => tintText,
    SingGrade.miss => bad,
  };
}

IconData singGradeIcon(SingGrade g) => switch (g) {
  SingGrade.hit => Icons.check_rounded,
  SingGrade.close => Icons.remove_rounded,
  SingGrade.miss => Icons.close_rounded,
};

// ── Round header ────────────────────────────────────────────────────────────

/// "Note 3 of 8" with a dot per note: done ones take their grade's colour.
class SingRoundHeader extends StatelessWidget {
  final int index;
  final int count;
  final List<SingGrade> grades;

  const SingRoundHeader({
    super.key,
    required this.index,
    required this.count,
    required this.grades,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    return Semantics(
      label: 'Note ${index + 1} of $count',
      excludeSemantics: true,
      child: Row(
        children: [
          Text(
            'Note ${index + 1}',
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            ' of $count',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.only(left: 6),
              width: i == index ? 18 : 9,
              height: 9,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                color: i < grades.length
                    ? p.forGrade(grades[i])
                    : (i == index ? p.tint : c.surfaceElevated),
                border: i >= grades.length && i != index
                    ? Border.all(color: c.border)
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// Thin bar that empties as the time to sing runs out.
class SingTimeBar extends StatelessWidget {
  /// 1 → 0.
  final double left;
  final bool visible;

  const SingTimeBar({super.key, required this.left, required this.visible});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    return ExcludeSemantics(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: visible ? 1 : 0,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            width: double.infinity,
            height: 4,
            child: ColoredBox(
              color: c.surfaceElevated,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: left.clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 90),
                builder: (_, v, _) => FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: v,
                  child: ColoredBox(color: v < 0.25 ? p.bad : p.tint),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Stage: the note, its hold ring, and the pitch meter ─────────────────────

enum SingStageMode { listen, sing, hit, missed }

/// The target note in a ring that fills while the note is held, beside a
/// vertical pitch meter: the ball is your voice, the green band is the note.
/// The ball glides (critically damped) rather than jumping between readings.
class SingStage extends StatefulWidget {
  final String note;
  final SingStageMode mode;
  final SingStatus status;

  /// Distance from the note in cents (folded to ±600); null = not singing.
  final double? cents;

  /// 0..1 of the hold.
  final double progress;

  /// How long the tone plays; drives the one-shot "listen" animation.
  final Duration listenFor;

  /// Changes whenever the tone is (re)played, restarting that animation.
  final int listenToken;

  /// With [SingStageMode.missed]: it was close, so show a dash, not a cross.
  final bool nearMiss;

  const SingStage({
    super.key,
    required this.note,
    required this.mode,
    required this.status,
    required this.cents,
    required this.progress,
    required this.listenFor,
    this.listenToken = 0,
    this.nearMiss = false,
  });

  /// Meter position for [cents]: −1 (bottom) … 1 (top). The semitone either
  /// side of the note gets 60 % of the travel; the rest is squeezed in.
  static double meterPos(double cents) {
    final a = cents.abs().clamp(0.0, 600.0);
    final n = a <= 100 ? 0.6 * a / 100 : 0.6 + 0.4 * (a - 100) / 500;
    return cents < 0 ? -n : n;
  }

  @override
  State<SingStage> createState() => _SingStageState();
}

class _SingStageState extends State<SingStage> with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _listen = AnimationController(
    vsync: this,
    duration: widget.listenFor,
  );
  Duration _last = Duration.zero;

  double _pos = 0; // ball, −1..1
  double _presence = 0; // ball shown
  double _glow = 0; // on the note
  double _ring = 0; // hold ring

  bool get _singing =>
      widget.mode == SingStageMode.sing &&
      widget.status != SingStatus.waiting &&
      widget.cents != null;

  double get _posTarget => widget.mode == SingStageMode.hit
      ? 0
      : (_singing ? SingStage.meterPos(widget.cents!) : _pos);
  double get _presenceTarget =>
      _singing || widget.mode == SingStageMode.hit ? 1 : 0;
  double get _glowTarget =>
      widget.mode == SingStageMode.hit ||
          (_singing && widget.status == SingStatus.inTune)
      ? 1
      : 0;
  double get _ringTarget => switch (widget.mode) {
    SingStageMode.hit => 1,
    SingStageMode.listen => 0,
    _ => widget.progress,
  };

  @override
  void initState() {
    super.initState();
    _pos = _singing ? _posTarget : 0;
    _presence = _presenceTarget;
    _glow = _glowTarget;
    _ring = _ringTarget;
    if (widget.mode == SingStageMode.listen) _listen.forward();
  }

  @override
  void didUpdateWidget(SingStage old) {
    super.didUpdateWidget(old);
    if (widget.mode == SingStageMode.listen) {
      if (old.mode != SingStageMode.listen ||
          old.listenToken != widget.listenToken) {
        _listen
          ..duration = widget.listenFor
          ..forward(from: 0);
      }
    } else if (_listen.isAnimating) {
      _listen.stop();
    }
    // A new note starts with an empty ring, not one draining away.
    if (old.note != widget.note) _ring = 0;
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
    final pos = ease(_pos, _posTarget, 10);
    final pr = ease(_presence, _presenceTarget, 9);
    final g = ease(_glow, _glowTarget, 9);
    final r = ease(_ring, _ringTarget, 14);
    final settled =
        (pos - _posTarget).abs() < 0.002 &&
        (pr - _presenceTarget).abs() < 0.01 &&
        (g - _glowTarget).abs() < 0.01 &&
        (r - _ringTarget).abs() < 0.003;
    setState(() {
      _pos = settled ? _posTarget : pos;
      _presence = settled ? _presenceTarget : pr;
      _glow = settled ? _glowTarget : g;
      _ring = settled ? _ringTarget : r;
    });
    if (settled) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _listen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    final style = DefaultTextStyle.of(context).style;
    final mode = widget.mode;
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, box) {
          const meterW = 58.0, gap = 22.0;
          final d = min(
            min(230.0, box.maxWidth - meterW - gap - 8),
            box.maxHeight - 24,
          ).clamp(110.0, 230.0);
          final meterH = min(box.maxHeight, max(d + 110, 250.0));
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: d,
                height: d,
                child: AnimatedBuilder(
                  animation: _listen,
                  builder: (context, _) => Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _RingPainter(
                            ring: _ring,
                            glow: _glow,
                            listen: mode == SingStageMode.listen
                                ? _listen.value
                                : null,
                            missed: mode == SingStageMode.missed,
                            palette: p,
                            colors: c,
                          ),
                        ),
                      ),
                      Text(
                        widget.note,
                        style: TextStyle(
                          color: Color.lerp(
                            mode == SingStageMode.missed
                                ? c.textSecondary
                                : c.textPrimary,
                            p.good,
                            _glow,
                          ),
                          fontSize: d * (widget.note.length > 1 ? 0.36 : 0.44),
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                          letterSpacing: -2,
                        ),
                      ),
                      if (mode == SingStageMode.hit ||
                          mode == SingStageMode.missed)
                        Positioned(
                          right: d * 0.08,
                          bottom: d * 0.08,
                          child: _Badge(
                            key: ValueKey(mode),
                            icon: mode == SingStageMode.hit
                                ? Icons.check_rounded
                                : (widget.nearMiss
                                      ? Icons.remove_rounded
                                      : Icons.close_rounded),
                            fill: mode == SingStageMode.hit
                                ? p.good
                                : c.surfaceElevated,
                            fg: mode == SingStageMode.hit
                                ? p.onGood
                                : c.textSecondary,
                            ring: c.scaffoldBg,
                            size: d * 0.26,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: gap),
              SizedBox(
                width: meterW,
                height: meterH,
                child: CustomPaint(
                  painter: _MeterPainter(
                    pos: _pos,
                    presence: _presence,
                    glow: _glow,
                    dim:
                        mode == SingStageMode.listen ||
                        mode == SingStageMode.missed,
                    palette: p,
                    colors: c,
                    textStyle: style,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Tick / cross that pops in on the ring when a note ends.
class _Badge extends StatelessWidget {
  final IconData icon;
  final Color fill, fg, ring;
  final double size;

  const _Badge({
    super.key,
    required this.icon,
    required this.fill,
    required this.fg,
    required this.ring,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 450),
      curve: Curves.elasticOut,
      builder: (_, t, child) => Transform.scale(scale: t, child: child),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(color: ring, width: 3),
        ),
        child: Icon(icon, color: fg, size: size * 0.62),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double ring, glow;
  final double? listen; // 0..1 while the tone plays
  final bool missed;
  final SingPalette palette;
  final AppColors colors;

  _RingPainter({
    required this.ring,
    required this.glow,
    required this.listen,
    required this.missed,
    required this.palette,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    const stroke = 11.0;
    final r = size.shortestSide / 2 - stroke / 2 - 6;
    final p = palette;

    final l = listen;

    // Disc.
    canvas.drawCircle(
      center,
      r - stroke / 2 - 5,
      Paint()
        ..color = Color.lerp(
          missed ? colors.surfaceCard : p.wash,
          p.good.withValues(alpha: p.dark ? 0.16 : 0.12),
          glow,
        )!,
    );

    // Sound ripples while the tone plays (one-shot, tied to its length).
    if (l != null) {
      for (var k = 0; k < 2; k++) {
        final t = (l * 3 + k * 0.5) % 1.0;
        final fade = (1 - t) * (1 - l * l);
        canvas.drawCircle(
          center,
          r * (0.5 + 0.34 * t),
          Paint()
            ..color = p.tint.withValues(alpha: 0.28 * fade)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }

    // Ring track.
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = colors.surfaceElevated
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );

    final rect = Rect.fromCircle(center: center, radius: r);
    if (l != null) {
      // The tone's length sweeps round in the game tint.
      canvas.drawArc(
        rect,
        -pi / 2,
        2 * pi * l.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = p.tint
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke,
      );
    } else if (ring > 0.001) {
      if (glow > 0.01) {
        canvas.drawArc(
          rect,
          -pi / 2,
          2 * pi * ring,
          false,
          Paint()
            ..color = p.good.withValues(alpha: 0.35 * glow)
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke + 8
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
        );
      }
      canvas.drawArc(
        rect,
        -pi / 2,
        2 * pi * ring,
        false,
        Paint()
          ..color = missed ? colors.iconSecondary : p.good
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.ring != ring ||
      old.glow != glow ||
      old.listen != listen ||
      old.missed != missed ||
      old.palette.tint != palette.tint ||
      old.colors != colors;
}

class _MeterPainter extends CustomPainter {
  final double pos, presence, glow;
  final bool dim;
  final SingPalette palette;
  final AppColors colors;
  final TextStyle textStyle;

  _MeterPainter({
    required this.pos,
    required this.presence,
    required this.glow,
    required this.dim,
    required this.palette,
    required this.colors,
    required this.textStyle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = palette;
    final c = colors;
    const labelH = 18.0, ballR = 13.0;
    final trackW = min(size.width, 40.0);
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        (size.width - trackW) / 2,
        labelH,
        trackW,
        size.height - labelH * 2,
      ),
      Radius.circular(trackW / 2),
    );
    final cx = size.width / 2;
    final cy = size.height / 2;
    final half = track.height / 2 - ballR - 5;
    final fade = dim ? 0.45 : 1.0;

    canvas.drawRRect(track, Paint()..color = c.surfaceCard);
    canvas.drawRRect(
      track,
      Paint()
        ..color = c.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Semitone ticks either side.
    final tick = Paint()
      ..color = c.iconSecondary.withValues(alpha: 0.55 * fade)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    for (final cents in const [-500.0, -300.0, -100.0, 100.0, 300.0, 500.0]) {
      final y = cy - SingStage.meterPos(cents) * half;
      final w = cents.abs() == 100 ? 8.0 : 5.0;
      canvas.drawLine(Offset(cx - w, y), Offset(cx + w, y), tick);
    }

    // The note: a band the ball has to sit in.
    final bandHalf =
        SingStage.meterPos(SingNoteGame.toleranceCents) * half + ballR * 0.55;
    final band = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: trackW - 6,
        height: bandHalf * 2,
      ),
      const Radius.circular(10),
    );
    if (glow > 0.01) {
      canvas.drawRRect(
        band.inflate(4),
        Paint()
          ..color = p.good.withValues(alpha: 0.4 * glow)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }
    canvas.drawRRect(
      band,
      Paint()..color = p.good.withValues(alpha: (0.22 + 0.3 * glow) * fade),
    );
    canvas.drawRRect(
      band,
      Paint()
        ..color = p.good.withValues(alpha: (0.7 + 0.3 * glow) * fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Your voice.
    if (presence > 0.01) {
      final at = Offset(cx, cy - pos.clamp(-1.0, 1.0) * half);
      final col = Color.lerp(p.tint, p.good, glow)!;
      canvas.drawCircle(
        at,
        ballR + 5,
        Paint()
          ..color = col.withValues(alpha: 0.3 * presence)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(
        at,
        ballR * (0.6 + 0.4 * presence),
        Paint()..color = col.withValues(alpha: presence),
      );
      canvas.drawCircle(
        at,
        ballR * (0.6 + 0.4 * presence),
        Paint()
          ..color = (p.dark ? Colors.white : Colors.black).withValues(
            alpha: 0.25 * presence,
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    void label(String text, double y) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: textStyle.copyWith(
            color: c.textSecondary.withValues(
              alpha: c.textSecondary.a * (dim ? 0.6 : 1),
            ),
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, y - tp.height / 2));
    }

    label('HIGH', labelH / 2 - 1);
    label('LOW', size.height - labelH / 2 + 1);
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.pos != pos ||
      old.presence != presence ||
      old.glow != glow ||
      old.dim != dim ||
      old.palette.tint != palette.tint ||
      old.colors != colors;
}

// ── Guidance ────────────────────────────────────────────────────────────────

enum SingCue { neutral, warn, good, bad }

/// The one thing to do right now: "Listen…", "Too low", "Hold it…".
class SingGuidance extends StatelessWidget {
  final String text;
  final IconData? icon;
  final SingCue cue;

  const SingGuidance({
    super.key,
    required this.text,
    this.icon,
    this.cue = SingCue.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    final col = switch (cue) {
      SingCue.neutral => c.textPrimary,
      SingCue.warn => p.tintText,
      SingCue.good => p.good,
      SingCue.bad => c.textSecondary,
    };
    final filled = cue == SingCue.warn || cue == SingCue.good;
    return Semantics(
      liveRegion: true,
      label: text,
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: filled
              ? col.withValues(alpha: p.dark ? 0.16 : 0.1)
              : c.surfaceCard,
          borderRadius: BorderRadius.circular(23),
          border: Border.all(
            color: filled ? col.withValues(alpha: 0.55) : c.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 21, color: col),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: col,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Results ─────────────────────────────────────────────────────────────────

class SingBestPill extends StatelessWidget {
  final int? best;
  final bool newBest;

  const SingBestPill({super.key, required this.best, this.newBest = false});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    final text = newBest
        ? 'New personal best!'
        : (best == null ? 'No best yet' : 'Personal best  $best');
    final col = newBest
        ? (p.dark ? p.star : const Color(0xFF8A5A00))
        : c.textSecondary;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: newBest
            ? p.star.withValues(alpha: p.dark ? 0.16 : 0.14)
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
              color: col,
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

/// Stars, the score counting up, a verdict and the personal best.
class SingScoreCard extends StatelessWidget {
  final int score;
  final int stars;
  final String message;
  final int? best;
  final bool newBest;
  final bool compact;

  const SingScoreCard({
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
    final p = SingPalette.of(context);
    return Semantics(
      label:
          'Score $score out of 100, $stars ${stars == 1 ? 'star' : 'stars'}. $message.'
          '${newBest ? ' New personal best.' : (best != null ? ' Best $best.' : '')}',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(
          16,
          compact ? 12 : 20,
          16,
          compact ? 14 : 20,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: p.tint.withValues(alpha: p.dark ? 0.3 : 0.45),
          ),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              p.tint.withValues(alpha: p.dark ? 0.2 : 0.18),
              p.tint.withValues(alpha: p.dark ? 0.06 : 0.05),
            ],
          ),
        ),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 1400),
          builder: (context, t, _) {
            final count = Curves.easeOutCubic.transform(
              (t / 0.65).clamp(0.0, 1.0),
            );
            final fade = ((t - 0.45) / 0.3).clamp(0.0, 1.0);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 3; i++)
                      _Star(
                        on: i < stars,
                        t: ((t - 0.25 - i * 0.15) / 0.3).clamp(0.0, 1.0),
                        color: p.star,
                        off: c.border,
                        size: compact ? 30 : 38,
                        lift: i == 1 ? 6 : 0,
                      ),
                  ],
                ),
                SizedBox(height: compact ? 0 : 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '${(score * count).round()}',
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: compact ? 56 : 72,
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
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Opacity(
                  opacity: fade,
                  child: Column(
                    children: [
                      Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.tintText,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: compact ? 8 : 12),
                      SingBestPill(best: best, newBest: newBest),
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

/// One mark per note of the round: its name under a ✓ / – / ✗.
class SingResultRow extends StatelessWidget {
  final List<({String note, SingGrade grade})> notes;

  const SingResultRow({super.key, required this.notes});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = SingPalette.of(context);
    final hits = notes.where((n) => n.grade == SingGrade.hit).length;
    Widget legend(SingGrade g, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(singGradeIcon(g), size: 14, color: p.forGrade(g)),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(color: c.textSecondary, fontSize: 12)),
      ],
    );
    return Semantics(
      label:
          '$hits of ${notes.length} notes hit. '
          '${notes.map((n) => '${n.note} ${switch (n.grade) {
            SingGrade.hit => 'hit',
            SingGrade.close => 'close',
            SingGrade.miss => 'missed',
          }}').join(', ')}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 14, 10, 12),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                for (final n in notes)
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: p
                                .forGrade(n.grade)
                                .withValues(alpha: p.dark ? 0.18 : 0.12),
                            border: Border.all(
                              color: p.forGrade(n.grade).withValues(alpha: 0.6),
                            ),
                          ),
                          child: Icon(
                            singGradeIcon(n.grade),
                            size: 17,
                            color: p.forGrade(n.grade),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          n.note,
                          maxLines: 1,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              alignment: WrapAlignment.center,
              children: [
                legend(SingGrade.hit, 'Hit'),
                legend(SingGrade.close, 'Close'),
                legend(SingGrade.miss, 'Missed'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
