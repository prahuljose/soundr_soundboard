import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/sound_model.dart';
import '../services/device_features.dart';
import '../services/haptics.dart';
import '../widgets/performance_widgets.dart';

export '../widgets/performance_widgets.dart' show PerformanceSet, PerformancePlayer;

/// Performance mode: a full-screen board of big pads for streams and parties.
///
/// Immersive (system bars hidden), screen kept awake, any orientation while
/// open. 12 pads per page (3×4 portrait, 6×2 landscape). Exit needs a
/// long-press on the X; Android back only shows the hint.
class PerformanceScreen extends StatefulWidget {
  /// Non-empty list of boards to pick from.
  final List<PerformanceSet> sets;

  /// Set to open on; defaults to the first.
  final String? initialSetId;

  /// Sound id → SoLoud source, already loaded by the soundboard.
  final Map<String, AudioSource> preloaded;

  /// Replaces the SoLoud-backed player in tests.
  @visibleForTesting
  final PerformancePlayer? debugPlayer;

  const PerformanceScreen({
    super.key,
    required this.sets,
    this.initialSetId,
    this.preloaded = const {},
    this.debugPlayer,
  }) : assert(sets.length > 0);

  static const padsPerPage = 12;

  @override
  State<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends State<PerformanceScreen>
    with TickerProviderStateMixin {
  late final PerformancePlayer _player =
      widget.debugPlayer ?? PerformancePlayer(preloaded: widget.preloaded);

  late int _setIndex;
  int _page = 0;
  PageController _pages = PageController();
  bool _locked = false;
  bool _cut = false;

  /// Sound id → progress through its current play (0→1).
  final Map<String, AnimationController> _playing = {};
  final Map<String, int> _tapGen = {};

  bool _hintVisible = false;
  Timer? _hintTimer;

  PerformanceSet get _set => widget.sets[_setIndex];

  @override
  void initState() {
    super.initState();
    final i = widget.sets.indexWhere((s) => s.id == widget.initialSetId);
    _setIndex = i < 0 ? 0 : i;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    DeviceFeatures.keepAwake(true);
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _player.dispose();
    for (final c in _playing.values) {
      c.dispose();
    }
    _pages.dispose();
    // The app sets no orientation lock and no system UI mode of its own, so
    // restore the platform defaults: all orientations allowed, bars visible.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    SystemChrome.setPreferredOrientations(const []);
    DeviceFeatures.keepAwake(false);
    super.dispose();
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  void _clearPad(String id) {
    _playing.remove(id)?.dispose();
  }

  Future<void> _tapPad(SoundModel sound) async {
    Haptics.light();
    final gen = _tapGen[sound.id] = (_tapGen[sound.id] ?? 0) + 1;
    if (_cut) {
      if (_playing.isNotEmpty) _player.stopAll();
      for (final id in _playing.keys.toList()) {
        _clearPad(id);
      }
    } else if (_playing.containsKey(sound.id)) {
      // Restart: drop the old voice before starting again from the top.
      _player.stop(sound.id);
      _clearPad(sound.id);
    }
    setState(() {});

    final duration = await _player.play(sound);
    if (!mounted || _tapGen[sound.id] != gen) return;
    if (duration == null || duration <= Duration.zero) return;

    _clearPad(sound.id);
    final c = AnimationController(vsync: this, duration: duration);
    c.addStatusListener((s) {
      if (s == AnimationStatus.completed && _playing[sound.id] == c) {
        setState(() => _clearPad(sound.id));
      }
    });
    setState(() => _playing[sound.id] = c);
    c.forward();
  }

  void _stopAll() {
    Haptics.medium();
    _player.stopAll();
    for (final id in _tapGen.keys) {
      _tapGen[id] = _tapGen[id]! + 1; // drop any play still starting
    }
    setState(() {
      for (final id in _playing.keys.toList()) {
        _clearPad(id);
      }
    });
  }

  // ── Chrome ────────────────────────────────────────────────────────────────

  void _showHint() {
    _hintTimer?.cancel();
    setState(() => _hintVisible = true);
    _hintTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _hintVisible = false);
    });
  }

  void _exit() {
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _pickSet() async {
    if (_locked) return;
    final p = PerformancePalette.of(context);
    final id = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.surface,
      isScrollControlled: true,
      builder: (_) => PerformanceSetSheet(sets: widget.sets, currentId: _set.id),
    );
    if (!mounted || id == null || id == _set.id) return;
    final i = widget.sets.indexWhere((s) => s.id == id);
    if (i < 0) return;
    final old = _pages;
    setState(() {
      _setIndex = i;
      _page = 0;
      _pages = PageController();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  // ── Layout ────────────────────────────────────────────────────────────────

  int get _pageCount =>
      (_set.sounds.length / PerformanceScreen.padsPerPage).ceil().clamp(1, 1 << 20);

  Widget _grid({required int cols, required int rows, required EdgeInsets padding}) {
    final sounds = _set.sounds;
    return PageView.builder(
      key: ValueKey(_set.id),
      controller: _pages,
      itemCount: _pageCount,
      onPageChanged: (i) => setState(() => _page = i),
      itemBuilder: (context, page) {
        final start = page * PerformanceScreen.padsPerPage;
        return Padding(
          padding: padding,
          child: Column(
            children: [
              for (var r = 0; r < rows; r++) ...[
                if (r > 0) const SizedBox(height: 10),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var c = 0; c < cols; c++) ...[
                        if (c > 0) const SizedBox(width: 10),
                        Expanded(child: _slot(sounds, start + r * cols + c)),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _slot(List<SoundModel> sounds, int i) {
    if (i >= sounds.length) return const SizedBox.shrink();
    final s = sounds[i];
    return PerformancePad(
      key: ValueKey('pad-${s.id}'),
      sound: s,
      progress: _playing[s.id],
      onTap: () => _tapPad(s),
    );
  }

  Widget _exitButton() =>
      PerformanceExitButton(onExit: _exit, onHint: _showHint);

  Widget _lockButton() => PerformanceLockButton(
        locked: _locked,
        onTap: () {
          Haptics.selection();
          setState(() => _locked = !_locked);
        },
      );

  Widget _modeSwitch(Axis direction) => PerformanceModeSwitch(
        cut: _cut,
        enabled: !_locked,
        direction: direction,
        onChanged: (v) {
          Haptics.selection();
          setState(() => _cut = v);
        },
      );

  Widget _portrait() => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 2),
            child: Row(
              children: [
                _exitButton(),
                const SizedBox(width: 10),
                Expanded(
                  child: PerformanceSetButton(
                    set: _set,
                    enabled: !_locked,
                    onTap: _pickSet,
                  ),
                ),
                const SizedBox(width: 10),
                _lockButton(),
              ],
            ),
          ),
          Expanded(
            child: _grid(
              cols: 3,
              rows: 4,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            ),
          ),
          SizedBox(
            height: 24,
            child: _pageCount > 1
                ? Center(
                    child: PerformancePageDots(count: _pageCount, current: _page))
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
            child: Row(
              children: [
                _modeSwitch(Axis.horizontal),
                const SizedBox(width: 10),
                Expanded(child: PerformanceStopAllButton(onTap: _stopAll)),
              ],
            ),
          ),
        ],
      );

  Widget _landscape() => Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 0, 14),
            child: Column(
              children: [
                _exitButton(),
                const SizedBox(height: 10),
                PerformanceSetButton(
                  set: _set,
                  compact: true,
                  enabled: !_locked,
                  onTap: _pickSet,
                ),
                const SizedBox(height: 10),
                _lockButton(),
                const Spacer(),
                if (_pageCount > 1)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: PerformancePageDots(
                      count: _pageCount,
                      current: _page,
                      direction: Axis.vertical,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _grid(
              cols: 6,
              rows: 2,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 14, 12, 14),
            child: SizedBox(
              width: 92,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _modeSwitch(Axis.vertical),
                  const SizedBox(height: 10),
                  Expanded(
                    child: PerformanceStopAllButton(
                        onTap: _stopAll, vertical: true),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final p = PerformancePalette.of(context);
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showHint();
      },
      child: Scaffold(
        backgroundColor: p.bg,
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(child: landscape ? _landscape() : _portrait()),
              Positioned(
                left: 0,
                right: 0,
                top: landscape ? 18 : 74,
                child: Center(
                  child: PerformanceHintToast(
                    message: 'Hold to exit',
                    visible: _hintVisible,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
