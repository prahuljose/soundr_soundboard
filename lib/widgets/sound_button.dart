import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/sound_model.dart';

class SoundButton extends StatefulWidget {
  final SoundModel sound;
  final VoidCallback onTap;
  final double duration;
  final int stopSignal;

  const SoundButton({

    super.key,

    required this.sound,

    required this.onTap,

    required this.duration,
    required this.stopSignal,

  });

  @override
  State<SoundButton> createState() => _SoundButtonState();
}

class _SoundButtonState extends State<SoundButton>
    with TickerProviderStateMixin {
  late AnimationController _pressController;
  late Animation<double> _scale;

  late AnimationController _waveController;

  bool _isPlaying = false;
  double _remaining = 0;

  Timer? _timer;

  final Random _random = Random();
  //late final double duration;

  @override
  void initState() {
    super.initState();

    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );

    _scale = Tween<double>(
      begin: 1.0,
      end: 0.92,
    ).animate(
      CurvedAnimation(
        parent: _pressController,
        curve: Curves.easeOut,
      ),
    );

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat();
  }

  @override
  void dispose() {
    _pressController.dispose();
    _waveController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SoundButton oldWidget) {

    super.didUpdateWidget(oldWidget);

    if (oldWidget.stopSignal != widget.stopSignal) {

      _timer?.cancel();

      setState(() {

        _isPlaying = false;

        _remaining = 0;

      });

    }

  }

  void _handleTap() {
    HapticFeedback.lightImpact();

    _pressController.forward().then(
          (_) => _pressController.reverse(),
    );

    widget.onTap();

    _startPlaybackVisuals();
  }

  void _startPlaybackVisuals() {
    _timer?.cancel();

    setState(() {

      _isPlaying = true;

      _remaining = widget.duration;

    });

    const tick = Duration(milliseconds: 10);

    _timer = Timer.periodic(tick, (timer) {
      final next =
          _remaining - (tick.inMilliseconds / 1000);

      if (next <= 0) {
        timer.cancel();

        setState(() {
          _isPlaying = false;
          _remaining = 0;
        });
      } else {
        setState(() {
          _remaining = next;
        });
      }
    });
  }

  Color get _bgColor {
    switch (widget.sound.category) {
      case 'Drums':
        return const Color(0xFF2A1F0A);
      case 'Synth':
        return const Color(0xFF1A1535);
      case 'FX':
        return const Color(0xFF0A2018);
      default:
        return const Color(0xFF1A1A1A);
    }
  }

  Color get _accentColor {
    switch (widget.sound.category) {
      case 'Drums':
        return const Color(0xFFFAC775);
      case 'Synth':
        return const Color(0xFF9F8FF0);
      case 'FX':
        return const Color(0xFF5DCAA5);
      default:
        return const Color(0xFF888780);
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = Colors.greenAccent;

    return GestureDetector(
      onTapDown: (_) => _handleTap(),
      child: ScaleTransition(
        scale: _scale,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _bgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: (_isPlaying
                  ? activeColor
                  : _accentColor)
                  .withOpacity(0.5),
            ),
            boxShadow: _isPlaying
                ? [
              BoxShadow(
                color: activeColor.withOpacity(0.25),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ]
                : [],
          ),
          child: Column(
            crossAxisAlignment:
            CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment:
                MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.sound.emoji,
                    style: const TextStyle(
                      fontSize: 28,
                    ),
                  ),

                ],
              ),

              const Spacer(),

              Text(
                widget.sound.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),

              const SizedBox(height: 10),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  AnimatedBuilder(
                    animation: _waveController,
                    builder: (_, __) {
                      return Row(
                        children: List.generate(
                          6,
                              (index) {
                            final baseHeight =
                            _isPlaying
                                ? 4.0 +
                                _random.nextDouble() *
                                    9
                                : 4.0;

                            return AnimatedContainer(
                              duration: const Duration(
                                milliseconds: 180,
                              ),
                              margin:
                              const EdgeInsets.only(
                                right: 2,
                              ),
                              width: 3,
                              height: baseHeight,
                              decoration: BoxDecoration(
                                color: _isPlaying
                                    ? activeColor
                                    : Colors.white24,
                                borderRadius:
                                BorderRadius.circular(
                                  2,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                  Text(
                    '${(_isPlaying ? _remaining : widget.duration).toStringAsFixed(2)}s',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _isPlaying
                          ? activeColor
                          : Colors.white38,
                    ),
                  ),
                ],
              ),

            ],
          ),
        ),
      ),
    );
  }
}