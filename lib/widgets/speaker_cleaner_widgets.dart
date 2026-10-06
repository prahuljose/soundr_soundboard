import 'dart:math';

import 'package:flutter/material.dart';

import '../services/cleaner_tones.dart';
import '../theme/app_colors.dart';

/// Where a cleaning run is.
enum CleanerPhase { idle, starting, running, done }

/// Speaker cleaner colours, tuned for contrast in light and dark mode.
class CleanerPalette {
  static const base = Color(0xFF5BB8FF);

  /// Fills and glows.
  final Color tint;

  /// Rings and other graphics on the page background (≥ 3:1).
  final Color line;

  /// Text and icons in the tint colour on page surfaces (≥ 4.5:1).
  final Color text;

  /// Text and icons on a [tint] fill (≥ 4.5:1).
  final Color onTint;

  final bool dark;

  const CleanerPalette._(
    this.tint,
    this.line,
    this.text,
    this.onTint,
    this.dark,
  );

  static CleanerPalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const CleanerPalette._(base, base, base, Color(0xFF04223A), true)
        : const CleanerPalette._(
            base,
            Color(0xFF2F8FE0),
            Color(0xFF1A68A8),
            Color(0xFF04223A),
            false,
          );
  }
}

TextStyle? _buttonFont(BuildContext context) =>
    Theme.of(context).textTheme.bodyMedium;

