import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/sound_model.dart';
import '../services/haptics.dart';
import '../services/sound_prefs.dart';
import '../theme/app_colors.dart';

// ── Model ───────────────────────────────────────────────────────────────────

/// One board the performer can switch to (Favourites, a custom board, Most
/// played, All sounds…).
@immutable
class PerformanceSet {
  final String id;
  final String name;
  final String emoji;
  final List<SoundModel> sounds;

  const PerformanceSet({
    required this.id,
    required this.name,
    required this.emoji,
    required this.sounds,
  });
}

// ── Playback ────────────────────────────────────────────────────────────────

/// Plays pads through SoLoud the same way the soundboard plays one-shot
/// sounds: start paused, seek to a user clip's trim start, apply the per-sound
/// speed, then stop at the trim end.
///
/// Performance mode is always one-shot: the per-sound loop setting from the
/// soundboard is deliberately ignored so a pad can never get stuck looping
/// mid-set. Tapping a playing pad restarts it instead.
///
/// Every SoLoud call is guarded. When the engine isn't available (widget
/// tests, or init failed) [play] still returns a duration — [debugDurationMs]
/// or 1500 ms — so the pads can show their playing state.
class PerformancePlayer {
  PerformancePlayer({this.preloaded = const {}, this.debugDurationMs});

  /// Sound id → source already loaded by the soundboard.
  final Map<String, AudioSource> preloaded;

  /// Playback length reported when SoLoud isn't ready.
  final int? debugDurationMs;

  static const _fallbackMs = 1500;

  final Map<String, SoundHandle> _voices = {};
  final Map<String, Timer> _endTimers = {};
  final Map<String, int> _generation = {};
  int _epoch = 0;
  bool _disposed = false;

  bool get _ready {
    try {
      return SoLoud.instance.isInitialized;
    } catch (_) {
      return false; // native library missing (tests)
    }
  }

  /// Starts [sound] from the top, stopping any voice it already has.
  /// Returns how long it will play (speed applied), or null if it can't play.
  Future<Duration?> play(SoundModel sound) async {
    if (_disposed) return null;
    stop(sound.id);
    final gen = _generation[sound.id] = (_generation[sound.id] ?? 0) + 1;
    final epoch = _epoch;
    final speed = SoundPrefs.speedOf(sound.id);

    if (!_ready) {
      return Duration(
          milliseconds: ((debugDurationMs ?? _fallbackMs) / speed).round());
    }
    final source = preloaded[sound.id];
    if (source == null) return null;

    try {
      final trimmed = sound.isUserClip && sound.trimEnd > sound.trimStart;
      final start = Duration(milliseconds: (sound.trimStart * 1000).round());

      // Start paused so speed and the trim seek apply before the first sample.
      final handle = await SoLoud.instance.play(source, paused: true);
      // Stopped (or replaced) while the engine was starting the voice.
      if (_disposed || epoch != _epoch || _generation[sound.id] != gen) {
        _stopHandle(handle);
        return null;
      }
      if (trimmed) SoLoud.instance.seek(handle, start);
      if (speed != 1.0) SoLoud.instance.setRelativePlaySpeed(handle, speed);
      SoLoud.instance.setPause(handle, false);
      _voices[sound.id] = handle;

      final lengthMs = trimmed
          ? ((sound.trimEnd - sound.trimStart) * 1000).round()
          : SoLoud.instance.getLength(source).inMilliseconds;
      final duration = Duration(milliseconds: (lengthMs / speed).round());
      _endTimers[sound.id] = Timer(duration, () {
        if (_voices[sound.id] == handle) stop(sound.id);
      });
      return duration;
    } catch (_) {
      return null;
    }
  }

  /// Stops [id]'s voice, if it has one.
  void stop(String id) {
    _generation[id] = (_generation[id] ?? 0) + 1;
    _endTimers.remove(id)?.cancel();
    final handle = _voices.remove(id);
    if (handle != null) _stopHandle(handle);
  }

  /// Stops every voice this player started.
  void stopAll() {
    _epoch++;
    for (final id in _voices.keys.toList()) {
      stop(id);
    }
    for (final t in _endTimers.values) {
      t.cancel();
    }
    _endTimers.clear();
  }

  /// Stops everything; the player can't be used afterwards.
  void dispose() {
    stopAll();
    _disposed = true;
  }

  void _stopHandle(SoundHandle handle) {
    try {
      if (SoLoud.instance.getIsValidVoiceHandle(handle)) {
        unawaited(SoLoud.instance.stop(handle));
      }
    } catch (_) {}
  }
}

// ── Palette ─────────────────────────────────────────────────────────────────

