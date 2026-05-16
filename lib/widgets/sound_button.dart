import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/sound_model.dart';

class SoundButton extends StatefulWidget {
  final SoundModel sound;
  final VoidCallback onTap;
  final double duration;
  final int stopSignal;
  final bool isFavorited;
  final VoidCallback onFavoriteToggle;
  final int playCount;
  // Incremented each time stop-on-tap fires. Used to reset all OTHER buttons.
  final int stopOthersSignal;
  // True for the button that just triggered the stop-on-tap play. Its own
  // animation should not be reset when stopOthersSignal changes.
  final bool excludeFromStopOthers;
  /// When non-empty, matching characters in the sound name are highlighted.
  final String highlightQuery;

  const SoundButton({
    super.key,
    required this.sound,
    required this.onTap,
    required this.duration,
    required this.stopSignal,
    required this.isFavorited,
    required this.onFavoriteToggle,
    this.playCount = 0,
    this.stopOthersSignal = 0,
    this.excludeFromStopOthers = false,
    this.highlightQuery = '',
  });

  @override
  State<SoundButton> createState() => _SoundButtonState();
}

class _SoundButtonState extends State<SoundButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pressController;
  late final Animation<double> _scale;

  bool _isPlaying = false;
  double _remaining = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _resetPlayback() {
    _timer?.cancel();
    setState(() { _isPlaying = false; _remaining = 0; });
  }

  @override
  void didUpdateWidget(covariant SoundButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stopSignal != widget.stopSignal) {
      _resetPlayback();
    } else if (oldWidget.stopOthersSignal != widget.stopOthersSignal &&
               !widget.excludeFromStopOthers) {
      _resetPlayback();
    }
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    _pressController.forward().then((_) => _pressController.reverse());
    widget.onTap();
    _startPlaybackVisuals();
  }

  void _startPlaybackVisuals() {
    _timer?.cancel();
    setState(() {
      _isPlaying = true;
      _remaining = widget.duration;
    });
    const tick = Duration(milliseconds: 16);
    _timer = Timer.periodic(tick, (t) {
      final next = _remaining - tick.inMilliseconds / 1000;
      if (next <= 0) {
        t.cancel();
        if (mounted) setState(() { _isPlaying = false; _remaining = 0; });
      } else {
        if (mounted) setState(() => _remaining = next);
      }
    });
  }

  /// Splits the sound name into normal + highlighted spans for search queries.
  List<TextSpan> _buildNameSpans() {
    const baseStyle = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: Colors.white,
      height: 1.2,
    );
    final q = widget.highlightQuery.trim();
    if (q.isEmpty) return [TextSpan(text: widget.sound.name, style: baseStyle)];

    final highlightStyle = baseStyle.copyWith(
      color: _accent,
      backgroundColor: _accent.withValues(alpha: 0.18),
    );

    final text = widget.sound.name;
    final lower = text.toLowerCase();
    final qLower = q.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final idx = lower.indexOf(qLower, start);
      if (idx == -1) {
        spans.add(TextSpan(text: text.substring(start), style: baseStyle));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx), style: baseStyle));
      }
      spans.add(TextSpan(
        text: text.substring(idx, idx + q.length),
        style: highlightStyle,
      ));
      start = idx + q.length;
    }
    return spans;
  }

  Color get _accent {
    if (widget.sound.customColor != null) {
      return Color(widget.sound.customColor!);
    }
    return switch (widget.sound.category) {
      'Instruments' => const Color(0xFFFAC775),
      'Memes'       => const Color(0xFFFF7272),
      'Reactions'   => const Color(0xFF64C8FF),
      'Effects'     => const Color(0xFF5DCAA5),
      'UI'          => const Color(0xFF9F8FF0),
      'Music'       => const Color(0xFFFF9FF0),
      'Animals'     => const Color(0xFF7DDB86),
      'Gaming'      => const Color(0xFF7B73FF),
      'Anime'       => const Color(0xFFFF9F7F),
      'Cartoons'    => const Color(0xFFFFD166),
      'My Clips'    => const Color(0xFF6C63FF),
      _             => const Color(0xFF888780),
    };
  }

  Color get _bg {
    if (widget.sound.customColor != null) {
      // Derive a very dark tint from the custom color
      return Color.lerp(Color(widget.sound.customColor!), Colors.black, 0.88)!;
    }
    return switch (widget.sound.category) {
      'Instruments' => const Color(0xFF221A08),
      'Memes'       => const Color(0xFF220E0E),
      'Reactions'   => const Color(0xFF081622),
      'Effects'     => const Color(0xFF081A12),
      'UI'          => const Color(0xFF120E28),
      'Music'       => const Color(0xFF220818),
      'Animals'     => const Color(0xFF081A0C),
      'Gaming'      => const Color(0xFF0E0820),
      'Anime'       => const Color(0xFF201000),
      'Cartoons'    => const Color(0xFF1A1600),
      'My Clips'    => const Color(0xFF12103A),
      _             => const Color(0xFF181818),
    };
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.duration > 0
        ? (1.0 - _remaining / widget.duration).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onTapDown: (_) => _handleTap(),
      child: ScaleTransition(
        scale: _scale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: _bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: _isPlaying
                  ? _accent.withValues(alpha: 0.75)
                  : _accent.withValues(alpha: 0.18),
              width: 1,
            ),
            boxShadow: _isPlaying
                ? [BoxShadow(color: _accent.withValues(alpha: 0.22), blurRadius: 18)]
                : [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Stack(
              children: [
                // Playback progress bar
                if (_isPlaying && widget.duration > 0)
                  Positioned(
                    bottom: 0, left: 0, right: 0,
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation(_accent.withValues(alpha: 0.5)),
                      minHeight: 3,
                    ),
                  ),
                // Content
                Padding(
                  padding: const EdgeInsets.fromLTRB(11, 11, 11, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.sound.emoji,
                              style: const TextStyle(fontSize: 26)),
                          const Spacer(),
                          GestureDetector(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              widget.onFavoriteToggle();
                            },
                            child: Padding(
                              padding: const EdgeInsets.only(top: 2, left: 4),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 200),
                                transitionBuilder: (child, anim) =>
                                    ScaleTransition(scale: anim, child: child),
                                child: Icon(
                                  widget.isFavorited
                                      ? Icons.star_rounded
                                      : Icons.star_outline_rounded,
                                  key: ValueKey(widget.isFavorited),
                                  size: 15,
                                  color: widget.isFavorited
                                      ? Colors.amber
                                      : Colors.white.withValues(alpha: 0.2),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      RichText(
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          children: _buildNameSpans(),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Text(
                            _isPlaying
                                ? '${_remaining.toStringAsFixed(1)}s'
                                : widget.duration > 0
                                    ? '${widget.duration.toStringAsFixed(1)}s'
                                    : '—',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: _isPlaying
                                  ? _accent
                                  : Colors.white.withValues(alpha: 0.28),
                            ),
                          ),
                          const Spacer(),
                          // Play count badge — shown once a sound has been played
                          if (widget.playCount > 0)
                            _PlayCountBadge(
                              count: widget.playCount,
                              color: _accent,
                            ),
                        ],
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

// ── Play count badge ──────────────────────────────────────────────────────────

class _PlayCountBadge extends StatelessWidget {
  final int count;
  final Color color;
  const _PlayCountBadge({required this.count, required this.color});

  String get _label {
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '$count';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        _label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color.withValues(alpha: 0.7),
          height: 1.3,
        ),
      ),
    );
  }
}
