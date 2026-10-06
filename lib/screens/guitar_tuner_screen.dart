import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../services/clip_repository.dart';
import '../services/guitar_tuning.dart';
import '../services/haptics.dart';
import '../services/pitch_detector.dart';
import '../services/reference_tone.dart';
import '../theme/app_colors.dart';
import '../widgets/permission_denied_card.dart';
import '../widgets/tuner_widgets.dart';

const _kRate = 44100;
const _kPrefTuning = 'tuner_tuning';
const _kPrefA4 = 'tuner_a4';
const _kPrefChromatic = 'tuner_chromatic';

/// Guitar tuner: listens to the mic, finds the string being played and
/// shows how far it is from pitch. Tap a peg to tune one string at a time
/// and hear its note.
class GuitarTunerScreen extends StatefulWidget {
  /// Feeds 16-bit PCM at 44.1 kHz instead of the microphone (tests).
  @visibleForTesting
  final Stream<Uint8List>? debugAudio;

  const GuitarTunerScreen({super.key, this.debugAudio});

  @override
  State<GuitarTunerScreen> createState() => _GuitarTunerScreenState();
}

class _GuitarTunerScreenState extends State<GuitarTunerScreen>
    with WidgetsBindingObserver {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  late final PitchDetector _detector = PitchDetector(
    sampleRate: _kRate,
    onReading: _onPitch,
  );
  late final TunerEngine _engine = TunerEngine(
    tuning: guitarTunings.first,
    onStringTuned: _onStringTuned,
  );

  TunerReading _reading = const TunerReading();
  PermissionStatus? _micDenied;
  String? _error;
  bool _listening = false;
  bool _starting = false; // guards against a second start mid-permission

  /// While the reference tone plays, the mic would hear it; ignore audio
  /// until this point on the detector's clock.
  int _muteUntilMs = 0;
  bool _toneOn = false;
  Timer? _toneTimer;

  bool get _auto => _engine.lockedString == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _toneTimer?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    if (widget.debugAudio == null) ReferenceTone.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Release the mic in the background; pick up again on return.
    if (state == AppLifecycleState.paused) {
      _stop();
    } else if (state == AppLifecycleState.resumed &&
        !_listening &&
        _micDenied == null) {
      _start();
    }
  }

  Future<void> _loadPrefs() async {
    if (widget.debugAudio != null) return;
    try {
      final id = await ClipRepository.getString(_kPrefTuning);
      final a4 = int.tryParse(await ClipRepository.getString(_kPrefA4) ?? '');
      final chromatic = await ClipRepository.getBool(_kPrefChromatic);
      if (!mounted) return;
      setState(() {
        _engine.tuning = tuningById(id);
        if (a4 != null && a4 >= 430 && a4 <= 450) _engine.a4 = a4.toDouble();
        _engine.chromatic = chromatic;
      });
    } catch (_) {}
  }

  void _savePrefs() {
    if (widget.debugAudio != null) return;
    ClipRepository.setString(
      _kPrefTuning,
      _engine.tuning.id,
    ).catchError((_) {});
    ClipRepository.setString(
      _kPrefA4,
      '${_engine.a4.round()}',
    ).catchError((_) {});
    ClipRepository.setBool(
      _kPrefChromatic,
      _engine.chromatic,
    ).catchError((_) {});
  }

  // ── Microphone ──────────────────────────────────────────────────────────

  Future<void> _start() async {
    if (_listening || _starting) return;
    _starting = true;
    try {
      await _open();
    } finally {
      _starting = false;
    }
  }

  Future<void> _open() async {
    final Stream<Uint8List> stream;
    try {
      final debug = widget.debugAudio;
      if (debug != null) {
        stream = debug;
      } else {
        final status = await Permission.microphone.request();
        if (!mounted) return;
        if (!status.isGranted) {
          setState(() => _micDenied = status);
          return;
        }
        stream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: _kRate,
            numChannels: 1,
            // Processing meant for voice smears a held note; keep it raw.
            autoGain: false,
            echoCancel: false,
            noiseSuppress: false,
            androidConfig: AndroidRecordConfig(
              audioSource: AndroidAudioSource.voiceRecognition,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Couldn’t open the microphone.');
      return;
    }
    if (!mounted) return;
    _detector.reset();
    _sub = stream.listen(
      _detector.addPcm16,
      onError: (Object _) {
        if (mounted) setState(() => _error = 'The microphone stopped.');
      },
    );
    setState(() {
      _listening = true;
      _micDenied = null;
      _error = null;
    });
  }

  Future<void> _stop() async {
    _listening = false;
    await _sub?.cancel();
    _sub = null;
    if (widget.debugAudio == null) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    _engine.resetNote();
    if (mounted) setState(() => _reading = _engine.reading);
  }

  // ── Tuning ──────────────────────────────────────────────────────────────

  void _onPitch(PitchReading? r) {
    final now = _detector.audioMs;
    if (now < _muteUntilMs) return;
    final next = _engine.add(r, now);
    if (!mounted) return;
    if (next.status != _reading.status ||
        next.stringIndex != _reading.stringIndex ||
        next.cents != _reading.cents) {
      setState(() => _reading = next);
    }
  }

  void _onStringTuned(int _) {
    Haptics.medium();
    if (_engine.allTuned) Haptics.heavy();
  }

  void _pickPeg(int string) {
    Haptics.selection();
    setState(() {
      _engine.lockedString = string;
      _engine.resetNote();
      _reading = _engine.reading;
    });
    _playReference();
  }

  void _setAuto() {
    if (_auto) return;
    Haptics.selection();
    _stopReference();
    setState(() {
      _engine.lockedString = null;
      _engine.resetNote();
      _reading = _engine.reading;
    });
  }

  void _playReference() {
    final s = _engine.lockedString;
    if (s == null) return;
    final hz = midiToHz(_engine.tuning.strings[s], a4: _engine.a4);
    final ms = ReferenceTone.duration.inMilliseconds;
    _muteUntilMs = _detector.audioMs + ms + 250;
    _engine.resetNote();
    if (widget.debugAudio == null) ReferenceTone.play(hz);
    _toneTimer?.cancel();
    setState(() => _toneOn = true);
    _toneTimer = Timer(Duration(milliseconds: ms), () {
      if (mounted) setState(() => _toneOn = false);
    });
  }

  void _stopReference() {
    ReferenceTone.stop();
    _toneTimer?.cancel();
    _muteUntilMs = 0;
    if (_toneOn) setState(() => _toneOn = false);
  }

  void _startOver() {
    Haptics.light();
    setState(() {
      _engine.resetTuned();
      _engine.lockedString = null;
      _engine.resetNote();
      _reading = _engine.reading;
    });
  }

  void _applyTuning({GuitarTuning? tuning, bool? chromatic, double? a4}) {
    setState(() {
      final changedStrings =
          (tuning != null && tuning.id != _engine.tuning.id) ||
          (chromatic != null && chromatic != _engine.chromatic);
      if (tuning != null) _engine.tuning = tuning;
      if (chromatic != null) _engine.chromatic = chromatic;
      if (a4 != null) _engine.a4 = a4;
      if (changedStrings || a4 != null) {
        _engine.resetTuned();
        _engine.lockedString = null;
      }
      _engine.resetNote();
      _reading = _engine.reading;
    });
    _stopReference();
    _savePrefs();
  }

  Future<void> _openTuningSheet() async {
    Haptics.light();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TuningSheet(
        tuning: _engine.tuning,
        chromatic: _engine.chromatic,
        a4: _engine.a4,
        onChanged: _applyTuning,
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Guitar Tuner',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: _micDenied != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: PermissionDeniedCard(
                    permission: Permission.microphone,
                    icon: Icons.music_note_rounded,
                    permissionLabel: 'Microphone',
                    purpose:
                        'The tuner listens to your guitar through the microphone. '
                        'Audio is processed on your phone — nothing is recorded or sent.',
                    onGranted: () {
                      if (!mounted) return;
                      setState(() => _micDenied = null);
                      _start();
                    },
                  ),
                ),
              )
            : _buildTuner(c),
      ),
    );
  }

  Widget _buildTuner(AppColors c) {
    final chromatic = _engine.chromatic;
    return LayoutBuilder(
      builder: (context, box) {
        // Fixed parts first; the gauge grows into what's left, leaving the
        // headstock enough room for comfortable pegs.
        final compact = box.maxHeight < 640;
        const controlsH = 60.0, bottomH = 72.0;
        final readoutH = compact ? 150.0 : 170.0;
        final minHeadstock = chromatic ? 0.0 : (compact ? 190.0 : 230.0);
        final gaugeRoom =
            box.maxHeight - controlsH - bottomH - readoutH - minHeadstock - 12;
        final widest = min(chromatic ? 400.0 : 360.0, box.maxWidth - 24);
        final gaugeW = min(max(gaugeRoom * 2.05, 200.0), widest);

        final meter = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: gaugeW,
              child: TunerGauge(cents: _reading.cents, status: _reading.status),
            ),
            const SizedBox(height: 4),
            _NoteReadout(
              reading: _reading,
              engine: _engine,
              listening: _listening,
              error: _error,
              toneOn: _toneOn,
              compact: compact,
            ),
          ],
        );

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: _TuningButton(
                      tuning: _engine.tuning,
                      chromatic: chromatic,
                      a4: _engine.a4,
                      onTap: _openTuningSheet,
                    ),
                  ),
                  if (!chromatic) ...[
                    const SizedBox(width: 10),
                    _AutoButton(on: _auto, onTap: _setAuto),
                  ],
                ],
              ),
            ),
            if (chromatic)
              Expanded(child: Center(child: meter))
            else ...[
              const SizedBox(height: 8),
              meter,
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 420,
                      maxHeight: 300,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: TunerHeadstock(
                        tuning: _engine.tuning,
                        active: _reading.stringIndex ?? _engine.lockedString,
                        tuned: _engine.tuned,
                        onPeg: _pickPeg,
                      ),
                    ),
                  ),
                ),
              ),
            ],
            _BottomBar(
              chromatic: chromatic,
              auto: _auto,
              allTuned: _engine.allTuned,
              toneOn: _toneOn,
              noteLabel: _engine.lockedString == null
                  ? null
                  : _engine.tuning.label(_engine.lockedString!),
              onPlay: _toneOn ? _stopReference : _playReference,
              onStartOver: _startOver,
            ),
          ],
        );
      },
    );
  }
}

