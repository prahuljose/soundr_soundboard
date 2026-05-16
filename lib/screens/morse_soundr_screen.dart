import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../theme/app_colors.dart';

class MorseSoundrScreen extends StatefulWidget {
  final AudioSource? dotSource;
  final AudioSource? dashSource;

  const MorseSoundrScreen({super.key, this.dotSource, this.dashSource});

  @override
  State<MorseSoundrScreen> createState() => _MorseSoundrScreenState();
}

class _MorseSoundrScreenState extends State<MorseSoundrScreen> {
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

  final _textController  = TextEditingController();
  final _chipController  = ScrollController();

  bool   _isPlaying        = false;
  int    _currentLetterIdx = -1;
  int    _currentSymbolIdx = -1;
  double _speed            = 1.0; // 0.5 – 2.0×
  bool   _practiceMode     = false;
  int    _playSession      = 0;   // incremented to cancel in-flight playback

  // Actual sound durations — read from SoLoud after the sources are loaded.
  Duration _dotDuration  = const Duration(milliseconds: 250);
  Duration _dashDuration = const Duration(milliseconds: 500);

  // Gap durations at 1× speed (scaled by _speed at runtime).
  static const _baseSymbolGapMs = 80;   // between symbols in the same letter
  static const _baseLetterGapMs = 340;  // between letters
  static const _baseWordGapMs   = 720;  // for a space character

  Duration get _symbolGap => Duration(milliseconds: (_baseSymbolGapMs / _speed).round());
  Duration get _letterGap => Duration(milliseconds: (_baseLetterGapMs / _speed * (_practiceMode ? 3.5 : 1.0)).round());
  Duration get _wordGap   => Duration(milliseconds: (_baseWordGapMs   / _speed * (_practiceMode ? 2.5 : 1.0)).round());

  String get _text => _textController.text.toUpperCase();

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _textController.addListener(() => setState(() {}));

