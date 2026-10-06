import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import '../services/clip_repository.dart';
import '../services/device_features.dart';
import '../services/haptics.dart';
import '../theme/app_colors.dart';
import '../widgets/morse_tapper_widgets.dart';

class MorseScreen extends StatefulWidget {
  final AudioSource? dotSource;
  final AudioSource? dashSource;

  /// Seeds the decoded text (goldens only).
  @visibleForTesting
  final String debugInitialText;

  /// Seeds the in-progress letter, in '.' / '-' (goldens only).
  @visibleForTesting
  final String debugInitialMorse;

  const MorseScreen({
    super.key,
    this.dotSource,
    this.dashSource,
    this.debugInitialText = '',
    this.debugInitialMorse = '',
  });

  @override
  State<MorseScreen> createState() => _MorseScreenState();
}

class _MorseScreenState extends State<MorseScreen> {
  // Internal lookup keys use '.' and '-'; dots and dashes are drawn as shapes.
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

  /// Hint-chip order: the design's starter set first, then by English
  /// letter frequency, then digits.
  static const _hintOrder = 'ETIANSOHRDLUMCWFGYPBVKJXQZ1234567890';

  static final Map<String, String> _charToMorse = {
    for (final e in _morseToChar.entries) e.value: e.key,
  };

  String _currentMorse = ''; // current letter being keyed in (. and -)
  String _decodedText  = ''; // full decoded output

  Timer? _letterTimer;
  Timer? _wordTimer;
  Timer? _dashModeTimer;
  DateTime? _pressStart;
  bool _isPressed   = false;
  bool _isDashMode  = false; // true once press exceeds dot threshold
  bool _isMuted     = false;

  // Opt-in: light the torch / buzz for as long as the key is held.
  bool _flashWhileHeld   = false;
  bool _vibrateWhileHeld = false;
  bool _hasTorch    = false;
  bool _hasVibrator = false;
  static const _kFlash   = 'morse_tapper_flash';
  static const _kVibrate = 'morse_tapper_vibrate';

  @override
  void initState() {
    super.initState();
    _decodedText = widget.debugInitialText;
    _currentMorse = widget.debugInitialMorse;
    _loadSignalPrefs();
  }

  Future<void> _loadSignalPrefs() async {
    final hasTorch = await DeviceFeatures.hasTorch();
    final hasVibrator = await DeviceFeatures.hasVibrator();
    var flash = false, vibrate = false;
    try {
      flash = await ClipRepository.getBool(_kFlash);
      vibrate = await ClipRepository.getBool(_kVibrate);
    } catch (_) {/* keep defaults */}
    if (!mounted) return;
    setState(() {
      _hasTorch = hasTorch;
      _hasVibrator = hasVibrator;
      _flashWhileHeld = flash && hasTorch;
      _vibrateWhileHeld = vibrate && hasVibrator;
    });
  }

  void _signalOn() {
    if (_flashWhileHeld) DeviceFeatures.setTorch(true);
    // Long one-shot, cancelled on release — no press lasts 10 s.
    if (_vibrateWhileHeld) DeviceFeatures.vibrate(10000);
  }

