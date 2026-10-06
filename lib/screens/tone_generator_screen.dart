import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../services/clip_repository.dart';
import '../services/guitar_tuning.dart';
import '../services/haptics.dart';
import '../services/tone_math.dart';
import '../theme/app_colors.dart';
import '../widgets/tone_generator_widgets.dart';

/// The guitar tuner's saved A4 calibration, shared with the pitch pipe.
const _kPrefA4 = 'tuner_a4';

/// The pitch pipe's voice: a triangle is soft like a sine but its odd
/// harmonics carry low notes through a phone speaker, a bit like a reed.
const _kPipeWave = ToneWave.triangle;

const _kSweepSeconds = 10.0;
const _kPresets = [100.0, 440.0, 1000.0, 10000.0];

// ── Audio ───────────────────────────────────────────────────────────────────

/// Where the tone goes. One continuous voice whose frequency, shape and
/// level can change while it plays.
abstract class ToneOutput {
  /// Starts the tone, or retunes it if it's already playing.
  void play(ToneWave wave, double hz, double gain);
  void setFreq(double hz);
  void setWave(ToneWave wave, double gain);
  void setGain(double gain);
  void stop();
  void dispose();
}

/// [ToneOutput] on SoLoud's live waveform generator. Frequency changes
/// glide inside the engine (no clicks); start and stop fade over ~40 ms.
/// Does nothing if the audio engine isn't running.
class SoLoudToneOutput implements ToneOutput {
  static const _fade = Duration(milliseconds: 40);

  AudioSource? _src;
  Future<AudioSource?>? _loading;
  SoundHandle? _handle;
  int _gen = 0; // bumped by every play/stop so a slow start knows it's stale
  Timer? _swap;
  bool _disposed = false;

  static WaveForm _form(ToneWave w) => switch (w) {
    ToneWave.sine => WaveForm.sin,
    ToneWave.square => WaveForm.square,
    ToneWave.triangle => WaveForm.triangle,
    ToneWave.saw => WaveForm.saw,
  };

  static SoLoud? get _engine {
    try {
      final sl = SoLoud.instance;
      return sl.isInitialized ? sl : null;
    } catch (_) {
      return null;
    }
  }

  Future<AudioSource?> _source() {
    return _loading ??= () async {
      final sl = _engine;
      if (sl == null) {
        _loading = null; // try again later; the engine may still be starting
        return null;
      }
      try {
        final src = await sl.loadWaveform(WaveForm.sin, false, 1.0, 0);
        if (_disposed) {
          sl.disposeSource(src).ignore();
          return null;
        }
        return _src = src;
      } catch (_) {
        _loading = null;
        return null;
      }
    }();
  }

  void _guard(void Function(SoLoud sl) f) {
    final sl = _engine;
    if (sl == null) return;
    try {
      f(sl);
    } catch (_) {}
  }

  @override
  void play(ToneWave wave, double hz, double gain) {
    final h = _handle;
    if (h != null) {
      _swap?.cancel();
      _guard((sl) {
        sl.setWaveform(_src!, _form(wave));
        sl.setWaveformFreq(_src!, hz);
        sl.fadeVolume(h, gain, _fade);
      });
      return;
    }
    final gen = ++_gen;
    () async {
      final src = await _source();
      final sl = _engine;
      if (src == null || sl == null || gen != _gen || _disposed) return;
      try {
        sl.setWaveform(src, _form(wave));
        sl.setWaveformFreq(src, hz);
        final h = await sl.play(src, volume: 0, looping: true);
        if (gen != _gen || _disposed) {
          sl.stop(h).ignore();
          return;
        }
        _handle = h;
        sl.setProtectVoice(h, true);
        sl.fadeVolume(h, gain, _fade);
      } catch (_) {}
    }();
  }

  @override
  void setFreq(double hz) {
    final src = _src;
    if (src != null) _guard((sl) => sl.setWaveformFreq(src, hz));
  }