/// Colours for performance mode. Dark is the stage look (near-black, violet
/// surfaces); light falls back to the app's [AppColors] tokens.
@immutable
class PerformancePalette {
  final bool dark;
  final Color bg;
  final Color surface;
  final Color border;
  final Color text;
  final Color textSecondary;
  final Color dotOff;
  final Color accent;
  final Color stopBg;
  final Color stopFg;

  const PerformancePalette._({
    required this.dark,
    required this.bg,
    required this.surface,
    required this.border,
    required this.text,
    required this.textSecondary,
    required this.dotOff,
    required this.accent,
    required this.stopBg,
    required this.stopFg,
  });

  factory PerformancePalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    if (theme.brightness == Brightness.dark) {
      return PerformancePalette._(
        dark: true,
        bg: const Color(0xFF07040F),
        surface: const Color(0xFF151028),
        border: const Color(0xFF2A2342),
        text: const Color(0xFFF4F1FF),
        textSecondary: const Color(0xFFB8B0D6),
        dotOff: const Color(0xFF3A3258),
        accent: accent,
        stopBg: const Color(0xFFFF6B81),
        stopFg: const Color(0xFF2A0710),
      );
    }
    final c = theme.extension<AppColors>() ?? AppColors.light;
    return PerformancePalette._(
      dark: false,
      bg: c.scaffoldBg,
      surface: c.surfaceCard,
      border: c.border,
      text: c.textPrimary,
      textSecondary: c.textSecondary,
      dotOff: c.textMuted,
      accent: accent,
      stopBg: const Color(0xFFD12C47),
      stopFg: Colors.white,
    );
  }
}

