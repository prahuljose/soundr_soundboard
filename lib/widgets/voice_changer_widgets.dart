import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/voice_effects.dart';
import '../theme/app_colors.dart';
import 'waveform_bars.dart';

/// Voice changer colours: a playful pink, darkened for text and borders in
/// light mode so it keeps ≥ 4.5:1 contrast.
class VoicePalette {
  /// Fills (mic button, halos, waveform).
  final Color tint;

  /// Text, icons and borders in the tint colour.
  final Color ink;

  /// Icons and text drawn on [tint].
  final Color onTint;
  final bool dark;

  const VoicePalette._(this.tint, this.ink, this.onTint, this.dark);

  static const pink = Color(0xFFFF7FA8);

  static VoicePalette of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return dark
        ? const VoicePalette._(pink, pink, Color(0xFF3A0B1C), true)
        : const VoicePalette._(
            pink,
            Color(0xFFB0245A),
            Color(0xFF3A0B1C),
            false,
          );
  }

  /// Soft background for selected things.
  Color get wash => tint.withValues(alpha: dark ? 0.16 : 0.14);
}

/// Bar heights (0..1) summarising [samples] in [count] buckets, scaled so
/// quiet speech still shows.
List<double> wavePeaks(Float64List samples, {int count = 64}) {
  if (samples.isEmpty) return List.filled(count, 0);
  final out = List<double>.filled(count, 0);
  var top = 0.0;
  for (var b = 0; b < count; b++) {
    final from = b * samples.length ~/ count;
    final to = max(from + 1, (b + 1) * samples.length ~/ count);
    var p = 0.0;
    for (var i = from; i < to && i < samples.length; i++) {
      final a = samples[i].abs();
      if (a > p) p = a;
    }
    out[b] = p;
    top = max(top, p);
  }
  if (top <= 0) return out;
  return [for (final p in out) sqrt(p / top)];
}

String formatClipTime(Duration d) {
  final s = d.inMilliseconds / 1000;
  return '0:${s.floor().toString().padLeft(2, '0')}';
}

// ── Mic button ──────────────────────────────────────────────────────────────

/// The big round record button. While recording it turns into a stop
/// button, a halo swells with the input level and a ring fills up towards
/// the length limit.
class VoiceMicButton extends StatelessWidget {
  final bool recording;

  /// Input level 0..1 (recording only).
  final double level;

  /// Fraction of the maximum length recorded so far, 0..1.
  final double progress;
  final double size;
  final VoidCallback onTap;

  const VoiceMicButton({
    super.key,
    required this.recording,
    required this.onTap,
    this.level = 0,
    this.progress = 0,
    this.size = 150,
  });

