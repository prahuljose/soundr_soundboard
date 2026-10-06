import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

import 'wav.dart';

/// What the speaker cleaner is shaking out.
enum CleanMode { water, dust }

/// Tone programs for the speaker cleaner, generated as samples.
///
/// * **Water**: a ~165 Hz sine — close to the resonance of small phone
///   speakers, where the membrane moves the most — that wobbles slowly
///   between 160 and 180 Hz and pulses (0.9 s on, 0.3 s off) so the cone
///   keeps kicking water out of the grille.
/// * **Dust**: log sweeps 200 → 1500 → 200 Hz every 3.5 s, the band where
///   the membrane moves with the most force, to shake loose dust and lint.
///
/// Both run at [peak] full scale with [edgeFade] fades at the ends, so the
/// first and last samples are silent (no click).
class CleanerTones {
  CleanerTones._();

  static const sampleRate = 44100;
  static const peak = 0.95;
  static const edgeFade = Duration(milliseconds: 20);

  // Water.
  static const waterCenterHz = 170.0;
  static const waterWobbleHz = 10.0; // ± around the centre → 160..180 Hz
  static const waterWobblePeriod = 4.8; // s (four pulses)
  static const waterPulsePeriod = 1.2; // s
  static const waterPulseOn = 0.9; // s
  static const _waterAttack = 0.04; // s
  static const _waterRelease = 0.08; // s

  // Dust.
  static const dustLowHz = 200.0;
  static const dustHighHz = 1500.0;
  static const dustSweepPeriod = 3.5; // s for low → high → low

  /// Default run length and the Quick / Normal / Deep choices per mode.
  static List<Duration> lengths(CleanMode mode) => switch (mode) {
    CleanMode.water => const [
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
    CleanMode.dust => const [
      Duration(seconds: 10),
      Duration(seconds: 20),
      Duration(seconds: 40),
    ],
  };

  static Duration defaultLength(CleanMode mode) => lengths(mode)[1];

  /// Seconds between the bursts the UI animates, in time with the audio.
  static double burstPeriod(CleanMode mode) => switch (mode) {
    CleanMode.water => waterPulsePeriod,
    CleanMode.dust => dustSweepPeriod / 4,
  };

  /// 0..1 "intensity" at [t] seconds into a program, for animating in time
  /// with the sound: the pulse envelope for water, the sweep position for
  /// dust (1 = top of the sweep).
  static double intensityAt(CleanMode mode, double t) => switch (mode) {
    CleanMode.water => _waterPulse(t),
    CleanMode.dust => _dustPosition(t),
  };

  /// The instantaneous frequency at [t] seconds. Public for tests and UI.
  static double frequencyAt(CleanMode mode, double t) => switch (mode) {
    CleanMode.water =>
      waterCenterHz + waterWobbleHz * sin(2 * pi * t / waterWobblePeriod),
    CleanMode.dust =>
      dustLowHz * pow(dustHighHz / dustLowHz, _dustPosition(t)).toDouble(),
  };

  /// Smooth on/off pulse: raised-cosine attack, hold, raised-cosine release,
  /// then silence until the next pulse.
  static double _waterPulse(double t) {
    final p = t % waterPulsePeriod;
    if (p < _waterAttack) return 0.5 - 0.5 * cos(pi * p / _waterAttack);
    final releaseAt = waterPulseOn - _waterRelease;
    if (p < releaseAt) return 1;
    if (p < waterPulseOn) {
      return 0.5 + 0.5 * cos(pi * (p - releaseAt) / _waterRelease);
    }
    return 0;
  }

  /// 0 → 1 → 0 over one sweep, eased at the turnarounds.
  static double _dustPosition(double t) =>
      0.5 - 0.5 * cos(2 * pi * (t % dustSweepPeriod) / dustSweepPeriod);

  /// The full program as samples in -1..1, exactly [length] long.
  static Float64List program(CleanMode mode, Duration length) {
    final n = sampleRate * length.inMicroseconds ~/ 1000000;
    final out = Float64List(n);
    final fade = sampleRate * edgeFade.inMicroseconds ~/ 1000000;
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / sampleRate;
      var env = mode == CleanMode.water ? _waterPulse(t) : 1.0;
      if (i < fade) env *= 0.5 - 0.5 * cos(pi * i / fade);
      final fromEnd = n - 1 - i;
      if (fromEnd < fade) env *= 0.5 - 0.5 * cos(pi * fromEnd / fade);
      out[i] = peak * env * sin(phase);
      phase += 2 * pi * frequencyAt(mode, t) / sampleRate;
      if (phase > 2 * pi) phase -= 2 * pi;
    }
    return out;
  }