/// A pad's tint: the sound's custom colour, else its category colour (same
/// mapping as the soundboard / Speed Round).
Color performanceSoundColor(BuildContext context, SoundModel sound) {
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

TextStyle _labelStyle(BuildContext context, Color color, double size,
        [FontWeight weight = FontWeight.w700]) =>
    TextStyle(
      fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
      color: color,
      fontSize: size,
      fontWeight: weight,
      height: 1.15,
    );

// ── Pad ─────────────────────────────────────────────────────────────────────

/// One big pad. [progress] is null while idle; while playing it runs 0→1 and
/// drives the fill rising from the bottom.
class PerformancePad extends StatelessWidget {
  final SoundModel sound;
  final Animation<double>? progress;
  final VoidCallback onTap;

  const PerformancePad({
    super.key,
    required this.sound,
    required this.onTap,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    final color = performanceSoundColor(context, sound);
    final playing = progress != null;
    final radius = BorderRadius.circular(22);

    return Semantics(
      button: true,
      container: true,
      excludeSemantics: true,
      label: '${sound.name}, ${sound.category}${playing ? ', playing' : ''}',
      onTapHint: 'play',
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Down, not up: a pad has to fire the instant it's hit.
        onTapDown: (_) => onTap(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            // Opaque (tint pre-blended onto the background) so the glow
            // only shows around the pad, not through it.
            color: Color.alphaBlend(
                color.withValues(
                    alpha: playing ? 0.2 : (p.dark ? 0.08 : 0.12)),
                p.bg),
            borderRadius: radius,
            border: Border.all(
              color: playing
                  ? color
                  : color.withValues(alpha: p.dark ? 0.25 : 0.45),
              width: playing ? 2 : 1,
            ),
            boxShadow: playing
                ? [
                    BoxShadow(
                      color: color.withValues(alpha: p.dark ? 0.33 : 0.4),
                      blurRadius: 26,
                    ),
                  ]
                : const [],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (progress != null)
                  AnimatedBuilder(
                    animation: progress!,
                    builder: (context, _) => Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        widthFactor: 1,
                        heightFactor: progress!.value.clamp(0.0, 1.0),
                        child: ColoredBox(
                          color: color.withValues(alpha: p.dark ? 0.25 : 0.3),
                        ),
                      ),
                    ),
                  ),
                LayoutBuilder(builder: (context, box) {
                  final w = box.maxWidth;
                  final h = box.maxHeight;
                  final fontSize = (w / 8).clamp(11.0, 14.0);
                  final textH = fontSize * 1.15 * 2;
                  final gap = h < 110 ? 6.0 : 10.0;
                  final emoji = math
                      .min(w * 0.42, h - textH - gap - 16)
                      .clamp(16.0, 72.0);
                  return Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(sound.emoji,
                            maxLines: 1,
                            style: TextStyle(fontSize: emoji, height: 1)),
                        SizedBox(height: gap),
                        Text(
                          sound.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: _labelStyle(context, p.text, fontSize),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Header controls ─────────────────────────────────────────────────────────

/// 48×48 rounded-square control used in the header / rail.
class PerformanceIconButton extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool active;
  final bool enabled;

  const PerformanceIconButton({
    super.key,
    required this.child,
    this.onTap,
    this.active = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.38,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? p.accent.withValues(alpha: 0.18) : p.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? p.accent : p.border,
              width: active ? 1.5 : 1,
            ),
          ),
          child: IconTheme.merge(
            data: IconThemeData(color: active ? p.accent : p.text, size: 20),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Exit control that only fires after being held for [holdDuration]; a ring
/// fills around the X while held. A short tap calls [onHint] instead.
class PerformanceExitButton extends StatefulWidget {
  final VoidCallback onExit;
  final VoidCallback onHint;
  final Duration holdDuration;

  const PerformanceExitButton({
    super.key,
    required this.onExit,
    required this.onHint,
    this.holdDuration = const Duration(milliseconds: 600),
  });

  @override
  State<PerformanceExitButton> createState() => _PerformanceExitButtonState();
}

class _PerformanceExitButtonState extends State<PerformanceExitButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold =
      AnimationController(vsync: this, duration: widget.holdDuration)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed && !_fired) {
            _fired = true;
            Haptics.medium();
            widget.onExit();
          }
        });
  bool _fired = false;

  void _down() {
    _fired = false;
    _hold.forward(from: 0);
  }

  void _up() {
    if (_fired) return;
    _hold.stop();
    _hold.animateBack(0, duration: const Duration(milliseconds: 150));
    widget.onHint();
  }

  void _cancel() {
    if (_fired) return;
    _hold.stop();
    _hold.value = 0;
  }

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    return Semantics(
      button: true,
      container: true,
      excludeSemantics: true,
      label: 'Hold to exit performance mode',
      onTap: widget.onHint,
      onLongPress: widget.onExit,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _down(),
        onPointerUp: (_) => _up(),
        onPointerCancel: (_) => _cancel(),
        child: PerformanceIconButton(
          child: AnimatedBuilder(
            animation: _hold,
            builder: (context, child) => CustomPaint(
              size: const Size(34, 34),
              painter: _RingPainter(_hold.value, p.accent, p.border),
              child: child,
            ),
            child: const SizedBox(
              width: 34,
              height: 34,
              child: Icon(Icons.close_rounded, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color color;
  final Color track;

  _RingPainter(this.value, this.color, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    if (value <= 0) return;
    final rect = Offset.zero & size;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(1.5), 0, math.pi * 2, false, stroke..color = track);
    canvas.drawArc(rect.deflate(1.5), -math.pi / 2, math.pi * 2 * value, false,
        stroke..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.track != track;
}

/// The set picker: full-width name + chevron (portrait) or the set's emoji
/// over a chevron (landscape rail).
class PerformanceSetButton extends StatelessWidget {
  final PerformanceSet set;
  final VoidCallback onTap;
  final bool enabled;
  final bool compact;

  const PerformanceSetButton({
    super.key,
    required this.set,
    required this.onTap,
    this.enabled = true,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    final content = compact
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(set.emoji, style: const TextStyle(fontSize: 18, height: 1)),
              Icon(Icons.expand_more_rounded, size: 16, color: p.textSecondary),
            ],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  set.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _labelStyle(context, p.text, 15),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.expand_more_rounded, size: 20, color: p.text),
            ],
          );
    return Semantics(
      button: true,
      enabled: enabled,
      container: true,
      excludeSemantics: true,
      label: 'Sound set: ${set.name}',
      onTapHint: 'change set',
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.38,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: Container(
            height: 48,
            width: compact ? 48 : null,
            padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: p.border),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// Lock toggle; highlighted in the accent while locked.
class PerformanceLockButton extends StatelessWidget {
  final bool locked;
  final VoidCallback onTap;

  const PerformanceLockButton(
      {super.key, required this.locked, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        toggled: locked,
        container: true,
        excludeSemantics: true,
        label: 'Lock the board',
        onTap: onTap,
        child: PerformanceIconButton(
          active: locked,
          onTap: onTap,
          child: Icon(locked ? Icons.lock_rounded : Icons.lock_open_rounded),
        ),
      );
}

// ── Footer controls ─────────────────────────────────────────────────────────

/// Layer | Cut segmented switch. Horizontal in portrait, stacked in the
/// landscape rail.
class PerformanceModeSwitch extends StatelessWidget {
  final bool cut;
  final ValueChanged<bool> onChanged;
  final bool enabled;
  final Axis direction;

  const PerformanceModeSwitch({
    super.key,
    required this.cut,
    required this.onChanged,
    this.enabled = true,
    this.direction = Axis.horizontal,
  });

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    final horizontal = direction == Axis.horizontal;

    Widget option(String label, String hint, bool selected, bool value) =>
        Semantics(
          button: true,
          selected: selected,
          enabled: enabled,
          inMutuallyExclusiveGroup: true,
          container: true,
          excludeSemantics: true,
          label: label,
          hint: hint,
          onTap: enabled ? () => onChanged(value) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? () => onChanged(value) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: horizontal ? null : 44,
              padding: EdgeInsets.symmetric(horizontal: horizontal ? 14 : 0),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? p.accent.withValues(alpha: 0.2)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                label,
                style: _labelStyle(context, selected ? p.text : p.textSecondary,
                    13.5, selected ? FontWeight.w700 : FontWeight.w500),
              ),
            ),
          ),
        );

    final options = [
      option('Layer', 'New sounds play on top', !cut, false),
      option('Cut', 'A new sound stops the others', cut, true),
    ];
    return Semantics(
      container: true,
      label: 'When a new sound starts',
      child: Opacity(
        opacity: enabled ? 1 : 0.38,
        child: Container(
          height: horizontal ? 60 : null,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: p.border),
          ),
          child: Flex(
            direction: direction,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: options,
          ),
        ),
      ),
    );
  }
}

/// The big red panic button.
class PerformanceStopAllButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool vertical;

  const PerformanceStopAllButton(
      {super.key, required this.onTap, this.vertical = false});

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    final children = [
      Icon(Icons.stop_rounded, size: 24, color: p.stopFg),
      SizedBox(width: vertical ? 0 : 8, height: vertical ? 6 : 0),
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text('Stop all',
              maxLines: 1,
              style: _labelStyle(context, p.stopFg, vertical ? 16 : 17,
                  FontWeight.w800)),
        ),
      ),
    ];
    return Semantics(
      button: true,
      container: true,
      excludeSemantics: true,
      label: 'Stop all sounds',
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => onTap(),
        child: Container(
          height: vertical ? null : 60,
          decoration: BoxDecoration(
            color: p.stopBg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Flex(
            direction: vertical ? Axis.vertical : Axis.horizontal,
            mainAxisAlignment: MainAxisAlignment.center,
            children: children,
          ),
        ),
      ),
    );
  }
}

// ── Page dots ───────────────────────────────────────────────────────────────

class PerformancePageDots extends StatelessWidget {
  final int count;
  final int current;
  final Axis direction;

  const PerformancePageDots({
    super.key,
    required this.count,
    required this.current,
    this.direction = Axis.horizontal,
  });

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    final horizontal = direction == Axis.horizontal;
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: 'Page ${current + 1} of $count',
      child: Flex(
        direction: direction,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: 6, height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: horizontal ? (i == current ? 18 : 6) : 6,
              height: horizontal ? 6 : (i == current ? 18 : 6),
              decoration: BoxDecoration(
                color: i == current ? p.accent : p.dotOff,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Set picker sheet ────────────────────────────────────────────────────────

/// Bottom-sheet list of sets. Pops with the chosen set's id.
class PerformanceSetSheet extends StatelessWidget {
  final List<PerformanceSet> sets;
  final String currentId;

  const PerformanceSetSheet(
      {super.key, required this.sets, required this.currentId});

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    final maxH = MediaQuery.sizeOf(context).height * 0.8;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: p.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Semantics(
                header: true,
                child: Text('Choose a set',
                    style: _labelStyle(context, p.text, 18, FontWeight.w800)),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  for (final s in sets) _row(context, p, s),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, PerformancePalette p, PerformanceSet s) {
    final selected = s.id == currentId;
    final count = s.sounds.length;
    return Semantics(
      button: true,
      selected: selected,
      container: true,
      excludeSemantics: true,
      label: '${s.name}, $count ${count == 1 ? 'sound' : 'sounds'}',
      onTap: () => Navigator.of(context).pop(s.id),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).pop(s.id),
        child: Container(
          height: 64,
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected ? p.accent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: selected ? p.accent : Colors.transparent, width: 1.5),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p.dark ? p.bg : p.border.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(s.emoji,
                    style: const TextStyle(fontSize: 22, height: 1)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _labelStyle(context, p.text, 16)),
                    const SizedBox(height: 3),
                    Text('$count ${count == 1 ? 'sound' : 'sounds'}',
                        style: _labelStyle(
                            context, p.textSecondary, 13, FontWeight.w500)),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_rounded, color: p.accent, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Hint toast ──────────────────────────────────────────────────────────────

class PerformanceHintToast extends StatelessWidget {
  final String message;
  final bool visible;

  const PerformanceHintToast(
      {super.key, required this.message, required this.visible});

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: Semantics(
          liveRegion: visible,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: p.dark ? const Color(0xFF221B3A) : p.text,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.dark ? p.border : p.text),
              boxShadow: const [
                BoxShadow(color: Color(0x55000000), blurRadius: 16),
              ],
            ),
            child: Text(message,
                style: _labelStyle(
                    context, p.dark ? p.text : p.bg, 14, FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}
