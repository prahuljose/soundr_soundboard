import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/sound_model.dart';

class SoundButton extends StatefulWidget {
  final SoundModel sound;
  final VoidCallback onTap;

  const SoundButton({super.key, required this.sound, required this.onTap});

  @override
  State<SoundButton> createState() => _SoundButtonState();
}

class _SoundButtonState extends State<SoundButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    HapticFeedback.lightImpact();
    _controller.forward().then((_) => _controller.reverse());
    widget.onTap();
  }

  Color get _bgColor {
    switch (widget.sound.category) {
      case 'Drums': return const Color(0xFF2A1F0A);
      case 'Synth': return const Color(0xFF1A1535);
      case 'FX':    return const Color(0xFF0A2018);
      default:      return const Color(0xFF1A1A1A);
    }
  }

  Color get _accentColor {
    switch (widget.sound.category) {
      case 'Drums': return const Color(0xFFFAC775);
      case 'Synth': return const Color(0xFF9F8FF0);
      case 'FX':    return const Color(0xFF5DCAA5);
      default:      return const Color(0xFF888780);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _handleTap(), // onTapDown = lowest latency
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _bgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _accentColor.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.sound.emoji,
                  style: const TextStyle(fontSize: 28)),
              const SizedBox(height: 10),
              Text(
                widget.sound.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                height: 3,
                width: 24,
                decoration: BoxDecoration(
                  color: _accentColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}