    // Read real sound durations from the already-loaded sources.
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
    _playSession++; // cancel any in-flight Future chain
    _textController.dispose();
    _chipController.dispose();
    super.dispose();
  }

  // ── Playback ────────────────────────────────────────────────────────────────

  void _playSymbol(bool isDash) {
    final src = isDash ? widget.dashSource : widget.dotSource;
    if (src == null) return;
    try { SoLoud.instance.play(src); } catch (_) {}
  }

  Future<void> _startPlayback() async {
    final text = _text;
    if (text.isEmpty) return;

    _playSession++;
    final session = _playSession;

    setState(() {
      _isPlaying        = true;
      _currentLetterIdx = 0;
      _currentSymbolIdx = -1;
    });

    for (int i = 0; i < text.length; i++) {
      if (_playSession != session || !mounted) break;

      final ch = text[i];
      setState(() { _currentLetterIdx = i; _currentSymbolIdx = -1; });

      // Scroll the chip strip to keep the active letter visible.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_chipController.hasClients) {
          final offset = (i * 46.0).clamp(
              0.0, _chipController.position.maxScrollExtent);
          _chipController.animateTo(
            offset,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });

      // Space → word gap then continue.
      if (ch == ' ') {
        await Future.delayed(_wordGap);
        continue;
      }

      final morse = _charToMorse[ch];
      if (morse == null) {
        await Future.delayed(_letterGap);
        continue;
      }

      // Play each symbol in this letter.
      for (int j = 0; j < morse.length; j++) {
        if (_playSession != session || !mounted) break;

        setState(() => _currentSymbolIdx = j);
        final isDash = morse[j] == '-';
        _playSymbol(isDash);
        HapticFeedback.selectionClick();

        // Wait for the sound to finish + inter-symbol gap.
        await Future.delayed(
            (isDash ? _dashDuration : _dotDuration) + _symbolGap);
      }

      if (_playSession != session || !mounted) break;
      setState(() => _currentSymbolIdx = -1);
      await Future.delayed(_letterGap);
    }

    if (mounted && _playSession == session) {
      setState(() {
        _isPlaying        = false;
        _currentLetterIdx = -1;
        _currentSymbolIdx = -1;
      });
    }
  }

  void _stopPlayback() {
    _playSession++;
    setState(() {
      _isPlaying        = false;
      _currentLetterIdx = -1;
      _currentSymbolIdx = -1;
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final text = _text;
    final currentChar = (_currentLetterIdx >= 0 && _currentLetterIdx < text.length)
        ? text[_currentLetterIdx]
        : null;
    final currentMorse =
        (currentChar != null && currentChar != ' ') ? _charToMorse[currentChar] : null;

    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(
          'Morse Code Soundr',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Input row ──────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  enabled: !_isPlaying,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9 ]')),
                  ],
                  cursorColor: accent,
                  decoration: InputDecoration(
                    hintText: 'Type a message…',
                    filled: true,
                    fillColor: c.surfaceCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide(
                          color: accent, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              if (text.isNotEmpty && !_isPlaying) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.clear_rounded, color: c.iconSecondary),
                  onPressed: () => _textController.clear(),
                ),
              ],
            ]),
          ),

          const SizedBox(height: 16),

          // ── Letter chip strip ──────────────────────────────────────────────
          if (text.isNotEmpty)
            SizedBox(
              height: 64,
              child: ListView.separated(
                controller: _chipController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: text.length,
                separatorBuilder: (context, i) => const SizedBox(width: 6),
                itemBuilder: (_, i) {
                  final ch = text[i];
                  if (ch == ' ') return const SizedBox(width: 20);

                  final isActive = i == _currentLetterIdx;
                  final isDone   = _isPlaying && i < _currentLetterIdx;
                  final morseDisplay = (_charToMorse[ch] ?? '')
                      .replaceAll('.', '·')
                      .replaceAll('-', '−');

                  final letterColor = isActive
                      ? Colors.white
                      : isDone
                          ? accent.withValues(alpha: 0.5)
                          : c.textSecondary;
                  final morseColor = isActive
                      ? Colors.white.withValues(alpha: 0.85)
                      : isDone
                          ? accent.withValues(alpha: 0.4)
                          : accent.withValues(alpha: 0.7);

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    constraints: const BoxConstraints(minWidth: 44),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isActive
                          ? accent
                          : isDone
                              ? accent.withValues(alpha: 0.12)
                              : c.surfaceCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isActive
                            ? accent
                            : c.border,
                      ),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: accent
                                    .withValues(alpha: 0.40),
                                blurRadius: 14,
                              )
                            ]
                          : [],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          ch,
                          style: TextStyle(
                            color: letterColor,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            height: 1.0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          morseDisplay,
                          style: TextStyle(
                            color: morseColor,
                            fontSize: 10,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w500,
                            height: 1.0,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

          // ── Active letter + morse symbols ──────────────────────────────────
          Expanded(
            child: Center(
              child: currentMorse != null
                  // FittedBox scales the column down uniformly when the
                  // available height is small (e.g. keyboard open).
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Current letter, large
                            Text(
                              currentChar!,
                              style: TextStyle(
                                color: c.textPrimary,
                                fontSize: 72,
                                fontWeight: FontWeight.w700,
                                height: 1.0,
                              ),
                            ),
                            const SizedBox(height: 20),
                            // Symbol chips — Row so FittedBox can scale as one unit
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(currentMorse.length, (j) {
                                final isDash   = currentMorse[j] == '-';
                                final isActive = j == _currentSymbolIdx;
                                return Padding(
                                  padding: EdgeInsets.only(left: j > 0 ? 10 : 0),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 80),
                                    width: 52,
                                    height: 52,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isActive
                                          ? accent
                                          : c.surfaceCard,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isActive
                                            ? accent
                                            : accent
                                                .withValues(alpha: 0.22),
                                      ),
                                      boxShadow: isActive
                                          ? [
                                              BoxShadow(
                                                color: accent
                                                    .withValues(alpha: 0.38),
                                                blurRadius: 16,
                                              )
                                            ]
                                          : [],
                                    ),
                                    child: Text(
                                      isDash ? '−' : '·',
                                      style: TextStyle(
                                        color: isActive
                                            ? Colors.white
                                            : accent,
                                        fontSize: 26,
                                        fontWeight: FontWeight.w300,
                                        height: 1.0,
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ],
                        ),
                      ),
                    )
                  : Text(
                      text.isEmpty ? 'Type a message above\nthen tap Play' : '',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.textMuted,
                        fontSize: 15,
                        height: 1.7,
                      ),
                    ),
            ),
          ),

          // ── Practice mode toggle ───────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Row(children: [
              Icon(
                Icons.school_rounded,
                size: 18,
                color: _practiceMode ? accent : c.iconSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Practice mode',
                        style: TextStyle(
                          color: _practiceMode ? c.textPrimary : c.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        )),
                    Text('Longer pauses between letters',
                        style: TextStyle(color: c.textMuted, fontSize: 10)),
                  ],
                ),
              ),
              Switch(
                value: _practiceMode,
                onChanged: _isPlaying ? null : (v) => setState(() => _practiceMode = v),
                activeThumbColor: accent,
                activeTrackColor: accent.withValues(alpha: 0.5),
              ),
            ]),
          ),

          // ── Speed slider ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
            child: Row(children: [
              Text('Slow',
                  style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: accent,
                    inactiveTrackColor: c.border,
                    thumbColor: accent,
                    overlayColor:
                        accent.withValues(alpha: 0.12),
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14),
                  ),
                  child: Slider(
                    value: _speed,
                    min: 0.5,
                    max: 2.0,
                    divisions: 6,
                    onChanged: _isPlaying
                        ? null
                        : (v) => setState(() => _speed = v),
                  ),
                ),
              ),
              Text('Fast',
                  style: TextStyle(
                      color: c.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500)),
            ]),
          ),

          // ── Play / Stop button ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: text.isEmpty
                      ? c.surfaceCard
                      : _isPlaying
                          ? const Color(0xFF2A0A0A)
                          : accent,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: _isPlaying
                        ? Colors.redAccent.withValues(alpha: 0.55)
                        : Colors.transparent,
                  ),
                  boxShadow: (!_isPlaying && text.isNotEmpty)
                      ? [
                          BoxShadow(
                            color:
                                accent.withValues(alpha: 0.30),
                            blurRadius: 20,
                          )
                        ]
                      : [],
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: text.isEmpty
                        ? null
                        : _isPlaying
                            ? _stopPlayback
                            : _startPlayback,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isPlaying
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          color: text.isEmpty ? c.textMuted : Colors.white,
                          size: 28,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isPlaying ? 'Stop' : 'Play',
                          style: TextStyle(
                            color: text.isEmpty ? c.textMuted : Colors.white,
                            fontSize: 16,
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
        ],
      ),
    );
  }
}