// ── Pieces ──────────────────────────────────────────────────────────────────

class _TuningButton extends StatelessWidget {
  final GuitarTuning tuning;
  final bool chromatic;
  final double a4;
  final VoidCallback onTap;

  const _TuningButton({
    required this.tuning,
    required this.chromatic,
    required this.a4,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final calibrated = a4.round() != 440;
    return Material(
      color: c.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chromatic ? 'Chromatic' : tuning.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        [
                          chromatic ? 'Any note' : tuning.letters,
                          if (calibrated) 'A4 ${a4.round()} Hz',
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: 12.5,
                          letterSpacing: chromatic ? 0 : 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.expand_more_rounded, color: c.iconSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AutoButton extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  const _AutoButton({required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    return Semantics(
      button: true,
      toggled: on,
      label: 'Auto detect string',
      excludeSemantics: true,
      child: Material(
        color: on
            ? p.accent.withValues(alpha: p.dark ? 0.2 : 0.12)
            : c.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: on ? p.accent : c.border,
            width: on ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_rounded,
                    size: 17,
                    color: on ? p.accent : c.iconSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Auto',
                    style: TextStyle(
                      color: on ? c.textPrimary : c.textSecondary,
                      fontSize: 14,
                      fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Big note name, a status pill and the exact cents / Hz.
class _NoteReadout extends StatelessWidget {
  final TunerReading reading;
  final TunerEngine engine;
  final bool listening;
  final String? error;
  final bool toneOn;
  final bool compact;

  const _NoteReadout({
    required this.reading,
    required this.engine,
    required this.listening,
    required this.error,
    required this.toneOn,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    final tabular = [const FontFeature.tabularFigures()];
    final flats = engine.tuning.flats;

    // The note to show: what's being tuned, else the chosen string.
    final locked = engine.lockedString;
    final midi =
        reading.targetMidi ??
        (locked != null && !engine.chromatic
            ? engine.tuning.strings[locked]
            : null);
    final active = reading.active;

    final String hint;
    if (error != null) {
      hint = error!;
    } else if (toneOn) {
      hint = 'Listen, then play the string';
    } else if (!listening) {
      hint = 'Starting the microphone…';
    } else if (engine.chromatic) {
      hint = 'Play any note';
    } else if (locked != null) {
      hint = 'Play the ${engine.tuning.label(locked)} string';
    } else {
      hint = 'Pluck any string';
    }

    final (String statusText, IconData? statusIcon) = switch (reading.status) {
      TunerStatus.inTune => ('In tune', Icons.check_rounded),
      TunerStatus.flat => ('Tune up', Icons.arrow_upward_rounded),
      TunerStatus.sharp => ('Tune down', Icons.arrow_downward_rounded),
      TunerStatus.waiting => (hint, null),
    };
    final statusColor = active
        ? p.forStatus(reading.status, c)
        : c.textSecondary;
    final cents = reading.cents;

    return Semantics(
      liveRegion: true,
      label: active
          ? '${noteName(midi!, flats: flats)}, $statusText'
                '${cents != null ? ', ${cents.round()} cents' : ''}'
          : statusText,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: compact ? 76 : 96,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: active ? 1 : (midi == null ? 0.35 : 0.4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (midi == null)
                    Padding(
                      padding: EdgeInsets.only(bottom: compact ? 14 : 20),
                      child: Icon(
                        Icons.graphic_eq_rounded,
                        size: compact ? 48 : 60,
                        color: c.textSecondary,
                      ),
                    )
                  else
                    Text(
                      noteName(midi, flats: flats),
                      style: TextStyle(
                        color: active ? statusColor : c.textPrimary,
                        fontSize: compact ? 68 : 86,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                        letterSpacing: -2,
                      ),
                    ),
                  if (midi != null)
                    Padding(
                      padding: EdgeInsets.only(
                        left: 2,
                        bottom: compact ? 10 : 14,
                      ),
                      child: Text(
                        '${noteOctave(midi)}',
                        style: TextStyle(
                          color: c.textSecondary,
                          fontSize: compact ? 18 : 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 36,
            padding: EdgeInsets.symmetric(horizontal: active ? 14 : 4),
            decoration: BoxDecoration(
              color: active
                  ? statusColor.withValues(alpha: p.dark ? 0.16 : 0.1)
                  : null,
              borderRadius: BorderRadius.circular(18),
              border: active
                  ? Border.all(color: statusColor.withValues(alpha: 0.5))
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (statusIcon != null) ...[
                  Icon(statusIcon, size: 18, color: statusColor),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? statusColor : c.textSecondary,
                      fontSize: 15,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            active && cents != null && reading.hz != null
                ? '${cents >= 0 ? '+' : '−'}${cents.abs().toStringAsFixed(cents.abs() < 10 ? 1 : 0)} cents'
                      '  ·  ${reading.hz!.toStringAsFixed(1)} Hz'
                : ' ',
            style: TextStyle(
              color: c.textMuted,
              fontSize: 13,
              fontFeatures: tabular,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final bool chromatic;
  final bool auto;
  final bool allTuned;
  final bool toneOn;
  final String? noteLabel;
  final VoidCallback onPlay;
  final VoidCallback onStartOver;

  const _BottomBar({
    required this.chromatic,
    required this.auto,
    required this.allTuned,
    required this.toneOn,
    required this.noteLabel,
    required this.onPlay,
    required this.onStartOver,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    final Widget child;
    if (allTuned) {
      child = Container(
        key: const ValueKey('done'),
        height: 52,
        padding: const EdgeInsets.only(left: 16, right: 6),
        decoration: BoxDecoration(
          color: p.good.withValues(alpha: p.dark ? 0.14 : 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.good.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_rounded, color: p.good, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'All six strings in tune',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: onStartOver,
              child: Text(
                'Start over',
                style: TextStyle(color: p.good, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    } else if (!chromatic && !auto && noteLabel != null) {
      child = SizedBox(
        key: const ValueKey('play'),
        height: 52,
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPlay,
          icon: Icon(
            toneOn ? Icons.stop_rounded : Icons.volume_up_rounded,
            size: 20,
          ),
          label: Text(toneOn ? 'Stop' : 'Play $noteLabel again'),
          style: OutlinedButton.styleFrom(
            foregroundColor: c.textPrimary,
            side: BorderSide(color: c.border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            textStyle: TextStyle(
              fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    } else {
      child = SizedBox(
        key: ValueKey('hint$chromatic'),
        height: 52,
        child: Center(
          child: Text(
            chromatic
                ? 'Shows the nearest note for anything you play'
                : 'Tap a peg to tune one string and hear its note',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textMuted, fontSize: 13),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: child,
      ),
    );
  }
}

/// Tunings, chromatic mode and the A4 reference.
class _TuningSheet extends StatefulWidget {
  final GuitarTuning tuning;
  final bool chromatic;
  final double a4;
  final void Function({GuitarTuning? tuning, bool? chromatic, double? a4})
  onChanged;

  const _TuningSheet({
    required this.tuning,
    required this.chromatic,
    required this.a4,
    required this.onChanged,
  });

  @override
  State<_TuningSheet> createState() => _TuningSheetState();
}

class _TuningSheetState extends State<_TuningSheet> {
  late GuitarTuning _tuning = widget.tuning;
  late bool _chromatic = widget.chromatic;
  late int _a4 = widget.a4.round();

  void _pick(GuitarTuning? t) {
    Haptics.selection();
    setState(() {
      _chromatic = t == null;
      if (t != null) _tuning = t;
    });
    widget.onChanged(tuning: t, chromatic: t == null);
    Navigator.pop(context);
  }

  void _setA4(int v) {
    Haptics.selection();
    setState(() => _a4 = v.clamp(430, 450));
    widget.onChanged(a4: _a4.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final p = TunerPalette.of(context);
    final tabular = [const FontFeature.tabularFigures()];

    Widget row({
      required String title,
      required String subtitle,
      required bool selected,
      required VoidCallback onTap,
    }) => Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected
                ? p.accent.withValues(alpha: p.dark ? 0.16 : 0.1)
                : null,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12.5,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) Icon(Icons.check_rounded, color: p.accent),
            ],
          ),
        ),
      ),
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Text(
                'Tuning',
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final t in guitarTunings)
              row(
                title: t.name,
                subtitle: t.letters,
                selected: !_chromatic && t.id == _tuning.id,
                onTap: () => _pick(t),
              ),
            row(
              title: 'Chromatic',
              subtitle: 'Any note, any instrument',
              selected: _chromatic,
              onTap: () => _pick(null),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              decoration: BoxDecoration(
                color: c.surfaceElevated.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.borderSubtle),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Reference pitch',
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _a4 == 440
                              ? 'A4 = 440 Hz (standard)'
                              : 'A4 = $_a4 Hz',
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 12.5,
                            fontFeatures: tabular,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Lower',
                    onPressed: _a4 > 430 ? () => _setA4(_a4 - 1) : null,
                    icon: const Icon(Icons.remove_rounded),
                  ),
                  SizedBox(
                    width: 40,
                    child: Text(
                      '$_a4',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFeatures: tabular,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Raise',
                    onPressed: _a4 < 450 ? () => _setA4(_a4 + 1) : null,
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
            ),
            if (_a4 != 440)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _setA4(440),
                  child: const Text('Reset to 440 Hz'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
