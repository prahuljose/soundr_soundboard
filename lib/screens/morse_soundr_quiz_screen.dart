import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../theme/app_colors.dart';

enum _Phase { idle, playing, answering, result }

class MorseSoundrQuizScreen extends StatefulWidget {
  final AudioSource? dotSource;
  final AudioSource? dashSource;

  const MorseSoundrQuizScreen({super.key, this.dotSource, this.dashSource});

  @override
  State<MorseSoundrQuizScreen> createState() => _MorseSoundrQuizScreenState();
}

class _MorseSoundrQuizScreenState extends State<MorseSoundrQuizScreen> {
  static const _charToMorse = {
    'A': '.-',    'B': '-...', 'C': '-.-.', 'D': '-..',  'E': '.',
    'F': '..-.', 'G': '--.',  'H': '....', 'I': '..',   'J': '.---',
    'K': '-.-',  'L': '.-..', 'M': '--',   'N': '-.',   'O': '---',
    'P': '.--.', 'Q': '--.-', 'R': '.-.',  'S': '...',  'T': '-',
    'U': '..-',  'V': '...-', 'W': '.--',  'X': '-..-', 'Y': '-.--',
    'Z': '--..', '0': '-----','1': '.----','2': '..---','3': '...--',
    '4': '....-','5': '.....','6': '-....','7': '--...','8': '---..',
    '9': '----.',
  };

  static const _symbolGapMs = 80;
  static const _letterGapMs = 340;

