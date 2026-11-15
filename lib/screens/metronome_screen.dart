import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../services/haptics.dart';
import '../services/metronome_presets.dart';
import '../theme/app_colors.dart';
import '../widgets/bpm_finder_sheet.dart';
import '../widgets/metronome_widgets.dart';

// ---------------------------------------------------------------------------
// WAV generator
// ---------------------------------------------------------------------------

Uint8List _buildSineWav({
  required int freqHz,
  int durationMs = 60,
  double amplitude = 0.5,
  double decayRate = 40.0,
  int sampleRate = 44100,
}) {
  final int numSamples = (sampleRate * durationMs / 1000).round();
  final int dataBytes = numSamples * 2; // 16-bit mono

  final ByteData header = ByteData(44);
  // RIFF chunk
  header.setUint8(0, 0x52); // R
  header.setUint8(1, 0x49); // I
  header.setUint8(2, 0x46); // F
  header.setUint8(3, 0x46); // F
  header.setUint32(4, 36 + dataBytes, Endian.little); // chunk size
  header.setUint8(8, 0x57); // W
  header.setUint8(9, 0x41); // A
  header.setUint8(10, 0x56); // V
  header.setUint8(11, 0x45); // E
  // fmt sub-chunk
  header.setUint8(12, 0x66); // f
  header.setUint8(13, 0x6D); // m
  header.setUint8(14, 0x74); // t
  header.setUint8(15, 0x20); // space
  header.setUint32(16, 16, Endian.little); // sub-chunk size
  header.setUint16(20, 1, Endian.little);  // PCM
  header.setUint16(22, 1, Endian.little);  // mono
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * 2, Endian.little); // byte rate
  header.setUint16(32, 2, Endian.little);  // block align
  header.setUint16(34, 16, Endian.little); // bits per sample
  // data sub-chunk
  header.setUint8(36, 0x64); // d
  header.setUint8(37, 0x61); // a
  header.setUint8(38, 0x74); // t
  header.setUint8(39, 0x61); // a
  header.setUint32(40, dataBytes, Endian.little);

  final Uint8List bytes = Uint8List(44 + dataBytes);
  bytes.setRange(0, 44, header.buffer.asUint8List());

  final ByteData samples = ByteData(dataBytes);
  for (int i = 0; i < numSamples; i++) {
    final double t = i / sampleRate;
    final double raw =
        sin(2 * pi * freqHz * t) * amplitude * exp(-decayRate * t) * 32767;
    final int sample = raw.round().clamp(-32768, 32767);
    samples.setInt16(i * 2, sample, Endian.little);
  }
  bytes.setRange(44, 44 + dataBytes, samples.buffer.asUint8List());
  return bytes;
}

// ---------------------------------------------------------------------------
// Tempo name helper
// ---------------------------------------------------------------------------

String _tempoName(int bpm) {
  if (bpm < 60) return 'Largo';
  if (bpm < 76) return 'Adagio';
  if (bpm < 108) return 'Andante';
  if (bpm < 120) return 'Moderato';
  if (bpm < 168) return 'Allegro';
  if (bpm < 200) return 'Presto';
  return 'Prestissimo';
}

// ---------------------------------------------------------------------------
// Screen widget
// ---------------------------------------------------------------------------

class MetronomeScreen extends StatefulWidget {
  const MetronomeScreen({
    super.key,
    @visibleForTesting this.debugSoundReady = false,
    @visibleForTesting this.clock,
    @visibleForTesting this.store,
    @visibleForTesting this.debugMicAudio,
  });

  /// Tests only: treat the click sounds as loaded (the audio engine doesn't
  /// exist under `flutter test`), so the play button is enabled.
  final bool debugSoundReady;

  /// Monotonic time source for click scheduling and tap timing. Defaults to
  /// a [Stopwatch]; widget tests pass the binding's fake clock.
  final Duration Function()? clock;

  /// Where saved tempos and the last-used setup live. Defaults to the app's
  /// settings table.
  final MetronomeStore? store;

  /// Feeds the BPM finder 16-bit PCM at 44.1 kHz instead of the microphone.
  final Stream<Uint8List>? debugMicAudio;

  @override
  State<MetronomeScreen> createState() => _MetronomeScreenState();
}

class _MetronomeScreenState extends State<MetronomeScreen> {
  static const int _minBpm = kMetronomeMinBpm;
  static const int _maxBpm = kMetronomeMaxBpm;

  static final List<(int, String)> _signatures = [
    for (final b in kMetronomeBeats) (b, metronomeSignatureLabel(b)),
  ];

  // BPM, signature, subdivision
  int _bpm = 120;
  int _beatsPerBar = 4;
  MetronomeSubdivision _subdivision = MetronomeSubdivision.none;