  void _signalOff() {
    if (_hasTorch) DeviceFeatures.setTorch(false);
    if (_hasVibrator) DeviceFeatures.cancelVibrate();
  }

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
        Haptics.selection();
      }
    });
    setState(() { _isPressed = true; _isDashMode = false; });
    Haptics.light();
    _signalOn();
  }

  void _onPressEnd() {
    _dashModeTimer?.cancel();
    _signalOff();
    if (_pressStart == null) return;
    final held   = DateTime.now().difference(_pressStart!);
    final isDash = held >= _dotThreshold;
    _pressStart  = null;
    setState(() { _isPressed = false; _isDashMode = false; });
    _addSymbol(isDash);
  }

  void _onPressCancel() {
    _dashModeTimer?.cancel();
    _signalOff();
    setState(() { _isPressed = false; _isDashMode = false; });
  }

  // ── Symbol logic ────────────────────────────────────────────────────────────

  void _addSymbol(bool isDash) {
    final symbol = isDash ? '-' : '.';
    setState(() => _currentMorse += symbol);
    _playSymbol(isDash);
    Haptics.selection();

    _letterTimer?.cancel();
    _letterTimer = Timer(_letterGap, _commitLetter);
  }

  void _commitLetter() {
    if (_currentMorse.isEmpty) return;
    final letter = _morseToChar[_currentMorse] ?? '?';
    setState(() { _decodedText += letter; _currentMorse = ''; });
    Haptics.medium();

    _wordTimer?.cancel();
    _wordTimer = Timer(_wordGap, _commitSpace);
  }

  void _commitSpace() {
    if (_decodedText.isNotEmpty && !_decodedText.endsWith(' ')) {
      setState(() => _decodedText += ' ');
    }
  }

  void _playSymbol(bool isDash) {
    if (_isMuted) return;
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
    Haptics.selection();
  }

  void _clear() {
    _letterTimer?.cancel();
    _wordTimer?.cancel();
    setState(() { _currentMorse = ''; _decodedText = ''; });
    Haptics.medium();
  }

  // ── Current-letter helpers ──────────────────────────────────────────────────

  /// The letter the in-progress sequence decodes to right now, if any.
  String? get _currentLetter => _morseToChar[_currentMorse];

  /// Whether more symbols could still lead to a valid character.
  bool get _canExtend => _morseToChar.keys.any(
      (k) => k.length > _currentMorse.length && k.startsWith(_currentMorse));

  String get _pillHint {
    if (_currentMorse.isEmpty) return 'Tap to start';
    final letter = _currentLetter;
    if (letter != null) {
      return _canExtend ? '$letter … or keep going' : "That's $letter";
    }
    return _canExtend ? 'No letter yet' : 'Not a letter';
  }

  /// Letters whose code starts with the current sequence (exact match first,
  /// then shortest codes), or the most common letters when nothing is keyed.
  List<(String, String)> get _hints {
    final chars = _hintOrder.split('');
    if (_currentMorse.isEmpty) {
      return [for (final ch in chars.take(12)) (ch, _charToMorse[ch]!)];
    }
    // Grouped by code length (exact match first), frequency order within.
    return [
      for (var len = _currentMorse.length; len <= 5; len++)
        for (final ch in chars)
          if (_charToMorse[ch]!.length == len &&
              _charToMorse[ch]!.startsWith(_currentMorse))
            (ch, _charToMorse[ch]!),
    ];
  }

  // ── Toggles ─────────────────────────────────────────────────────────────────

  void _toggleSound() {
    setState(() => _isMuted = !_isMuted);
    Haptics.selection();
  }

  void _toggleFlash() {
    if (!_hasTorch) {
      _snack('This device has no flashlight');
      return;
    }
    final v = !_flashWhileHeld;
    setState(() => _flashWhileHeld = v);
    ClipRepository.setBool(_kFlash, v).catchError((_) {});
    Haptics.selection();
  }

  void _toggleVibrate() {
    if (!_hasVibrator) {
      _snack('This device can\'t vibrate');
      return;
    }
    final v = !_vibrateWhileHeld;
    setState(() => _vibrateWhileHeld = v);
    ClipRepository.setBool(_kVibrate, v).catchError((_) {});
    Haptics.selection();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ── Timing settings sheet ───────────────────────────────────────────────────

  void _showTimingSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final sc = Theme.of(ctx).extension<AppColors>()!;
          final accent = Theme.of(ctx).colorScheme.primary;
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
                            color: sc.textSecondary,
                            fontSize: 12,
                          )),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${value}ms',
                        style: TextStyle(
                          color: accent,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: accent,
                      inactiveTrackColor: sc.textPrimary.withValues(alpha: 0.08),
                      thumbColor: accent,
                      overlayColor: accent.withValues(alpha: 0.12),
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
            child: SingleChildScrollView(
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
                    Icon(Icons.tune_rounded, color: accent, size: 20),
                    const SizedBox(width: 10),
                    Text('Timing', style: TextStyle(
                      color: sc.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    )),
                    const Spacer(),
                    TextButton(
                      onPressed: () => update(() {
                        _dotThresholdMs = 260;
                        _letterGapMs    = 800;
                        _wordGapMs      = 1800;
                      }),
                      style: TextButton.styleFrom(
                        foregroundColor: sc.textSecondary,
                        textStyle: Theme.of(ctx).textTheme.labelLarge
                            ?.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      child: const Text('Reset'),
                    ),
                  ]),
                  const SizedBox(height: 12),
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

  // ── Reference chart sheet ───────────────────────────────────────────────────

  void _showChart() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _MorseChart(entries: [
        for (final ch in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.split(''))
          (ch, _charToMorse[ch]!),
      ]),
    );
  }

  @override
  void dispose() {
    _signalOff();
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
    final screenH = MediaQuery.sizeOf(context).height;
    final padHeight = math.min(220.0, math.max(160.0, screenH * 0.27));
    final hints = _hints;

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(children: [
                MorseSquareButton(
                  icon: Icons.chevron_left_rounded,
                  iconSize: 26,
                  tooltip: 'Back',
                  onTap: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Morse Tapper',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                MorseSquareButton(
                  icon: Icons.menu_book_rounded,
                  tooltip: 'Morse chart',
                  onTap: _showChart,
                ),
                const SizedBox(width: 8),
                MorseSquareButton(
                  icon: Icons.backspace_outlined,
                  tooltip: 'Delete last (hold to clear all)',
                  enabled: hasContent,
                  onTap: _deleteLast,
                  onLongPress: _clear,
                ),
              ]),
            ),

            // ── Decoded output + current letter ─────────────────────────────
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 12),
                    Text(
                      'DECODED',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Flexible(child: _decodedView(c)),
                    const SizedBox(height: 22),
                    _currentLetterPill(c),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),

            // ── Hint chips ──────────────────────────────────────────────────
            SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: hints.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => MorseHintChip(
                  letter: hints[i].$1,
                  code: hints[i].$2,
                  highlighted:
                      _currentMorse.isNotEmpty && hints[i].$2 == _currentMorse,
                ),
              ),
            ),

            // ── Tap pad ─────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Semantics(
                button: true,
                label: 'Morse key',
                hint: 'Tap for a dot, hold for a dash',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) => _onPressStart(),
                  onTapUp: (_) => _onPressEnd(),
                  onTapCancel: _onPressCancel,
                  child: MorseTapPad(
                    pressed: _isPressed,
                    dashMode: _isDashMode,
                    height: padHeight,
                  ),
                ),
              ),
            ),

            // ── Toggles ─────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MorseToggleChip(
                        label: 'Sound',
                        selected: !_isMuted,
                        onTap: _toggleSound,
                      ),
                      const SizedBox(width: 8),
                      MorseToggleChip(
                        label: 'Flash',
                        selected: _flashWhileHeld,
                        available: _hasTorch,
                        onTap: _toggleFlash,
                      ),
                      const SizedBox(width: 8),
                      MorseToggleChip(
                        label: 'Vibrate',
                        selected: _vibrateWhileHeld,
                        available: _hasVibrator,
                        onTap: _toggleVibrate,
                      ),
                      const SizedBox(width: 8),
                      MorseToggleChip(
                        label: 'Timing',
                        onTap: _showTimingSheet,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Decoded text with a blinking caret. Shrinks as it grows, wraps, and
  /// scrolls (pinned to the newest line) once it outgrows the space.
  Widget _decodedView(AppColors c) {
    final n = _decodedText.length;
    final size = n <= 7 ? 50.0 : n <= 12 ? 40.0 : n <= 24 ? 32.0 : 26.0;
    return SingleChildScrollView(
      reverse: true,
      child: Semantics(
        label: _decodedText.isEmpty
            ? 'Decoded text: empty'
            : 'Decoded text: $_decodedText',
        excludeSemantics: true,
        child: Text.rich(
          TextSpan(children: [
            TextSpan(text: _decodedText),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsets.only(left: _decodedText.isEmpty ? 0 : 2),
                child: MorseBlinkingCursor(height: size * 0.96),
              ),
            ),
          ]),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: size,
            fontWeight: FontWeight.w600,
            letterSpacing: size * 0.16,
            height: 1.2,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  Widget _currentLetterPill(AppColors c) {
    final accent = Theme.of(context).colorScheme.primary;
    final symbols = <Widget>[];
    for (var i = 0; i < _currentMorse.length; i++) {
      symbols.add(MorseSymbol(isDash: _currentMorse[i] == '-', color: accent));
      symbols.add(const SizedBox(width: 12));
    }
    if (_isPressed) {
      // Live preview of the symbol being held.
      symbols.add(AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: _isDashMode ? 34 : 14,
        height: 14,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(7),
        ),
      ));
    } else if (_currentMorse.isEmpty || _canExtend) {
      symbols.add(MorseNextSlot(color: c.textMuted));
    } else {
      symbols.removeLast(); // trailing gap
    }

    final spoken = _currentMorse
        .split('')
        .map((s) => s == '-' ? 'dash' : 'dot')
        .join(' ');
    return Semantics(
      label: _currentMorse.isEmpty
          ? 'Current letter: empty. $_pillHint'
          : 'Current letter: $spoken. $_pillHint',
      excludeSemantics: true,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: c.border),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...symbols,
              const SizedBox(width: 18),
              Text(
                _pillHint,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reference chart ───────────────────────────────────────────────────────────

class _MorseChart extends StatelessWidget {
  final List<(String, String)> entries;
  const _MorseChart({required this.entries});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    final letters = entries.where((e) => !RegExp(r'\d').hasMatch(e.$1)).toList();
    final digits = entries.where((e) => RegExp(r'\d').hasMatch(e.$1)).toList();

    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            text,
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            ),
          ),
        );

    Widget grid(List<(String, String)> items) => LayoutBuilder(
          builder: (context, box) {
            const gap = 8.0;
            final cols = (box.maxWidth / 104).floor().clamp(3, 5);
            final cellW = (box.maxWidth - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final e in items)
                  Semantics(
                    label: '${e.$1}: ${e.$2.split('').map((s) => s == '-' ? 'dash' : 'dot').join(' ')}',
                    excludeSemantics: true,
                    child: Container(
                      width: cellW,
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: c.scaffoldBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: c.border),
                      ),
                      child: Row(children: [
                        Text(
                          e.$1,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: MorseSymbols(code: e.$2, color: accent),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
              ],
            );
          },
        );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: c.handleBar,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Icon(Icons.menu_book_rounded, color: accent, size: 20),
              const SizedBox(width: 10),
              Text('Morse chart', style: TextStyle(
                color: c.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              )),
            ]),
            const SizedBox(height: 18),
            label('LETTERS'),
            grid(letters),
            const SizedBox(height: 20),
            label('NUMBERS'),
            grid(digits),
          ],
        ),
      ),
    );
  }
}
