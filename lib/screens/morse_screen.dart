import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../theme/app_colors.dart';

class MorseScreen extends StatefulWidget {
  final AudioSource? dotSource;
  final AudioSource? dashSource;

  const MorseScreen({super.key, this.dotSource, this.dashSource});

  @override
  State<MorseScreen> createState() => _MorseScreenState();
}

class _MorseScreenState extends State<MorseScreen> {
  // Internal lookup keys use '.' and '-'; display uses '·' and '−'
  static const _morseToChar = {
    '.-': 'A',    '-...': 'B',  '-.-.': 'C',  '-..': 'D',   '.': 'E',
    '..-.': 'F',  '--.': 'G',   '....': 'H',  '..': 'I',    '.---': 'J',
    '-.-': 'K',   '.-..': 'L',  '--': 'M',    '-.': 'N',    '---': 'O',
    '.--.': 'P',  '--.-': 'Q',  '.-.': 'R',   '...': 'S',   '-': 'T',
    '..-': 'U',   '...-': 'V',  '.--': 'W',   '-..-': 'X',  '-.--': 'Y',
    '--..': 'Z',  '-----': '0', '.----': '1', '..---': '2', '...--': '3',
    '....-': '4', '.....': '5', '-....': '6', '--...': '7', '---..': '8',
    '----.': '9',
  };

  String _currentMorse = ''; // current letter being keyed in (. and -)
  String _decodedText  = ''; // full decoded output

  Timer? _letterTimer;
  Timer? _wordTimer;
  Timer? _dashModeTimer;
  DateTime? _pressStart;
  bool _isPressed   = false;
  bool _isDashMode  = false; // true once press exceeds dot threshold

  // Adjustable timing values (milliseconds)
  int _dotThresholdMs = 260;  // how long a press must be held to count as a dash
  int _letterGapMs    = 800;  // silence before the current symbols commit to a letter
  int _wordGapMs      = 1800; // silence after a letter before a space is inserted

  Duration get _dotThreshold => Duration(milliseconds: _dotThresholdMs);
  Duration get _letterGap    => Duration(milliseconds: _letterGapMs);
  Duration get _wordGap      => Duration(milliseconds: _wordGapMs);

  // ── Press handling ──────────────────────────────────────────────────────────

  void _onPressStart() {
    _pressStart = DateTime.now();
    _letterTimer?.cancel();
    _wordTimer?.cancel();
    _dashModeTimer?.cancel();
    _dashModeTimer = Timer(_dotThreshold, () {
      if (mounted) {
        setState(() => _isDashMode = true);
        HapticFeedback.selectionClick();
      }
    });
    setState(() { _isPressed = true; _isDashMode = false; });
    HapticFeedback.lightImpact();
  }

  void _onPressEnd() {
    _dashModeTimer?.cancel();
    if (_pressStart == null) return;
    final held   = DateTime.now().difference(_pressStart!);
    final isDash = held >= _dotThreshold;
    _pressStart  = null;
    setState(() { _isPressed = false; _isDashMode = false; });
    _addSymbol(isDash);
  }

  void _onPressCancel() {
    _dashModeTimer?.cancel();
    setState(() { _isPressed = false; _isDashMode = false; });
  }

  // ── Symbol logic ────────────────────────────────────────────────────────────

  void _addSymbol(bool isDash) {
    final symbol = isDash ? '-' : '.';
    setState(() => _currentMorse += symbol);
    _playSymbol(isDash);
    HapticFeedback.selectionClick();

    _letterTimer?.cancel();
    _letterTimer = Timer(_letterGap, _commitLetter);
  }

  void _commitLetter() {
    if (_currentMorse.isEmpty) return;
    final letter = _morseToChar[_currentMorse] ?? '?';
    setState(() { _decodedText += letter; _currentMorse = ''; });
    HapticFeedback.mediumImpact();

    _wordTimer?.cancel();
    _wordTimer = Timer(_wordGap, _commitSpace);
  }

  void _commitSpace() {
    if (_decodedText.isNotEmpty && !_decodedText.endsWith(' ')) {
      setState(() => _decodedText += ' ');
    }
  }

  void _playSymbol(bool isDash) {
    final source = isDash ? widget.dashSource : widget.dotSource;
    if (source == null) return;
    try { SoLoud.instance.play(source); } catch (_) {}
  }

