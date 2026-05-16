import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../theme/app_colors.dart';

enum _Phase { waiting, tapping, result }

class MorseTapperQuizScreen extends StatefulWidget {
  final AudioSource? dotSource;
  final AudioSource? dashSource;
  const MorseTapperQuizScreen({super.key, this.dotSource, this.dashSource});

  @override
  State<MorseTapperQuizScreen> createState() => _MorseTapperQuizScreenState();
}

class _MorseTapperQuizScreenState extends State<MorseTapperQuizScreen> {
  static const _morseMap = {
    'A': '.-',   'B': '-...', 'C': '-.-.', 'D': '-..',  'E': '.',
    'F': '..-.', 'G': '--.',  'H': '....', 'I': '..',   'J': '.---',
    'K': '-.-',  'L': '.-..', 'M': '--',   'N': '-.',   'O': '---',
    'P': '.--.', 'Q': '--.-', 'R': '.-.',  'S': '...',  'T': '-',
    'U': '..-',  'V': '...-', 'W': '.--',  'X': '-..-', 'Y': '-.--',
    'Z': '--..',
    '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.',
  };

  static final _chars = _morseMap.keys.toList();
  final _rng = Random();

  String _targetChar = '';
  String _currentMorse = '';
  int _score = 0;
  int _streak = 0;
  _Phase _phase = _Phase.waiting;
  bool _isCorrect = false;
  bool _showHint = false;
  bool _isMuted = false;

  bool _isPressed = false;
  bool _isDashMode = false;
  DateTime? _pressStart;

  Timer? _letterTimer;
  Timer? _dashModeTimer;

  static const _dotThreshold = Duration(milliseconds: 260);
  static const _letterGap = Duration(milliseconds: 1000);

  @override
  void initState() {
    super.initState();
    _pickNextChar();
  }

  void _pickNextChar() {
    _letterTimer?.cancel();
    _dashModeTimer?.cancel();
    final next = _chars[_rng.nextInt(_chars.length)];
    setState(() {
      _targetChar = next;
      _currentMorse = '';
      _phase = _Phase.waiting;
      _isPressed = false;
      _isDashMode = false;
      _showHint = false;
    });
  }

  void _onPressStart() {
    if (_phase == _Phase.result) return;
    _letterTimer?.cancel();
    _dashModeTimer?.cancel();
    _dashModeTimer = Timer(_dotThreshold, () {
      if (mounted) {
        setState(() => _isDashMode = true);
        HapticFeedback.selectionClick();
      }
    });
    _pressStart = DateTime.now();
    setState(() {
      _isPressed = true;
      _isDashMode = false;
      if (_phase == _Phase.waiting) _phase = _Phase.tapping;
    });
    HapticFeedback.lightImpact();
  }

  void _onPressEnd() {
    _dashModeTimer?.cancel();
    if (_pressStart == null) return;
    final held = DateTime.now().difference(_pressStart!);
    final isDash = held >= _dotThreshold;
    _pressStart = null;
    setState(() {
      _isPressed = false;
      _isDashMode = false;
    });
    _addSymbol(isDash);
  }

  void _onPressCancel() {
    _dashModeTimer?.cancel();
    setState(() {
      _isPressed = false;
      _isDashMode = false;
    });
  }

  void _addSymbol(bool isDash) {
    final symbol = isDash ? '-' : '.';
    setState(() => _currentMorse += symbol);
    _playSymbol(isDash);
    HapticFeedback.selectionClick();

    _letterTimer?.cancel();
    _letterTimer = Timer(_letterGap, _commit);
  }

  void _commit() {
    if (_currentMorse.isEmpty) return;
    final correct = _morseMap[_targetChar] == _currentMorse;
    setState(() {
      _isCorrect = correct;
      _phase = _Phase.result;
      if (correct) {
        _score++;
        _streak++;
      } else {
        _streak = 0;
      }
    });
    HapticFeedback.mediumImpact();
  }

  void _playSymbol(bool isDash) {
    if (_isMuted) return;
    final source = isDash ? widget.dashSource : widget.dotSource;
    if (source == null) return;
    try {
      SoLoud.instance.play(source);
    } catch (_) {}
  }

  String get _displayMorse => _currentMorse.replaceAll('.', '·').replaceAll('-', '−');