  @override
  void setWave(ToneWave wave, double gain) {
    final src = _src;
    if (src == null) return;
    final h = _handle;
    if (h == null) {
      _guard((sl) => sl.setWaveform(src, _form(wave)));
      return;
    }
    // Dip the level around the switch so the change of shape doesn't click.
    _swap?.cancel();
    _guard((sl) => sl.fadeVolume(h, 0, const Duration(milliseconds: 15)));
    _swap = Timer(const Duration(milliseconds: 18), () {
      _guard((sl) {
        sl.setWaveform(src, _form(wave));
        if (_handle == h) {
          sl.fadeVolume(h, gain, const Duration(milliseconds: 25));
        }
      });
    });
  }

  @override
  void setGain(double gain) {
    final h = _handle;
    if (h != null) {
      _guard((sl) => sl.fadeVolume(h, gain, const Duration(milliseconds: 30)));
    }
  }

  @override
  void stop() {
    _gen++;
    _swap?.cancel();
    final h = _handle;
    _handle = null;
    if (h == null) return;
    _guard((sl) {
      sl.fadeVolume(h, 0, _fade);
      sl.scheduleStop(h, _fade + const Duration(milliseconds: 20));
    });
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    final src = _src;
    _src = null;
    if (src != null) {
      // After the fade-out has finished.
      Timer(const Duration(milliseconds: 120), () {
        _guard((sl) => sl.disposeSource(src).ignore());
      });
    }
  }
}

// ── Screen ──────────────────────────────────────────────────────────────────

/// Tone generator (any frequency, four waveforms, sweep) and a chromatic
/// pitch pipe.
class ToneGeneratorScreen extends StatefulWidget {
  /// Replaces the audio engine (tests). Also skips reading saved settings.
  @visibleForTesting
  final ToneOutput? debugOutput;

  const ToneGeneratorScreen({super.key, this.debugOutput});

  @override
  State<ToneGeneratorScreen> createState() => _ToneGeneratorScreenState();
}