  void _deleteLast() {
    _letterTimer?.cancel();
    _wordTimer?.cancel();
    if (_currentMorse.isNotEmpty) {
      setState(() => _currentMorse = _currentMorse.substring(0, _currentMorse.length - 1));
    } else if (_decodedText.isNotEmpty) {
      setState(() => _decodedText = _decodedText.substring(0, _decodedText.length - 1));
    }
    HapticFeedback.selectionClick();
  }

  void _clear() {
    _letterTimer?.cancel();
    _wordTimer?.cancel();
    setState(() { _currentMorse = ''; _decodedText = ''; });
    HapticFeedback.mediumImpact();
  }

  /// Display version of _currentMorse (· and −).
  String get _displayMorse =>
      _currentMorse.replaceAll('.', '·').replaceAll('-', '−');

  // ── Timing settings sheet ───────────────────────────────────────────────────

  void _showTimingSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final sc = Theme.of(ctx).extension<AppColors>()!;
          void update(VoidCallback fn) {
            setSheet(fn);
            setState(fn);
          }

          Widget slider({
            required String label,
            required String sublabel,
            required int value,
            required int min,
            required int max,
            required int divisions,
            required ValueChanged<int> onChanged,
          }) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: TextStyle(
                            color: sc.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          )),
                          const SizedBox(height: 2),
                          Text(sublabel, style: TextStyle(
                            color: sc.textMuted,
                            fontSize: 11,
                          )),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF6C63FF).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${value}ms',
                        style: const TextStyle(
                          color: Color(0xFF6C63FF),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: const Color(0xFF6C63FF),
                      inactiveTrackColor: sc.textPrimary.withValues(alpha: 0.08),
                      thumbColor: const Color(0xFF6C63FF),
                      overlayColor:
                          const Color(0xFF6C63FF).withValues(alpha: 0.12),
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14),
                    ),
                    child: Slider(
                      value: value.toDouble(),
                      min: min.toDouble(),
                      max: max.toDouble(),
                      divisions: divisions,
                      onChanged: (v) => onChanged(v.round()),
                    ),
                  ),
                ],
              ),
            );
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36, height: 4,
                      decoration: BoxDecoration(
                        color: sc.handleBar,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(children: [
                    const Icon(Icons.tune_rounded,
                        color: Color(0xFF6C63FF), size: 20),
                    const SizedBox(width: 10),
                    Text('Timing Settings', style: TextStyle(
                      color: sc.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    )),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => update(() {
                        _dotThresholdMs = 260;
                        _letterGapMs    = 800;
                        _wordGapMs      = 1800;
                      }),
                      child: Text('Reset', style: TextStyle(
                        color: sc.textMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      )),
                    ),
                  ]),
                  const SizedBox(height: 24),

                  slider(
                    label: 'Dash hold duration',
                    sublabel: 'How long to hold before it counts as a dash',
                    value: _dotThresholdMs,
                    min: 100, max: 500, divisions: 8,
                    onChanged: (v) => update(() => _dotThresholdMs = v),
                  ),
                  slider(
                    label: 'Letter gap',
                    sublabel: 'Silence before symbols commit to a letter',
                    value: _letterGapMs,
                    min: 300, max: 2000, divisions: 17,
                    onChanged: (v) => update(() => _letterGapMs = v),
                  ),
                  slider(
                    label: 'Word gap',
                    sublabel: 'Silence after a letter before a space is added',
                    value: _wordGapMs,
                    min: 800, max: 4000, divisions: 16,
                    onChanged: (v) => update(() => _wordGapMs = v),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _letterTimer?.cancel();
    _wordTimer?.cancel();
    _dashModeTimer?.cancel();
    super.dispose();
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasContent = _decodedText.isNotEmpty || _currentMorse.isNotEmpty;

    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Morse Code Tapper',
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (hasContent) ...[
            IconButton(
              icon: Icon(Icons.backspace_outlined, size: 20, color: c.iconSecondary),
              onPressed: _deleteLast,
            ),
            IconButton(
              icon: Icon(Icons.clear_rounded, size: 20, color: c.iconSecondary),
              onPressed: _clear,
            ),
          ],
          IconButton(
            icon: Icon(Icons.tune_rounded, size: 22, color: c.iconSecondary),
            tooltip: 'Timing settings',
            onPressed: _showTimingSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Decoded output ─────────────────────────────────────────────────
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Decoded letters
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 120),
                      child: Text(
                        _decodedText.isEmpty && _currentMorse.isEmpty
                            ? '—'
                            : _decodedText,
                        key: ValueKey(_decodedText),
                        style: TextStyle(
                          color: _decodedText.isEmpty
                              ? c.textPrimary.withValues(alpha: 0.08)
                              : c.textPrimary,
                          fontSize: 52,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 6,
                          height: 1.1,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Current symbols being entered
                    AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: _currentMorse.isEmpty ? 0.0 : 1.0,
                      child: Text(
                        _displayMorse,
                        style: const TextStyle(
                          color: Color(0xFF6C63FF),
                          fontSize: 30,
                          letterSpacing: 10,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Collapsible reference ──────────────────────────────────────────
          const _MorseReference(),
          const SizedBox(height: 20),

          // ── Big tap button ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 36),
            child: GestureDetector(
              onTapDown:  (_) => _onPressStart(),
              onTapUp:    (_) => _onPressEnd(),
              onTapCancel: _onPressCancel,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                height: 160,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: _isDashMode
                      ? const Color(0xFF1C1650)
                      : _isPressed
                          ? const Color(0xFF211E52)
                          : const Color(0xFF141420),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: _isPressed
                        ? const Color(0xFF6C63FF)
                        : const Color(0xFF6C63FF).withValues(alpha: 0.22),
                    width: 1.5,
                  ),
                  boxShadow: _isPressed
                      ? [
                          BoxShadow(
                            color: const Color(0xFF6C63FF).withValues(alpha: 0.28),
                            blurRadius: 28,
                          )
                        ]
                      : [],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Live symbol preview while held
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 100),
                      child: _isPressed
                          ? Text(
                              _isDashMode ? '−' : '·',
                              key: ValueKey(_isDashMode),
                              style: const TextStyle(
                                color: Color(0xFF6C63FF),
                                fontSize: 44,
                                fontWeight: FontWeight.w200,
                              ),
                            )
                          : Icon(
                              Icons.touch_app_rounded,
                              key: const ValueKey('idle'),
                              size: 36,
                              color: c.textPrimary.withValues(alpha: 0.10),
                            ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _isPressed
                          ? (_isDashMode ? 'dash  −' : 'dot  ·')
                          : 'tap for ·    hold for −',
                      style: TextStyle(
                        color: _isPressed
                            ? const Color(0xFF6C63FF).withValues(alpha: 0.65)
                            : c.textPrimary.withValues(alpha: 0.18),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Collapsible morse reference ───────────────────────────────────────────────

class _MorseReference extends StatefulWidget {
  const _MorseReference();

  @override
  State<_MorseReference> createState() => _MorseReferenceState();
}

class _MorseReferenceState extends State<_MorseReference> {
  bool _expanded = false;

  static const _entries = [
    ('A', '·−'),    ('B', '−···'),  ('C', '−·−·'),  ('D', '−··'),
    ('E', '·'),     ('F', '··−·'),  ('G', '−−·'),   ('H', '····'),
    ('I', '··'),    ('J', '·−−−'),  ('K', '−·−'),   ('L', '·−··'),
    ('M', '−−'),    ('N', '−·'),    ('O', '−−−'),   ('P', '·−−·'),
    ('Q', '−−·−'),  ('R', '·−·'),   ('S', '···'),   ('T', '−'),
    ('U', '··−'),   ('V', '···−'),  ('W', '·−−'),   ('X', '−··−'),
    ('Y', '−·−−'),  ('Z', '−−··'),
    ('0', '−−−−−'), ('1', '·−−−−'), ('2', '··−−−'), ('3', '···−−'),
    ('4', '····−'), ('5', '·····'), ('6', '−····'),  ('7', '−−···'),
    ('8', '−−−··'), ('9', '−−−−·'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Builder(builder: (ctx) {
          final rc = Theme.of(ctx).extension<AppColors>()!;
          return GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(children: [
                Text(
                  'REFERENCE',
                  style: TextStyle(
                    color: rc.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: rc.textMuted,
                  size: 16,
                ),
              ]),
            ),
          );
        }),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _entries.map((e) {
                      return Builder(builder: (bCtx) {
                        final rc = Theme.of(bCtx).extension<AppColors>()!;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 9, vertical: 5),
                          decoration: BoxDecoration(
                            color: rc.surfaceCard,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: rc.borderSubtle),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(e.$1,
                                  style: TextStyle(
                                    color: rc.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  )),
                              const SizedBox(width: 7),
                              Text(e.$2,
                                  style: const TextStyle(
                                    color: Color(0xFF6C63FF),
                                    fontSize: 11,
                                    letterSpacing: 1.5,
                                  )),
                            ],
                          ),
                        );
                      });
                    }).toList(),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