String formatClock(Duration d) {
  final s = d.inSeconds;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

// ── Mode switch ─────────────────────────────────────────────────────────────

/// Two-segment Water / Dust switch with a sliding highlight.
class CleanerModeSwitch extends StatelessWidget {
  final CleanMode mode;
  final ValueChanged<CleanMode>? onChanged; // null = locked while running

  const CleanerModeSwitch({super.key, required this.mode, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = CleanerPalette.of(context);
    final enabled = onChanged != null;

    Widget segment(CleanMode m, IconData icon, String label) {
      final on = m == mode;
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          enabled: enabled,
          label: '$label mode',
          excludeSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: enabled ? () => onChanged!(m) : null,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 19, color: on ? p.text : c.iconSecondary),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    color: on ? p.text : c.textSecondary,
                    fontSize: 15,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled ? 1 : 0.5,
      child: Container(
        height: 50,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: mode == CleanMode.water
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: p.tint.withValues(alpha: p.dark ? 0.18 : 0.16),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: p.line.withValues(alpha: p.dark ? 0.55 : 0.6),
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Row(
                children: [
                  segment(CleanMode.water, Icons.water_drop_rounded, 'Water'),
                  segment(CleanMode.dust, Icons.cyclone_rounded, 'Dust'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Length chips ────────────────────────────────────────────────────────────

class CleanerLengthChips extends StatelessWidget {
  final List<Duration> lengths;
  final int selected;
  final ValueChanged<int> onSelected;

  static const names = ['Quick', 'Normal', 'Deep'];

  const CleanerLengthChips({
    super.key,
    required this.lengths,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = CleanerPalette.of(context);
    return Row(
      children: [
        for (var i = 0; i < lengths.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              button: true,
              selected: i == selected,
              label: '${names[i]}, ${lengths[i].inSeconds} seconds',
              excludeSemantics: true,
              child: Material(
                color: i == selected
                    ? p.tint.withValues(alpha: p.dark ? 0.16 : 0.12)
                    : c.surfaceCard,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: i == selected ? p.line : c.border,
                    width: i == selected ? 1.5 : 1,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: i == selected ? null : () => onSelected(i),
                  child: SizedBox(
                    height: 50,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          names[i],
                          style: TextStyle(
                            color: i == selected ? p.text : c.textPrimary,
                            fontSize: 14,
                            fontWeight: i == selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                            height: 1.15,
                          ),
                        ),
                        Text(
                          '${lengths[i].inSeconds} s',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 12.5,
                            height: 1.2,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Tips ────────────────────────────────────────────────────────────────────

class CleanerTipsCard extends StatelessWidget {
  final bool compact;
  const CleanerTipsCard({super.key, this.compact = false});

  static const tips = [
    (Icons.volume_up_rounded, 'Turn the volume all the way up'),
    (Icons.south_rounded, 'Point the speaker down'),
    (Icons.hearing_disabled_rounded, 'Don’t hold it to your ear'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = CleanerPalette.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 14, vertical: compact ? 8 : 12),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        children: [
          for (final (icon, text) in tips)
            SizedBox(
              height: compact ? 30 : 34,
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: p.tint.withValues(alpha: p.dark ? 0.14 : 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 15, color: p.text),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
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

// ── Buttons under the dial ──────────────────────────────────────────────────

class CleanerStopButton extends StatelessWidget {
  final VoidCallback onPressed;
  const CleanerStopButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return SizedBox(
      height: 50,
      width: 180,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.stop_rounded, size: 22),
        label: const Text('Stop'),
        style: OutlinedButton.styleFrom(
          foregroundColor: c.textPrimary,
          backgroundColor: c.surfaceCard,
          side: BorderSide(color: c.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: TextStyle(
            fontFamily: _buttonFont(context)?.fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class CleanerRunAgainButton extends StatelessWidget {
  final VoidCallback onPressed;
  const CleanerRunAgainButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final p = CleanerPalette.of(context);
    return SizedBox(
      height: 50,
      width: 200,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.replay_rounded, size: 20),
        label: const Text('Run again'),
        style: FilledButton.styleFrom(
          backgroundColor: p.tint,
          foregroundColor: p.onTint,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: TextStyle(
            fontFamily: _buttonFont(context)?.fontFamily,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ── Dial ────────────────────────────────────────────────────────────────────

/// The big round control: a Start button when idle, a progress ring with a
/// countdown and bursting droplets (or dust) while running, and a check
/// when done. Animates only while [phase] is running — [progress] is the
/// run's controller, which is stopped otherwise.
class CleanerDial extends StatelessWidget {
  final double size;
  final CleanMode mode;
  final CleanerPhase phase;
  final Duration length;
  final Animation<double> progress;
  final VoidCallback onStart;

  /// Tapping the Done face (back to the Start button).
  final VoidCallback onReset;

  const CleanerDial({
    super.key,
    required this.size,
    required this.mode,
    required this.phase,
    required this.length,
    required this.progress,
    required this.onStart,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        switchInCurve: Curves.easeOutCubic,
        layoutBuilder: (current, previous) =>
            Stack(fit: StackFit.expand, children: [...previous, ?current]),
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(
            scale: Tween(begin: 0.94, end: 1.0).animate(a),
            child: child,
          ),
        ),
        child: switch (phase) {
          CleanerPhase.idle || CleanerPhase.starting => _StartFace(
            key: const ValueKey('start'),
            size: size,
            mode: mode,
            length: length,
            starting: phase == CleanerPhase.starting,
            onStart: onStart,
          ),
          CleanerPhase.running => _RunningFace(
            key: const ValueKey('running'),
            size: size,
            mode: mode,
            length: length,
            progress: progress,
          ),
          CleanerPhase.done => _DoneFace(
            key: const ValueKey('done'),
            size: size,
            mode: mode,
            onTap: onReset,
          ),
        },
      ),
    );
  }
}

class _StartFace extends StatelessWidget {
  final double size;
  final CleanMode mode;
  final Duration length;
  final bool starting;
  final VoidCallback onStart;

  const _StartFace({
    super.key,
    required this.size,
    required this.mode,
    required this.length,
    required this.starting,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final p = CleanerPalette.of(context);
    final inner = size - 28;
    final what = mode == CleanMode.water ? 'water eject' : 'dust clean';
    return Semantics(
      button: true,
      label: 'Start $what, ${length.inSeconds} seconds',
      excludeSemantics: true,
      child: Center(
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: p.line.withValues(alpha: p.dark ? 0.28 : 0.3),
              width: 2,
            ),
          ),
          child: Container(
            width: inner,
            height: inner,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: p.tint.withValues(alpha: p.dark ? 0.22 : 0.35),
                  blurRadius: 36,
                  spreadRadius: -4,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Material(
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: Ink(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF8FD0FF), CleanerPalette.base],
                  ),
                ),
                child: InkWell(
                  onTap: starting ? null : onStart,
                  splashColor: Colors.white24,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        mode == CleanMode.water
                            ? Icons.water_drop_rounded
                            : Icons.cyclone_rounded,
                        size: inner * 0.2,
                        color: p.onTint,
                      ),
                      SizedBox(height: inner * 0.03),
                      Text(
                        starting ? 'Starting…' : 'Start',
                        style: TextStyle(
                          color: p.onTint,
                          fontSize: starting ? inner * 0.1 : inner * 0.14,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                          letterSpacing: -0.5,
                        ),
                      ),
                      SizedBox(height: inner * 0.015),
                      Text(
                        '${length.inSeconds} seconds',
                        style: TextStyle(
                          color: p.onTint,
                          fontSize: max(13, inner * 0.058),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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

class _RunningFace extends StatelessWidget {
  final double size;
  final CleanMode mode;
  final Duration length;
  final Animation<double> progress;

  const _RunningFace({
    super.key,
    required this.size,
    required this.mode,
    required this.length,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = CleanerPalette.of(context);
    final iconD = size * 0.24;
    final emitter = Offset(size / 2, size * 0.39);
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        final secs = length.inMicroseconds / 1e6;
        final t = progress.value * secs;
        final level = CleanerTones.intensityAt(mode, t);
        final left = Duration(
          microseconds: ((1 - progress.value) * length.inMicroseconds).ceil(),
        );
        // Round up so it reads 0:30 at the start and 0:00 only at the end.
        final shown = Duration(seconds: (left.inMilliseconds / 1000).ceil());
        return Semantics(
          label:
              '${mode == CleanMode.water ? 'Ejecting water' : 'Clearing dust'}, '
              '${shown.inSeconds} seconds left',
          excludeSemantics: true,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RunPainter(
                    mode: mode,
                    t: t,
                    progress: progress.value,
                    level: level,
                    emitter: emitter,
                    palette: p,
                    colors: c,
                  ),
                ),
              ),
              Positioned(
                left: emitter.dx - iconD / 2,
                top: emitter.dy - iconD / 2,
                width: iconD,
                height: iconD,
                child: Transform.scale(
                  scale: 1 + 0.08 * level,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color.lerp(
                        p.tint.withValues(alpha: p.dark ? 0.2 : 0.18),
                        p.tint.withValues(alpha: p.dark ? 0.36 : 0.32),
                        level,
                      ),
                    ),
                    child: Icon(
                      Icons.volume_up_rounded,
                      size: iconD * 0.5,
                      color: p.text,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: size * 0.55,
                child: Column(
                  children: [
                    Text(
                      formatClock(shown),
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: size * 0.15,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                        letterSpacing: -1,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      mode == CleanMode.water
                          ? 'Ejecting water'
                          : 'Clearing dust',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: max(13, size * 0.05),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RunPainter extends CustomPainter {
  final CleanMode mode;
  final double t; // seconds into the run
  final double progress; // 0..1
  final double level; // 0..1 sound intensity right now
  final Offset emitter;
  final CleanerPalette palette;
  final AppColors colors;

  _RunPainter({
    required this.mode,
    required this.t,
    required this.progress,
    required this.level,
    required this.emitter,
    required this.palette,
    required this.colors,
  });

  static const _stroke = 10.0;

  // Deterministic 0..1 noise, so particles don't jitter between frames.
  static double _rand(int a, int b) {
    var h = a * 374761393 + b * 668265263;
    h = (h ^ (h >> 13)) * 1274126177;
    h = h ^ (h >> 16);
    return (h & 0xFFFF) / 0xFFFF;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2 - _stroke / 2 - 4;
    final p = palette;

    // Face.
    canvas.drawCircle(center, r, Paint()..color = colors.surfaceCard);

    // Particles, kept inside the ring.
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: r - _stroke)),
    );
    if (mode == CleanMode.water) {
      _paintDrops(canvas, size);
    } else {
      _paintDust(canvas, size);
    }
    canvas.restore();

    // Track, glow and progress.
    final ring = Rect.fromCircle(center: center, radius: r);
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = colors.surfaceElevated
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke,
    );
    final sweep = 2 * pi * progress.clamp(0.0, 1.0);
    canvas.drawArc(
      ring,
      -pi / 2,
      max(sweep, 0.001),
      false,
      Paint()
        ..color = p.tint.withValues(alpha: (p.dark ? 0.25 : 0.3) + 0.35 * level)
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke + 10
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 + 6 * level),
    );
    canvas.drawArc(
      ring,
      -pi / 2,
      max(sweep, 0.001),
      false,
      Paint()
        ..color = p.line
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = _stroke,
    );
  }

  /// Droplets thrown up and out at the start of each pulse, falling back
  /// under a little gravity.
  void _paintDrops(Canvas canvas, Size size) {
    const period = CleanerTones.waterPulsePeriod;
    const life = 1.05;
    final reach = size.width * 0.34;
    final current = (t / period).floor();
    for (var k = max(0, current - 1); k <= current; k++) {
      final age = t - k * period;
      if (age < 0 || age > life) continue;
      final a = age / life;
      final ease = 1 - pow(1 - a, 3).toDouble();
      final fade = 1 - a * a;
      for (var i = 0; i < 11; i++) {
        final angle = -pi / 2 + (_rand(k, i) - 0.5) * pi * 0.95;
        final dist = reach * (0.55 + 0.45 * _rand(k, i + 50));
        final dir = Offset(cos(angle), sin(angle));
        final gravity = Offset(0, size.width * 0.16 * a * a);
        final pos = emitter + dir * (size.width * 0.1 + dist * ease) + gravity;
        // Point the drop's tail back along its path.
        final vel =
            dir * (dist * 3 * pow(1 - a, 2).toDouble()) +
            Offset(0, size.width * 0.32 * a);
        final rad = size.width * (0.011 + 0.011 * _rand(k, i + 99));
        _drop(
          canvas,
          pos,
          atan2(vel.dy, vel.dx),
          rad,
          palette.tint.withValues(alpha: 0.85 * fade),
        );
      }
    }
  }

  void _drop(Canvas canvas, Offset at, double heading, double r, Color color) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(heading);
    final path = Path()
      ..moveTo(-r * 2.4, 0)
      ..quadraticBezierTo(-r * 0.7, -r * 1.05, 0, -r)
      ..arcToPoint(Offset(0, r), radius: Radius.circular(r))
      ..quadraticBezierTo(-r * 0.7, r * 1.05, -r * 2.4, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.restore();
  }

  /// Specks swirling out, more of them near the top of each sweep.
  void _paintDust(Canvas canvas, Size size) {
    final period = CleanerTones.burstPeriod(CleanMode.dust);
    const life = 1.4;
    final reach = size.width * 0.36;
    final current = (t / period).floor();
    for (var k = max(0, current - 2); k <= current; k++) {
      final age = t - k * period;
      if (age < 0 || age > life) continue;
      final a = age / life;
      final ease = 1 - pow(1 - a, 2).toDouble();
      final fade = 1 - a * a;
      final strength = CleanerTones.intensityAt(CleanMode.dust, k * period);
      final count = 8 + (strength * 8).round();
      for (var i = 0; i < count; i++) {
        final start = -pi / 2 + (_rand(k, i) - 0.5) * pi * 1.25;
        final angle = start + a * 0.9 * (_rand(k, i + 7) < 0.5 ? -1 : 1);
        final dist = reach * (0.35 + 0.65 * _rand(k, i + 50));
        final pos =
            emitter +
            Offset(cos(angle), sin(angle)) * (size.width * 0.1 + dist * ease);
        final rad = size.width * (0.006 + 0.008 * _rand(k, i + 99));
        final color = _rand(k, i + 3) < 0.55
            ? palette.tint
            : colors.textSecondary;
        canvas.drawCircle(
          pos,
          rad,
          Paint()..color = color.withValues(alpha: color.a * 0.85 * fade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_RunPainter old) =>
      old.t != t ||
      old.mode != mode ||
      old.palette.dark != palette.dark ||
      old.emitter != emitter;
}

class _DoneFace extends StatelessWidget {
  final double size;
  final CleanMode mode;
  final VoidCallback onTap;

  const _DoneFace({
    super.key,
    required this.size,
    required this.mode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = CleanerPalette.of(context);
    final iconD = size * 0.3;
    return Semantics(
      liveRegion: true,
      button: true,
      label: 'Done',
      hint: 'Back to start',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.surfaceCard,
            border: Border.all(color: p.line, width: 10),
            boxShadow: [
              BoxShadow(
                color: p.tint.withValues(alpha: p.dark ? 0.22 : 0.28),
                blurRadius: 28,
                spreadRadius: -4,
              ),
            ],
          ),
          margin: const EdgeInsets.all(4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0.6, end: 1),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutBack,
                builder: (context, s, child) =>
                    Transform.scale(scale: s, child: child),
                child: Container(
                  width: iconD,
                  height: iconD,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: p.tint,
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    size: iconD * 0.6,
                    color: p.onTint,
                  ),
                ),
              ),
              SizedBox(height: size * 0.05),
              Text(
                'Done',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: size * 0.12,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
              Text(
                mode == CleanMode.water
                    ? 'Water eject finished'
                    : 'Dust clean finished',
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: max(13, size * 0.05),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