  @override
  Widget build(BuildContext context) {
    final p = VoicePalette.of(context);
    final c = Theme.of(context).extension<AppColors>()!;
    final box = size * 1.5;
    return Semantics(
      button: true,
      label: recording ? 'Stop recording' : 'Record',
      excludeSemantics: true,
      child: SizedBox(
        width: box,
        height: box,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Level halo.
            AnimatedScale(
              scale: recording ? 1.0 + 0.42 * level : 1.0,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOut,
              child: Container(
                width: size * 1.04,
                height: size * 1.04,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.tint.withValues(
                    alpha: recording ? (p.dark ? 0.2 : 0.26) : 0.0,
                  ),
                ),
              ),
            ),
            // Idle: a soft outer ring. Recording: progress to the limit.
            SizedBox(
              width: size * 1.2,
              height: size * 1.2,
              child: CustomPaint(
                painter: _RingPainter(
                  progress: recording ? progress : 0,
                  color: p.ink,
                  track: recording
                      ? c.border
                      : p.tint.withValues(alpha: p.dark ? 0.22 : 0.35),
                  width: 4,
                ),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: Ink(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFFFFA3C1), Color(0xFFFF6E9C)],
                  ),
                ),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, a) =>
                        ScaleTransition(scale: a, child: child),
                    child: recording
                        ? Container(
                            key: const ValueKey('stop'),
                            width: size * 0.28,
                            height: size * 0.28,
                            decoration: BoxDecoration(
                              color: p.onTint,
                              borderRadius: BorderRadius.circular(size * 0.06),
                            ),
                          )
                        : Icon(
                            Icons.mic_rounded,
                            key: const ValueKey('mic'),
                            size: size * 0.42,
                            color: p.onTint,
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

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color track;
  final double width;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.track,
    required this.width,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * pi, false, paint..color = track);
    if (progress > 0) {
      canvas.drawArc(
        rect,
        -pi / 2,
        2 * pi * progress.clamp(0.0, 1.0),
        false,
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color || old.track != track;
}

/// Live input level while recording: newest bar on the right.
class LiveLevelBars extends StatelessWidget {
  final List<double> levels;
  final int count;

  const LiveLevelBars({super.key, required this.levels, this.count = 36});

  @override
  Widget build(BuildContext context) {
    final p = VoicePalette.of(context);
    final recent = levels.length > count
        ? levels.sublist(levels.length - count)
        : levels;
    final bars = [
      ...List.filled(count - recent.length, 0.0),
      // Speech sits around 0.5–0.8 on the dB scale; stretch it.
      for (final l in recent) ((l - 0.25) / 0.6).clamp(0.0, 1.0),
    ];
    return WaveformBars(
      levels: bars,
      progress: 1,
      activeColor: p.ink,
      idleColor: p.ink,
      height: 44,
    );
  }
}

// ── Recording card ──────────────────────────────────────────────────────────

/// The recording (or the chosen voice's render of it) as a waveform, with a
/// play/stop button and the played part tinted.
class VoiceWaveformCard extends StatelessWidget {
  final String title;
  final String? emoji;
  final Duration duration;
  final List<double> peaks;

  /// 0..1 while this clip plays, else null.
  final ValueListenable<double?> progress;
  final bool playing;
  final bool busy;
  final VoidCallback onTap;

  const VoiceWaveformCard({
    super.key,
    required this.title,
    required this.duration,
    required this.peaks,
    required this.progress,
    required this.playing,
    required this.onTap,
    this.emoji,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = VoicePalette.of(context);
    return Semantics(
      button: true,
      label:
          '${playing ? 'Stop' : 'Play'} ${title.toLowerCase()}, ${duration.inSeconds} seconds',
      excludeSemantics: true,
      child: Material(
        color: c.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: VoicePalette.pink,
                  ),
                  child: busy
                      ? Padding(
                          padding: const EdgeInsets.all(13),
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: p.onTint,
                          ),
                        )
                      : Icon(
                          playing
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          color: p.onTint,
                          size: 28,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (emoji != null) ...[
                            Text(
                              emoji!,
                              style: const TextStyle(fontSize: 15, height: 1.2),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                height: 1.2,
                              ),
                            ),
                          ),
                          Text(
                            formatClipTime(duration),
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 13,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder<double?>(
                        valueListenable: progress,
                        builder: (context, v, _) => WaveformBars(
                          levels: peaks,
                          progress: playing ? (v ?? 0) : 0,
                          activeColor: p.ink,
                          idleColor: playing
                              ? c.textMuted
                              : p.ink.withValues(alpha: 0.55),
                          height: 34,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Effect tile ─────────────────────────────────────────────────────────────

/// One voice in the grid: emoji and name. Selected tiles are tinted; a
/// ring around the emoji fills while it plays, and a spinner shows while
/// it's being made.
class VoiceEffectTile extends StatelessWidget {
  final VoiceEffect effect;
  final bool selected;
  final bool rendering;
  final bool playing;

  /// Playback progress, read only while [playing].
  final ValueListenable<double?> progress;
  final VoidCallback onTap;
  final bool compact;

  const VoiceEffectTile({
    super.key,
    required this.effect,
    required this.selected,
    required this.rendering,
    required this.playing,
    required this.progress,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = VoicePalette.of(context);
    final circle = compact ? 38.0 : 48.0;
    final ringPad = compact ? 6.0 : 8.0;
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${effect.label} voice'
          '${rendering
              ? ', getting ready'
              : playing
              ? ', playing, tap to stop'
              : ''}',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: selected ? p.wash : c.surfaceCard,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? p.ink : c.border,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Stack(
              children: [
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: circle + ringPad,
                        height: circle + ringPad,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: circle,
                              height: circle,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: selected
                                    ? p.tint.withValues(
                                        alpha: p.dark ? 0.22 : 0.24,
                                      )
                                    : c.surfaceElevated.withValues(
                                        alpha: p.dark ? 0.7 : 0.75,
                                      ),
                              ),
                            ),
                            Text(
                              effect.emoji,
                              style: TextStyle(
                                fontSize: compact ? 20 : 25,
                                height: 1.15,
                              ),
                            ),
                            if (playing)
                              Positioned.fill(
                                child: ValueListenableBuilder<double?>(
                                  valueListenable: progress,
                                  builder: (context, v, _) => CustomPaint(
                                    painter: _RingPainter(
                                      progress: v ?? 0,
                                      color: p.ink,
                                      track: p.ink.withValues(alpha: 0.2),
                                      width: 3,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      SizedBox(height: compact ? 1 : 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          effect.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? (p.dark ? c.textPrimary : p.ink)
                                : c.textPrimary,
                            fontSize: compact ? 12.5 : 13.5,
                            height: 1.2,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (rendering || playing)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: rendering
                          ? CircularProgressIndicator(
                              strokeWidth: 2,
                              color: p.ink,
                            )
                          : Icon(Icons.stop_rounded, size: 16, color: p.ink),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