  String _toDisplay(String morse) => morse.replaceAll('.', '·').replaceAll('-', '−');

  Color _targetColor(AppColors c) {
    if (_phase != _Phase.result) return c.textPrimary;
    return _isCorrect ? const Color(0xFF4CAF50) : const Color(0xFFEF5350);
  }

  @override
  void dispose() {
    _letterTimer?.cancel();
    _dashModeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Morse Tapper Quiz',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              color: _isMuted ? c.textMuted : c.textSecondary,
              size: 22,
            ),
            tooltip: _isMuted ? 'Unmute' : 'Mute',
            onPressed: () => setState(() => _isMuted = !_isMuted),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.emoji_events_rounded, color: Colors.amber, size: 20),
              const SizedBox(width: 4),
              Text(
                '$_score',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_streak >= 2) ...[
                const SizedBox(width: 8),
                Text(
                  '🔥$_streak',
                  style: const TextStyle(fontSize: 15),
                ),
              ],
              const SizedBox(width: 16),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          const Spacer(),
          Text(
            _targetChar,
            style: TextStyle(
              color: _targetColor(c),
              fontSize: 96,
              fontWeight: FontWeight.w700,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => setState(() => _showHint = !_showHint),
            child: Text(
              _showHint ? 'Hide hint' : 'Show hint',
              style: TextStyle(
                color: accent,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 6),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _showHint ? 1.0 : 0.0,
            child: Text(
              _toDisplay(_morseMap[_targetChar] ?? ''),
              style: TextStyle(
                color: c.textMuted,
                fontSize: 22,
                letterSpacing: 4,
              ),
            ),
          ),
          const SizedBox(height: 32),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 150),
            opacity: _currentMorse.isEmpty ? 0.0 : 1.0,
            child: Text(
              _displayMorse.isEmpty ? ' ' : _displayMorse,
              style: TextStyle(
                color: accent,
                fontSize: 28,
                letterSpacing: 8,
              ),
            ),
          ),
          const SizedBox(height: 8),
          AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: _phase == _Phase.result ? 1.0 : 0.0,
            child: Column(
              children: [
                Text(
                  _isCorrect ? '✓ Correct!' : '✗ Incorrect',
                  style: TextStyle(
                    color: _isCorrect
                        ? const Color(0xFF4CAF50)
                        : const Color(0xFFEF5350),
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (!_isCorrect && _phase == _Phase.result)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Correct: ',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                        Text(
                          _toDisplay(_morseMap[_targetChar] ?? ''),
                          style: TextStyle(
                            color: accent,
                            fontSize: 16,
                            letterSpacing: 4,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Spacer(),
          if (_phase != _Phase.result)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: GestureDetector(
                onTapDown: (_) => _onPressStart(),
                onTapUp: (_) => _onPressEnd(),
                onTapCancel: _onPressCancel,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  height: 120,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _isDashMode
                        ? accent.withValues(alpha: 0.18)
                        : _isPressed
                            ? accent.withValues(alpha: 0.12)
                            : c.surfaceCard,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: _isPressed
                          ? accent
                          : accent.withValues(alpha: 0.22),
                      width: 1.5,
                    ),
                    boxShadow: _isPressed
                        ? [
                            BoxShadow(
                              color: accent.withValues(alpha: 0.12),
                              blurRadius: 12,
                            ),
                          ]
                        : [],
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 100),
                        child: _isPressed
                            ? Text(
                                _isDashMode ? '−' : '·',
                                key: ValueKey(_isDashMode),
                                style: TextStyle(
                                  color: accent,
                                  fontSize: 40,
                                  fontWeight: FontWeight.w200,
                                ),
                              )
                            : Icon(
                                Icons.touch_app_rounded,
                                key: const ValueKey('idle'),
                                size: 30,
                                color: c.iconSecondary,
                              ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isPressed
                            ? (_isDashMode ? 'dash  −' : 'dot  ·')
                            : 'tap for ·    hold for −',
                        style: TextStyle(
                          color: _isPressed
                              ? accent.withValues(alpha: 0.65)
                              : c.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: SizedBox(
                height: 52,
                width: double.infinity,
                child: TextButton(
                  onPressed: _pickNextChar,
                  style: TextButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Next →',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