  String _targetChar = 'A';
  int _score = 0;
  int _streak = 0;
  _Phase _phase = _Phase.idle;
  bool _isCorrect = false;
  int _playSession = 0;
  int _playCount = 0;
  final _answerController = TextEditingController();
  Duration _dotDuration = const Duration(milliseconds: 250);
  Duration _dashDuration = const Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _targetChar = _randomChar();
    if (widget.dotSource != null) {
      try {
        final d = SoLoud.instance.getLength(widget.dotSource!);
        if (d.inMilliseconds > 0) _dotDuration = d;
      } catch (_) {}
    }
    if (widget.dashSource != null) {
      try {
        final d = SoLoud.instance.getLength(widget.dashSource!);
        if (d.inMilliseconds > 0) _dashDuration = d;
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _playSession++;
    _answerController.dispose();
    super.dispose();
  }

  String _randomChar() {
    final keys = _charToMorse.keys.toList();
    return keys[Random().nextInt(keys.length)];
  }

  void _pickNextChar() {
    setState(() {
      _targetChar = _randomChar();
      _phase = _Phase.idle;
      _isCorrect = false;
      _playCount = 0;
      _answerController.clear();
    });
  }

  void _playSymbol(bool isDash) {
    final src = isDash ? widget.dashSource : widget.dotSource;
    if (src == null) return;
    try {
      SoLoud.instance.play(src);
    } catch (_) {}
  }

  Future<void> _playMorse() async {
    if (_phase == _Phase.playing) return;

    _playSession++;
    final session = _playSession;

    setState(() {
      _phase = _Phase.playing;
      _playCount++;
    });

    final morse = _charToMorse[_targetChar] ?? '';
    for (int i = 0; i < morse.length; i++) {
      if (_playSession != session || !mounted) return;

      final isDash = morse[i] == '-';
      _playSymbol(isDash);
      await Future.delayed(
        (isDash ? _dashDuration : _dotDuration) +
            const Duration(milliseconds: _symbolGapMs),
      );
    }

    if (_playSession != session || !mounted) return;
    await Future.delayed(const Duration(milliseconds: _letterGapMs));

    if (_playSession == session && mounted) {
      setState(() => _phase = _Phase.answering);
    }
  }

  void _submit() {
    final answer = _answerController.text.trim().toUpperCase();
    if (answer.isEmpty || _phase != _Phase.answering) return;

    final correct = answer == _targetChar;
    setState(() {
      _isCorrect = correct;
      if (correct) {
        _score++;
        _streak++;
      } else {
        _streak = 0;
      }
      _phase = _Phase.result;
    });
    HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final isResult = _phase == _Phase.result;
    final isPlaying = _phase == _Phase.playing;
    final isAnswering = _phase == _Phase.answering;
    final answer = _answerController.text.trim().toUpperCase();
    final morseDisplay = (_charToMorse[_targetChar] ?? '')
        .replaceAll('.', '·')
        .replaceAll('-', '−');

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Morse Soundr Quiz',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.emoji_events_rounded, color: Colors.amber, size: 22),
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
                  const SizedBox(width: 6),
                  Text(
                    '🔥$_streak',
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  AppBar().preferredSize.height -
                  MediaQuery.of(context).padding.top -
                  MediaQuery.of(context).padding.bottom,
            ),
            child: IntrinsicHeight(
              child: Column(
                children: [
            const Spacer(),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: isResult
                  ? Text(
                      _targetChar,
                      key: ValueKey('result-$_targetChar-$_score'),
                      style: TextStyle(
                        color: _isCorrect ? Colors.greenAccent : Colors.redAccent,
                        fontSize: 96,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    )
                  : Text(
                      '?',
                      key: const ValueKey('question'),
                      style: TextStyle(
                        color: c.textPrimary.withValues(alpha: 0.15),
                        fontSize: 96,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    ),
            ),

            const SizedBox(height: 8),

            AnimatedOpacity(
              opacity: isResult ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: Text(
                morseDisplay,
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 20,
                  letterSpacing: 3,
                ),
              ),
            ),

            const SizedBox(height: 40),

            GestureDetector(
              onTap: (_phase == _Phase.idle || _phase == _Phase.answering)
                  ? _playMorse
                  : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 96,
                height: 96,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isResult
                      ? c.surfaceCard
                      : isPlaying
                          ? accent.withValues(alpha: 0.12)
                          : accent.withValues(alpha: 0.14),
                  border: Border.all(
                    color: isResult
                        ? c.border
                        : accent.withValues(alpha: 0.50),
                    width: 1.5,
                  ),
                ),
                child: isPlaying
                    ? SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(accent),
                        ),
                      )
                    : Icon(
                        Icons.volume_up_rounded,
                        size: 40,
                        color: isResult ? c.iconSecondary : accent,
                      ),
              ),
            ),

            const SizedBox(height: 12),

            Text(
              isPlaying
                  ? 'Playing…'
                  : _phase == _Phase.idle
                      ? 'Tap to listen'
                      : isAnswering
                          ? (_playCount == 1
                              ? 'Tap to replay'
                              : 'Tap to replay (×$_playCount)')
                          : '',
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),

            const Spacer(),

            if (!isResult) ...[
              TextField(
                controller: _answerController,
                enabled: isAnswering,
                maxLength: 1,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9]')),
                ],
                textAlign: TextAlign.center,
                cursorColor: accent,
                onChanged: (_) => setState(() {}),
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: _phase == _Phase.idle ? 'Listen first' : '?',
                  hintStyle: TextStyle(
                    color: c.textMuted,
                    fontSize: _phase == _Phase.idle ? 14 : 32,
                  ),
                  filled: true,
                  fillColor: c.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: accent, width: 1.5),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: (isAnswering && answer.isNotEmpty) ? _submit : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (isAnswering && answer.isNotEmpty)
                        ? accent
                        : c.surfaceCard,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'Submit',
                    style: TextStyle(
                      color: (isAnswering && answer.isNotEmpty)
                          ? Colors.white
                          : c.textMuted,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],

            if (isResult) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                decoration: BoxDecoration(
                  color: _isCorrect
                      ? Colors.greenAccent.withValues(alpha: 0.10)
                      : Colors.redAccent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _isCorrect
                        ? Colors.greenAccent.withValues(alpha: 0.30)
                        : Colors.redAccent.withValues(alpha: 0.30),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isCorrect
                          ? '✓  Correct!'
                          : '✗  The answer was $_targetChar',
                      style: TextStyle(
                        color: _isCorrect ? Colors.greenAccent : Colors.redAccent,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (!_isCorrect && answer.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'You answered: $answer',
                        style: TextStyle(color: c.textMuted, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: _pickNextChar,
                child: Container(
                  width: double.infinity,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    'Next →',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 36),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