  /// [program] as a 16-bit mono WAV.
  static Uint8List wav(CleanMode mode, Duration length) =>
      Wav.encode(program(mode, length), sampleRate: sampleRate);
}

/// Plays cleaner programs through SoLoud at full volume.
///
/// Silent no-op when the audio engine isn't initialised (tests); the
/// screen runs its countdown either way.
class CleanerPlayer {
  // Programs are big (60 s ≈ 10 MB once decoded), so only the two most
  // recently used stay loaded.
  static const _keep = 2;

  final Map<String, Future<AudioSource?>> _sources = {};
  SoundHandle? _handle;
  int _gen = 0;
  bool _disposed = false;

  static bool get available {
    try {
      return SoLoud.instance.isInitialized;
    } catch (_) {
      return false;
    }
  }

  static String _key(CleanMode mode, Duration length) =>
      '${mode.name}_${length.inSeconds}';

  /// Generates and loads a program ahead of time so [play] starts at once.
  Future<AudioSource?> prepare(CleanMode mode, Duration length) {
    if (_disposed || !available) return Future.value(null);
    final key = _key(mode, length);
    final existing = _sources.remove(key);
    if (existing != null) {
      _sources[key] = existing; // most recently used goes last
      return existing;
    }
    final future = _load(key, mode, length);
    _sources[key] = future;
    while (_sources.length > _keep) {
      final oldest = _sources.keys.first;
      _free(_sources.remove(oldest)!);
    }
    return future;
  }

  Future<AudioSource?> _load(
    String key,
    CleanMode mode,
    Duration length,
  ) async {
    try {
      final bytes = await _render(mode, length);
      if (_disposed) return null;
      final src = await SoLoud.instance.loadMem('cleaner_$key.wav', bytes);
      if (_disposed || !_sources.containsKey(key)) {
        SoLoud.instance.disposeSource(src).ignore();
        return null;
      }
      return src;
    } catch (_) {
      _sources.remove(key);
      return null;
    }
  }

  // Static so the isolate closure captures nothing but its arguments.
  static Future<Uint8List> _render(CleanMode mode, Duration length) =>
      Isolate.run(() => CleanerTones.wav(mode, length));

  void _free(Future<AudioSource?> source) {
    source.then((s) {
      if (s == null) return;
      try {
        SoLoud.instance.disposeSource(s).ignore();
      } catch (_) {}
    });
  }

  /// Starts [mode] for [length]; any program already playing fades out.
  /// Completes once the sound is playing (or straight away without audio).
  Future<void> play(CleanMode mode, Duration length) async {
    stop();
    final gen = ++_gen;
    final src = await prepare(mode, length);
    if (src == null || gen != _gen || _disposed) return;
    try {
      _handle = await SoLoud.instance.play(src, volume: 1.0);
      if (gen != _gen || _disposed) stop();
    } catch (_) {}
  }

  /// Fades out over [fade] rather than cutting off.
  void stop({Duration fade = const Duration(milliseconds: 150)}) {
    _gen++;
    final h = _handle;
    _handle = null;
    if (h == null) return;
    try {
      SoLoud.instance.fadeVolume(h, 0, fade);
      SoLoud.instance.scheduleStop(h, fade);
    } catch (_) {}
  }

  /// Forgets the playing program without stopping it (it ended by itself).
  void release() => _handle = null;

  void dispose() {
    stop();
    _disposed = true;
    for (final s in _sources.values) {
      _free(s);
    }
    _sources.clear();
  }
}
