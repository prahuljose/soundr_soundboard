import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../services/cleaner_tones.dart';
import '../services/haptics.dart';
import '../theme/app_colors.dart';
import '../widgets/speaker_cleaner_widgets.dart';

/// Speaker Cleaner: plays a low pulsing tone near the speaker's resonance
/// to push water out of the grille, or a 200–1500 Hz sweep to shake dust
/// loose. One big Start button, a countdown ring while it runs.
class SpeakerCleanerScreen extends StatefulWidget {
  const SpeakerCleanerScreen({super.key});

  @override
  State<SpeakerCleanerScreen> createState() => _SpeakerCleanerScreenState();
}

class _SpeakerCleanerScreenState extends State<SpeakerCleanerScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _player = CleanerPlayer();
  late final AnimationController _run = AnimationController(vsync: this)
    ..addStatusListener(_onRunStatus);

  CleanMode _mode = CleanMode.water;
  final _lengthIndex = {CleanMode.water: 1, CleanMode.dust: 1};
  CleanerPhase _phase = CleanerPhase.idle;
  int _gen = 0; // bumps on every start/stop so a slow start can't resurrect

  List<Duration> get _lengths => CleanerTones.lengths(_mode);
  Duration get _length => _lengths[_lengthIndex[_mode]!];
  bool get _busy =>
      _phase == CleanerPhase.running || _phase == CleanerPhase.starting;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gen++;
    _player.dispose(); // fades out anything still playing
    _run.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_busy) _stop(haptic: false);
    }
  }

  /// Renders the selected program in the background so Start is instant.
  void _prepare() => _player.prepare(_mode, _length).ignore();

  void _setMode(CleanMode m) {
    if (_busy) return;
    if (m == _mode) {
      if (_phase == CleanerPhase.done) _reset();
      return;
    }
    Haptics.selection();
    setState(() {
      _mode = m;
      _phase = CleanerPhase.idle;
    });
    _prepare();
  }

  void _setLength(int i) {
    if (_busy) return;
    Haptics.selection();
    setState(() {
      _lengthIndex[_mode] = i;
      _phase = CleanerPhase.idle;
    });
    _prepare();
  }

  Future<void> _start() async {
    if (_busy) return;
    Haptics.medium();
    final gen = ++_gen;
    final length = _length;
    setState(() => _phase = CleanerPhase.starting);
    await _player.play(_mode, length);
    if (!mounted || gen != _gen) return;
    setState(() => _phase = CleanerPhase.running);
    _run.duration = length;
    unawaited(_run.forward(from: 0).orCancel.catchError((_) {}));
  }

  void _stop({bool haptic = true}) {
    if (!_busy) return;
    if (haptic) Haptics.light();
    _gen++;
    _player.stop();
    _run.stop();
    _run.value = 0;
    setState(() => _phase = CleanerPhase.idle);
  }

  void _onRunStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed || _phase != CleanerPhase.running) {
      return;
    }
    _player.release(); // the program fades out by itself
    Haptics.heavy();
    setState(() => _phase = CleanerPhase.done);
  }

  void _reset() {
    Haptics.selection();
    setState(() => _phase = CleanerPhase.idle);
  }

  void _runAgain() {
    setState(() => _phase = CleanerPhase.idle);
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Speaker Cleaner',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final compact = box.maxHeight < 620;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  SizedBox(height: compact ? 2 : 8),
                  CleanerModeSwitch(
                    mode: _mode,
                    onChanged: _busy ? null : _setMode,
                  ),
                  SizedBox(
                    height: compact ? 44 : 50,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Text(
                          _mode == CleanMode.water
                              ? 'Low 165 Hz pulses push water out of the speaker.'
                              : 'A 200–1500 Hz sweep shakes loose dust and lint.',
                          key: ValueKey(_mode),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 13.5,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, b) {
                        final size = min(
                          b.maxWidth - 40,
                          b.maxHeight - 12,
                        ).clamp(140.0, 300.0);
                        return Center(
                          child: CleanerDial(
                            size: size,
                            mode: _mode,
                            phase: _phase,
                            length: _length,
                            progress: _run,
                            onStart: _start,
                            onReset: _reset,
                          ),
                        );
                      },
                    ),
                  ),
                  SizedBox(height: compact ? 6 : 10),
                  SizedBox(
                    height: compact ? 80 : 84,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...previous, ?current],
                      ),
                      child: _controls(c),
                    ),
                  ),
                  SizedBox(height: compact ? 4 : 8),
                  CleanerTipsCard(compact: compact),
                  SizedBox(height: compact ? 8 : 14),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _controls(AppColors c) {
    switch (_phase) {
      case CleanerPhase.idle:
      case CleanerPhase.starting:
        return CleanerLengthChips(
          key: ValueKey('chips${_mode.name}'),
          lengths: _lengths,
          selected: _lengthIndex[_mode]!,
          onSelected: _setLength,
        );
      case CleanerPhase.running:
        return CleanerStopButton(key: const ValueKey('stop'), onPressed: _stop);
      case CleanerPhase.done:
        return Column(
          key: const ValueKey('done'),
          children: [
            CleanerRunAgainButton(onPressed: _runAgain),
            const SizedBox(height: 8),
            Flexible(
              child: Text(
                _mode == CleanMode.water
                    ? 'Still muffled? Run it once more.'
                    : 'Still crackly? Run it once more.',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
            ),
          ],
        );
    }
  }
}