class _ToneGeneratorScreenState extends State<ToneGeneratorScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late final ToneOutput _out = widget.debugOutput ?? SoLoudToneOutput();
  late final Ticker _sweepTicker;

  int _tab = 0;
  double _volume = 0.5;

  // Tone
  double _hz = 440;
  ToneWave _wave = ToneWave.sine;
  bool _playing = false;
  bool _sweeping = false;
  double _preSweepHz = 440;

  // Pitch pipe
  int _pipePc = 9; // A
  int _octave = 4;
  bool _pipePlaying = false;
  double _a4 = 440;

  @override
  void initState() {
    super.initState();
    _sweepTicker = createTicker(_onSweepTick);
    WidgetsBinding.instance.addObserver(this);
    _loadA4();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweepTicker.dispose();
    _out.stop();
    _out.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never keep beeping in the background.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _stopAll();
    }
  }

  Future<void> _loadA4() async {
    if (widget.debugOutput != null) return;
    try {
      final a4 = parseA4(await ClipRepository.getString(_kPrefA4));
      if (!mounted || a4 == _a4) return;
      setState(() => _a4 = a4);
      if (_pipePlaying) _out.setFreq(_pipeHz);
    } catch (_) {}
  }

  double get _pipeHz => midiToHz(pipeMidi(_pipePc, _octave), a4: _a4);
  double get _toneGain => toneGain(_volume, _wave);
  double get _pipeGain => toneGain(_volume, _kPipeWave);

  void _stopAll() {
    if (_sweeping) _endSweep();
    if (_playing || _pipePlaying) _out.stop();
    if (!mounted) return;
    if (_playing || _pipePlaying) {
      setState(() {
        _playing = false;
        _pipePlaying = false;
      });
    }
  }

  void _setTab(int i) {
    if (i == _tab) return;
    Haptics.selection();
    _stopAll();
    setState(() => _tab = i);
  }

  void _setVolume(double v) {
    setState(() => _volume = v);
    if (_playing) _out.setGain(_toneGain);
    if (_pipePlaying) _out.setGain(_pipeGain);
  }

  // ── Tone ────────────────────────────────────────────────────────────────

  /// [snap] rounds to a tidy value (for dragging); typed values are kept.
  void _setHz(double hz, {bool snap = true}) {
    if (_sweeping) _endSweep(restore: false);
    final v = snap ? snapHz(hz) : clampHz(hz);
    if (v == _hz) return;
    setState(() => _hz = v);
    if (_playing) _out.setFreq(v);
  }

  void _nudge(bool up, [int repeats = 0]) {
    if (repeats == 0) Haptics.selection();
    _setHz(
      nudgeHz(_hz, up: up, multiplier: repeats > 20 ? 10 : 1),
      snap: false,
    );
  }

  void _setWave(ToneWave w) {
    if (w == _wave) return;
    Haptics.selection();
    setState(() => _wave = w);
    if (_playing) _out.setWave(w, _toneGain);
  }

  void _togglePlay() {
    Haptics.light();
    if (_playing) {
      _stopTone();
    } else {
      _out.play(_wave, _hz, _toneGain);
      setState(() => _playing = true);
    }
  }

  void _stopTone() {
    if (_sweeping) _endSweep();
    _out.stop();
    setState(() => _playing = false);
  }

  void _toggleSweep() {
    Haptics.light();
    if (_sweeping) {
      _stopTone();
      return;
    }
    _preSweepHz = _hz;
    setState(() {
      _sweeping = true;
      _hz = kMinHz;
    });
    if (_playing) {
      _out.setFreq(_hz);
    } else {
      _out.play(_wave, _hz, _toneGain);
      setState(() => _playing = true);
    }
    _sweepTicker.start();
  }

  void _onSweepTick(Duration elapsed) {
    final t = elapsed.inMicroseconds / 1e6;
    if (t >= _kSweepSeconds) {
      _stopTone(); // also puts the frequency back
      return;
    }
    final hz = sweepHz(t, seconds: _kSweepSeconds);
    setState(() => _hz = hz);
    _out.setFreq(hz);
  }

  /// Stops the sweep; [restore] puts back the frequency from before it.
  /// The caller decides whether the tone keeps playing.
  void _endSweep({bool restore = true}) {
    _sweepTicker.stop();
    _sweeping = false;
    if (restore) {
      _hz = _preSweepHz;
      if (_playing) _out.setFreq(_hz);
    }
    if (mounted) setState(() {});
  }

  Future<void> _typeHz() async {
    Haptics.light();
    final v = await showDialog<double>(
      context: context,
      builder: (_) => _HzDialog(initial: _hz),
    );
    if (v != null && mounted) _setHz(v, snap: false);
  }

  // ── Pitch pipe ──────────────────────────────────────────────────────────

  void _pipeNote(int pc) {
    Haptics.selection();
    if (_pipePlaying && pc == _pipePc) {
      _stopPipe();
      return;
    }
    setState(() {
      _pipePc = pc;
      _pipePlaying = true;
    });
    _out.play(_kPipeWave, _pipeHz, _pipeGain);
  }

  void _pipeCentre() {
    Haptics.selection();
    if (_pipePlaying) {
      _stopPipe();
    } else {
      setState(() => _pipePlaying = true);
      _out.play(_kPipeWave, _pipeHz, _pipeGain);
    }
  }

  void _stopPipe() {
    _out.stop();
    setState(() => _pipePlaying = false);
  }

  void _setOctave(int o) {
    Haptics.selection();
    setState(() => _octave = o.clamp(kMinOctave, kMaxOctave));
    if (_pipePlaying) _out.setFreq(_pipeHz);
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Tone Generator',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: ToneTabs(
                index: _tab,
                labels: const ['Tone', 'Pitch pipe'],
                onChanged: _setTab,
              ),
            ),
            Expanded(child: _tab == 0 ? _toneTab(c) : _pipeTab(c)),
          ],
        ),
      ),
    );
  }

  Widget _toneTab(AppColors c) {
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxHeight < 600;
        // Below this the scope can't get a useful height: scroll instead.
        final scroll = box.maxHeight < 470;
        final caution = showCaution(_hz, _volume);
        final scope = Oscilloscope(
          wave: _wave,
          hz: _hz,
          volume: _volume,
          playing: _playing,
          badge: _sweeping ? 'Sweeping' : null,
        );
        final column = Column(
          children: [
            _FrequencyReadout(
              hz: _hz,
              a4: _a4,
              compact: compact,
              onTap: _typeHz,
            ),
            SizedBox(height: compact ? 6 : 10),
            if (scroll)
              SizedBox(height: 90, child: scope)
            else
              Expanded(child: scope),
            SizedBox(height: compact ? 10 : 14),
            Row(
              children: [
                RepeatButton(
                  icon: Icons.remove_rounded,
                  tooltip: 'Lower frequency',
                  enabled: _hz > kMinHz,
                  onStep: (n) => _nudge(false, n),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FrequencyDial(
                    key: const ValueKey('tone-dial'),
                    hz: _hz,
                    height: compact ? 56 : 64,
                    onChanged: _setHz,
                    onNudge: _nudge,
                  ),
                ),
                const SizedBox(width: 8),
                RepeatButton(
                  icon: Icons.add_rounded,
                  tooltip: 'Raise frequency',
                  enabled: _hz < kMaxHz,
                  onStep: (n) => _nudge(true, n),
                ),
              ],
            ),
            SizedBox(height: compact ? 8 : 10),
            Row(
              children: [
                for (var i = 0; i < _kPresets.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _PresetChip(
                      hz: _kPresets[i],
                      selected: _hz == _kPresets[i],
                      onTap: () {
                        Haptics.selection();
                        _setHz(_kPresets[i], snap: false);
                      },
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: compact ? 10 : 14),
            WaveformSelector(
              value: _wave,
              onChanged: _setWave,
              compact: compact,
            ),
            SizedBox(height: compact ? 2 : 6),
            ToneVolumeRow(value: _volume, onChanged: _setVolume),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: caution
                  ? _CautionLine(highPitch: _hz > kHighHz)
                  : const SizedBox(width: double.infinity),
            ),
            SizedBox(height: compact ? 6 : 10),
            Row(
              children: [
                Expanded(
                  child: _PlayButton(
                    playing: _playing,
                    compact: compact,
                    onTap: _togglePlay,
                  ),
                ),
                const SizedBox(width: 10),
                _SweepButton(
                  sweeping: _sweeping,
                  compact: compact,
                  onTap: _toggleSweep,
                ),
              ],
            ),
            SizedBox(height: compact ? 10 : 14),
          ],
        );
        final padded = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: column,
        );
        return scroll ? SingleChildScrollView(child: padded) : padded;
      },
    );
  }

  Widget _pipeTab(AppColors c) {
    final tabular = [const FontFeature.tabularFigures()];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // The wheel and its hint sit together in the middle of the space.
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                const hintH = 34.0;
                final size = min(box.maxWidth, box.maxHeight - hintH - 8);
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: size,
                      height: size,
                      child: PitchPipeWheel(
                        selected: _pipePc,
                        playing: _pipePlaying,
                        octave: _octave,
                        a4: _a4,
                        onNote: _pipeNote,
                        onCentre: _pipeCentre,
                      ),
                    ),
                    SizedBox(
                      height: hintH,
                      child: Center(
                        child: Text(
                          _pipePlaying
                              ? 'Tap the note again, or the middle, to stop'
                              : 'Tap a note to hear it',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              OctaveStepper(octave: _octave, onChanged: _setOctave),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Reference',
                      style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                    ),
                    Text(
                      'A4 = ${_a4.round()} Hz',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: tabular,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ToneVolumeRow(value: _volume, onChanged: _setVolume),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

// ── Pieces ──────────────────────────────────────────────────────────────────

/// "440 Hz" big, the nearest note under it. Tap to type a value.
class _FrequencyReadout extends StatelessWidget {
  final double hz;
  final double a4;
  final bool compact;
  final VoidCallback onTap;

  const _FrequencyReadout({
    required this.hz,
    required this.a4,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    final (number, unit) = formatHzParts(hz);
    final note = nearestNote(hz, a4: a4);
    final tabular = [const FontFeature.tabularFigures()];
    return Semantics(
      button: true,
      label:
          'Frequency $number $unit, nearest note ${note.label}. '
          'Tap to type a frequency',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('tone-readout'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      number,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: compact ? 50 : 62,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.5,
                        height: 1.1,
                        fontFeatures: tabular,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      unit,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: compact ? 19 : 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.edit_rounded, size: 16, color: c.iconSecondary),
                  ],
                ),
              ),
              Text(
                note.label,
                style: TextStyle(
                  color: p.tintText,
                  fontSize: compact ? 14 : 15,
                  fontWeight: FontWeight.w600,
                  fontFeatures: tabular,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final double hz;
  final bool selected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.hz,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? p.tintSoft : c.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? p.tint.withValues(alpha: 0.6) : c.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 36,
            child: Center(
              child: Text(
                formatHz(hz),
                maxLines: 1,
                style: TextStyle(
                  color: selected ? p.tintText : c.textSecondary,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CautionLine extends StatelessWidget {
  final bool highPitch;
  const _CautionLine({required this.highPitch});

  @override
  Widget build(BuildContext context) {
    final p = TonePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.hearing_rounded, size: 16, color: p.warn),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              highPitch
                  ? 'High tones can be hard to hear — keep the volume moderate.'
                  : 'That’s loud — keep the volume moderate, especially with headphones.',
              style: TextStyle(
                color: p.warn,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;
  final bool compact;
  final VoidCallback onTap;

  const _PlayButton({
    required this.playing,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    return SizedBox(
      height: compact ? 52 : 58,
      child: FilledButton.icon(
        key: const ValueKey('tone-play'),
        onPressed: onTap,
        icon: Icon(
          playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
          size: 26,
        ),
        label: Text(playing ? 'Stop' : 'Play'),
        style: FilledButton.styleFrom(
          backgroundColor: playing ? c.surfaceElevated : p.tint,
          foregroundColor: playing ? c.textPrimary : p.onTint,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: TextStyle(
            fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _SweepButton extends StatelessWidget {
  final bool sweeping;
  final bool compact;
  final VoidCallback onTap;

  const _SweepButton({
    required this.sweeping,
    required this.compact,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    return Tooltip(
      message: 'Sweep 20 Hz to 20 kHz over 10 seconds',
      child: SizedBox(
        height: compact ? 52 : 58,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(
            sweeping ? Icons.stop_rounded : Icons.trending_up_rounded,
            size: 20,
          ),
          label: Text(sweeping ? 'Stop sweep' : 'Sweep'),
          style: OutlinedButton.styleFrom(
            foregroundColor: sweeping ? p.tintText : c.textPrimary,
            backgroundColor: sweeping ? p.tintSoft : null,
            side: BorderSide(
              color: sweeping ? p.tint.withValues(alpha: 0.6) : c.border,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            textStyle: TextStyle(
              fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Type an exact frequency.
class _HzDialog extends StatefulWidget {
  final double initial;
  const _HzDialog({required this.initial});

  @override
  State<_HzDialog> createState() => _HzDialogState();
}

class _HzDialogState extends State<_HzDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    final v = widget.initial;
    final text = v == v.roundToDouble()
        ? '${v.round()}'
        : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
    _ctrl = TextEditingController(text: text)
      ..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = parseHz(_ctrl.text);
    if (v == null) {
      setState(() => _error = 'Enter a number, like 440 or 1.5k');
    } else if (!inAudibleRange(v)) {
      setState(() => _error = 'Choose between 20 Hz and 20 kHz');
    } else {
      Navigator.pop(context, v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TonePalette.of(context);
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return AlertDialog(
      title: Text(
        'Set frequency',
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: TextField(
        key: const ValueKey('tone-hz-field'),
        controller: _ctrl,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        cursorColor: p.tint,
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: InputDecoration(
          suffixText: 'Hz',
          helperText: '20 Hz to 20 kHz',
          errorText: _error,
          filled: true,
          fillColor: c.surfaceElevated.withValues(alpha: 0.5),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: p.tint, width: 1.5),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          style: TextButton.styleFrom(
            foregroundColor: c.textSecondary,
            textStyle: TextStyle(fontFamily: font, fontWeight: FontWeight.w600),
          ),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          style: TextButton.styleFrom(
            foregroundColor: p.tintText,
            textStyle: TextStyle(fontFamily: font, fontWeight: FontWeight.w700),
          ),
          child: const Text('Set'),
        ),
      ],
    );
  }
}