  MetronomeSetup get _setup => MetronomeSetup(
    bpm: _bpm,
    beatsPerBar: _beatsPerBar,
    subdivision: _subdivision,
  );

  // Playback state
  bool _running = false;
  bool _flash = false;
  int _lastBeat = -1;

  // Click scheduling: sub-tick [_tick] sounds at
  // `_startedAt + clickTimeMicros(_tick)`. Every wait is measured against
  // that fixed origin, so neither timer lateness nor rounding accumulates.
  final Stopwatch _stopwatch = Stopwatch()..start();
  Timer? _timer;
  Timer? _flashTimer;
  int _tick = 0;
  Duration _startedAt = Duration.zero;

  // Audio
  AudioSource? _clickSrc;
  AudioSource? _accentSrc;
  AudioSource? _subSrc;
  late bool _soundReady = widget.debugSoundReady;

  // Saved tempos / last-used setup
  late final MetronomeStore _store = widget.store ?? const SettingsMetronomeStore();
  List<MetronomePreset> _presets = [];
  bool _touched = false; // the user changed something before the load landed
  Timer? _saveTimer;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _initSounds();
    _load();
  }

  Future<void> _initSounds() async {
    try {
      _clickSrc = await SoLoud.instance.loadMem(
        'metro_click',
        _buildSineWav(freqHz: 1000, amplitude: 0.45, decayRate: 45),
      );
      _accentSrc = await SoLoud.instance.loadMem(
        'metro_accent',
        _buildSineWav(freqHz: 1500, amplitude: 0.70, decayRate: 35),
      );
      // Subdivisions: lower, quieter and shorter than the beat click.
      _subSrc = await SoLoud.instance.loadMem(
        'metro_sub',
        _buildSineWav(freqHz: 700, durationMs: 40, amplitude: 0.26, decayRate: 70),
      );
      if (mounted) setState(() => _soundReady = true);
    } catch (_) {
      // Sound init failed — UI stays disabled
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _flashTimer?.cancel();
    if (_saveTimer?.isActive ?? false) {
      _saveTimer!.cancel();
      _saveLast();
    }
    for (final src in [_clickSrc, _accentSrc, _subSrc]) {
      try {
        if (src != null) SoLoud.instance.disposeSource(src);
      } catch (_) {}
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Persistence (failures are silent: the metronome works without storage)
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    List<MetronomePreset> presets;
    MetronomeSetup? last;
    try {
      presets = decodePresets(await _store.read(MetronomeStore.presetsKey));
      last = decodeSetup(await _store.read(MetronomeStore.lastKey));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() {
      if (_presets.isEmpty) _presets = presets;
      if (last != null && !_touched && !_running) {
        _bpm = last.bpm;
        _beatsPerBar = last.beatsPerBar;
        _subdivision = last.subdivision;
      }
    });
  }

  /// Notes a change by the user and saves the setup shortly after.
  void _changed() {
    _touched = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveLast);
  }

  void _saveLast() {
    try {
      _store
          .write(MetronomeStore.lastKey, encodeSetup(_setup))
          .then((_) {}, onError: (Object _) {});
    } catch (_) {}
  }

  void _savePresets() {
    try {
      _store
          .write(MetronomeStore.presetsKey, encodePresets(_presets))
          .then((_) {}, onError: (Object _) {});
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Click scheduling
  // ---------------------------------------------------------------------------

  Duration _now() => widget.clock?.call() ?? _stopwatch.elapsed;

  void _fire() {
    if (!_running) return;
    final cpb = _subdivision.clicksPerBeat;
    final kind = clickKindAt(_tick, beatsPerBar: _beatsPerBar, clicksPerBeat: cpb);
    // Sound first: nothing else should sit between the timer and the click.
    final src = switch (kind) {
      ClickKind.accent => _accentSrc,
      ClickKind.beat => _clickSrc,
      ClickKind.sub => _subSrc,
    };
    if (src != null) {
      try {
        SoLoud.instance.play(src);
      } catch (_) {}
    }
    // Only beats touch the UI; sub-clicks (up to 16 a second) just sound.
    if (kind != ClickKind.sub) {
      final beat = beatAt(_tick, beatsPerBar: _beatsPerBar, clicksPerBeat: cpb);
      if (beat == 0) Haptics.medium();
      setState(() {
        _lastBeat = beat;
        _flash = true;
      });
      _flashTimer?.cancel();
      _flashTimer = Timer(const Duration(milliseconds: 100), () {
        if (mounted) setState(() => _flash = false);
      });
    }
    _tick++;
    _scheduleNext();
  }

  void _scheduleNext() {
    final cpb = _subdivision.clicksPerBeat;
    final due = clickTimeMicros(_tick, bpm: _bpm, clicksPerBeat: cpb);
    var wait = due - (_now() - _startedAt).inMicroseconds;
    // Far behind (the app was suspended): carry on from now rather than
    // rattling through the missed clicks.
    if (wait < -clickTimeMicros(1, bpm: _bpm, clicksPerBeat: cpb)) {
      _startedAt += Duration(microseconds: -wait);
      wait = 0;
    }
    // Timers have millisecond resolution; round to the nearest.
    _timer = Timer(Duration(milliseconds: (max(0, wait) + 500) ~/ 1000), _fire);
  }

  void _begin() {
    _timer?.cancel();
    _tick = 0;
    _startedAt = _now();
    _fire();
  }

  void _start() {
    setState(() => _running = true);
    _begin();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _flashTimer?.cancel();
    setState(() {
      _running = false;
      _flash = false;
      _lastBeat = -1;
    });
  }

  void _restartIfRunning() {
    if (_running) _begin();
  }

  // ---------------------------------------------------------------------------
  // Tempo changes
  // ---------------------------------------------------------------------------

  /// −/+ buttons: one BPM per step. The metronome restarts on commit (tap, or
  /// release after press-and-hold) rather than on every repeated step.
  void _nudge(int delta) {
    final next = (_bpm + delta).clamp(_minBpm, _maxBpm);
    if (next == _bpm) return;
    Haptics.selection();
    setState(() => _bpm = next);
    _changed();
  }

  void _apply(MetronomeSetup setup) {
    setState(() {
      _bpm = setup.bpm.clamp(_minBpm, _maxBpm);
      _beatsPerBar = setup.beatsPerBar;
      _subdivision = setup.subdivision;
    });
    _changed();
    _restartIfRunning();
  }

  /// Opens the BPM finder. The metronome is stopped first — the microphone
  /// would hear its clicks — and stays stopped afterwards.
  Future<void> _openFinder() async {
    Haptics.light();
    if (_running) _stop();
    final bpm = await showBpmFinderSheet(
      context,
      clock: widget.clock,
      debugAudio: widget.debugMicAudio,
    );
    if (bpm == null || !mounted) return;
    setState(() => _bpm = bpm.clamp(_minBpm, _maxBpm));
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Saved tempos
  // ---------------------------------------------------------------------------

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _savePreset() async {
    Haptics.light();
    if (_presets.length >= kMetronomeMaxPresets) {
      _snack('You can keep up to $kMetronomeMaxPresets tempos. Delete one to save another.');
      return;
    }
    final setup = _setup;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: 'Save tempo',
        detail: setup.summary,
        action: 'Save',
      ),
    );
    if (name == null || !mounted) return;
    setState(() {
      _presets = [MetronomePreset(name: cleanPresetName(name), setup: setup), ..._presets];
    });
    _savePresets();
  }

  Future<void> _presetMenu(int index) async {
    Haptics.medium();
    final preset = _presets[index];
    final c = Theme.of(context).extension<AppColors>()!;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: c.handleBar,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                preset.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                preset.setup.summary,
                style: TextStyle(color: c.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(Icons.edit_rounded, color: c.textPrimary),
                title: Text('Rename', style: TextStyle(color: c.textPrimary)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                onTap: () => Navigator.of(context).pop('rename'),
              ),
              ListTile(
                leading: Icon(Icons.delete_outline_rounded,
                    color: Theme.of(context).colorScheme.error),
                title: Text('Delete',
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                onTap: () => Navigator.of(context).pop('delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    // The list can't have changed under a modal sheet, but stay safe.
    final at = _presets.indexOf(preset);
    if (at < 0) return;
    if (action == 'delete') {
      setState(() => _presets = [..._presets]..removeAt(at));
      _savePresets();
      _snack('Deleted “${preset.title}”');
    } else {
      final name = await showDialog<String>(
        context: context,
        builder: (_) => _NameDialog(
          title: 'Rename tempo',
          detail: preset.setup.summary,
          initial: preset.name,
          action: 'Rename',
        ),
      );
      if (name == null || !mounted) return;
      final now = _presets.indexOf(preset);
      if (now < 0) return;
      setState(() => _presets = [..._presets]..[now] = preset.renamed(name));
      _savePresets();
    }
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    final tabular = [const FontFeature.tabularFigures()];
    final sliderTint = metronomeStroke(context, lightDarken: 0.2);

    return Scaffold(
      backgroundColor: c.scaffoldBg,
      appBar: AppBar(
        title: const Text(
          'Metronome',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 20),
                    MetronomeBeatDots(
                      beatsPerBar: _beatsPerBar,
                      currentBeat: _running ? _lastBeat : -1,
                      pulse: _flash,
                    ),
                    const SizedBox(height: 24),

                    // ── BPM ──────────────────────────────────────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        MetronomeStepButton(
                          icon: Icons.remove_rounded,
                          tooltip: 'Slower',
                          onStep: _bpm > _minBpm ? () => _nudge(-1) : null,
                          onCommit: _restartIfRunning,
                        ),
                        const SizedBox(width: 18),
                        SizedBox(
                          width: 170,
                          child: Semantics(
                            label: '$_bpm BPM, ${_tempoName(_bpm)}',
                            excludeSemantics: true,
                            child: Column(
                              children: [
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    '$_bpm',
                                    style: TextStyle(
                                      color: c.textPrimary,
                                      fontSize: 92,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -3,
                                      height: 1.0,
                                      fontFeatures: tabular,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'BPM · ${_tempoName(_bpm)}',
                                  style: TextStyle(
                                    color: c.textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        MetronomeStepButton(
                          icon: Icons.add_rounded,
                          tooltip: 'Faster',
                          onStep: _bpm < _maxBpm ? () => _nudge(1) : null,
                          onCommit: _restartIfRunning,
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // ── Tempo slider ─────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text('$_minBpm',
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: tabular,
                                )),
                          ),
                          Text('$_maxBpm',
                              style: TextStyle(
                                color: c.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                fontFeatures: tabular,
                              )),
                        ],
                      ),
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: sliderTint,
                        inactiveTrackColor: light ? c.border : c.surfaceElevated,
                        thumbColor: sliderTint,
                        overlayColor: kMetronomeTint.withValues(alpha: 0.18),
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                      ),
                      child: Slider(
                        value: _bpm.toDouble(),
                        min: _minBpm.toDouble(),
                        max: _maxBpm.toDouble(),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                        semanticFormatterCallback: (v) => '${v.round()} BPM',
                        onChanged: (v) {
                          setState(() => _bpm = v.round());
                          _changed();
                        },
                        onChangeEnd: (_) => _restartIfRunning(),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // ── Saved tempos ─────────────────────────────────────
                    MetronomePresetRow(
                      presets: _presets,
                      current: _setup,
                      onSave: _savePreset,
                      onLoad: (i) {
                        Haptics.selection();
                        _apply(_presets[i].setup);
                      },
                      onMenu: _presetMenu,
                    ),
                    const SizedBox(height: 16),

                    // ── Time signature ───────────────────────────────────
                    const MetronomeSectionLabel('TIME SIGNATURE'),
                    MetronomeSignaturePicker(
                      options: _signatures,
                      selected: _beatsPerBar,
                      onSelect: (beats) {
                        Haptics.selection();
                        setState(() => _beatsPerBar = beats);
                        _changed();
                        _restartIfRunning();
                      },
                    ),
                    const SizedBox(height: 14),

                    // ── Subdivision ──────────────────────────────────────
                    const MetronomeSectionLabel('SUBDIVISION'),
                    MetronomeSubdivisionPicker(
                      selected: _subdivision,
                      onSelect: (s) {
                        Haptics.selection();
                        setState(() => _subdivision = s);
                        _changed();
                        _restartIfRunning();
                      },
                    ),
                    const SizedBox(height: 14),

                    // ── Find BPM ─────────────────────────────────────────
                    MetronomeFindBpmPad(onTap: _openFinder),
                  ],
                ),
              ),
            ),

            // ── Play / stop ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
              child: MetronomePlayButton(
                running: _running,
                onPressed: _soundReady
                    ? () {
                        if (_running) {
                          _stop();
                        } else {
                          _start();
                        }
                      }
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a preset's name. Pops with the text (possibly empty — the chip
/// then shows the tempo), or null if cancelled.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.detail,
    required this.action,
    this.initial = '',
  });

  final String title;
  final String detail;
  final String action;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    final tint = metronomeStroke(context, lightDarken: 0.45);
    return AlertDialog(
      backgroundColor: c.surfaceCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text(
        widget.title,
        style: TextStyle(color: c.textPrimary, fontSize: 19, fontWeight: FontWeight.w700),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.detail, style: TextStyle(color: c.textSecondary, fontSize: 14)),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: kMetronomePresetNameMax,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            cursorColor: tint,
            style: TextStyle(color: c.textPrimary, fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Name (optional)',
              hintStyle: TextStyle(color: c.textMuted),
              counterStyle: TextStyle(color: c.textMuted, fontSize: 11),
              filled: true,
              fillColor: c.scaffoldBg,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: c.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: tint, width: 1.5),
              ),
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(
            foregroundColor: c.textSecondary,
            textStyle: TextStyle(fontFamily: font, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: kMetronomeTint,
            foregroundColor: kMetronomeInk,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            textStyle: TextStyle(fontFamily: font, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          child: Text(widget.action),
        ),
      ],
    );
  }
}
