import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'clip_editor_screen.dart';

enum _RecordState { idle, recording, processing, stopped }

const _kSampleRate = 44100;
const _kChannels = 1;
const _kBitsPerSample = 16;
const _kBarCount = 30;

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  final _recorder = AudioRecorder();

  _RecordState _state = _RecordState.idle;
  String? _tempPcmPath;
  String? _wavPath;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;

  // Rolling amplitude history — oldest at index 0, newest at end
  final List<double> _ampHistory = List.filled(_kBarCount, 0.0, growable: true);
  StreamSubscription<Uint8List>? _streamSub;
  IOSink? _pcmSink;
  Completer<void>? _streamDone;

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _streamSub?.cancel();
    _pcmSink?.close();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (!status.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is required')),
      );
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final clipsDir = Directory(p.join(dir.path, 'clips'));
    await clipsDir.create(recursive: true);

    final ts = DateTime.now().millisecondsSinceEpoch;
    _tempPcmPath = p.join(clipsDir.path, 'temp_$ts.pcm');

    _pcmSink = File(_tempPcmPath!).openWrite();
    _streamDone = Completer<void>();

    // startStream gives us raw PCM chunks — we write to file AND compute
    // RMS amplitude from the actual sample data, which is always accurate.
    final audioStream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _kSampleRate,
        numChannels: _kChannels,
      ),
    );

    _streamSub = audioStream.listen(
      (chunk) {
        _pcmSink?.add(chunk);
        _pushAmplitude(chunk);
      },
      onDone: () async {
        await _pcmSink?.flush();
        await _pcmSink?.close();
        _pcmSink = null;
        if (!(_streamDone?.isCompleted ?? true)) _streamDone!.complete();
      },
      onError: (e) {
        if (!(_streamDone?.isCompleted ?? true)) _streamDone!.completeError(e);
      },
    );

    _elapsed = Duration.zero;
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });

    setState(() => _state = _RecordState.recording);
  }

  // Compute true RMS from raw 16-bit little-endian PCM and push to history.
  void _pushAmplitude(Uint8List chunk) {
    final n = chunk.length ~/ 2;
    if (n == 0) return;
    var sumSq = 0.0;
    for (var i = 0; i < n * 2; i += 2) {
      var s = chunk[i] | (chunk[i + 1] << 8);
      if (s > 32767) s -= 65536; // unsigned → signed
      sumSq += s * s;
    }
    final rms = (sqrt(sumSq / n) / 32768.0).clamp(0.0, 1.0);
    if (mounted) {
      setState(() {
        _ampHistory.removeAt(0);
        _ampHistory.add(rms);
      });
    }
  }

  Future<void> _stopRecording() async {
    _elapsedTimer?.cancel();
    setState(() => _state = _RecordState.processing);

    await _recorder.stop();

    // Wait for stream's onDone to flush+close the file (3 s safety timeout)
    try {
      await _streamDone?.future.timeout(const Duration(seconds: 3));
    } catch (_) {
      await _pcmSink?.flush();
      await _pcmSink?.close();
      _pcmSink = null;
    }
    await _streamSub?.cancel();
    _streamSub = null;

    if (_tempPcmPath != null) {
      final wavPath = _tempPcmPath!.replaceAll('.pcm', '.wav');
      await _buildWavFile(_tempPcmPath!, wavPath);
      await File(_tempPcmPath!).delete();
      _wavPath = wavPath;
    }

    if (mounted) setState(() => _state = _RecordState.stopped);
  }

  Future<void> _discard() async {
    if (_wavPath != null) {
      final f = File(_wavPath!);
      if (await f.exists()) await f.delete();
    }
    if (_tempPcmPath != null) {
      final f = File(_tempPcmPath!);
      if (await f.exists()) await f.delete();
    }
    if (mounted) Navigator.pop(context);
  }

  static Future<void> _buildWavFile(String pcmPath, String wavPath) async {
    final pcm = await File(pcmPath).readAsBytes();
    final dataSize = pcm.length;
    final header = ByteData(44);

    void str(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    header.setUint32(4, 36 + dataSize, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, _kChannels, Endian.little);
    header.setUint32(24, _kSampleRate, Endian.little);
    header.setUint32(28, _kSampleRate * _kChannels * _kBitsPerSample ~/ 8, Endian.little);
    header.setUint16(32, _kChannels * _kBitsPerSample ~/ 8, Endian.little);
    header.setUint16(34, _kBitsPerSample, Endian.little);
    str(36, 'data');
    header.setUint32(40, dataSize, Endian.little);

    final out = File(wavPath).openWrite();
    out.add(header.buffer.asUint8List());
    out.add(pcm);
    await out.flush();
    await out.close();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0E0E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0E0E),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          'Record Clip',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 20,
            letterSpacing: -0.4,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white70),
          onPressed:
              _state == _RecordState.recording || _state == _RecordState.processing
                  ? null
                  : _discard,
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Spacer(flex: 2),
          Center(
            child: Text(
              _formatDuration(_elapsed),
              style: TextStyle(
                fontSize: 72,
                fontWeight: FontWeight.w200,
                letterSpacing: -4,
                color: _state == _RecordState.recording
                    ? Colors.redAccent
                    : Colors.white24,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Center(
            child: Text(
              switch (_state) {
                _RecordState.idle       => 'Tap to start',
                _RecordState.recording  => 'Recording...',
                _RecordState.processing => 'Processing...',
                _RecordState.stopped    => 'Done',
              },
              style: TextStyle(
                fontSize: 14,
                letterSpacing: 0.4,
                color: _state == _RecordState.recording
                    ? Colors.redAccent.withValues(alpha: 0.7)
                    : Colors.white38,
              ),
            ),
          ),
          const Spacer(),
          // Live amplitude bars driven by real RMS values
          SizedBox(
            height: 80,
            child: _state == _RecordState.recording
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: List.generate(_kBarCount, (i) {
                      final amp = _ampHistory[i];
                      final height = 4.0 + amp * 64.0;
                      // Older bars dimmer, newer bars brighter
                      final alpha = 0.25 + (i / _kBarCount) * 0.75;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 80),
                        width: 4,
                        height: height,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: alpha),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  )
                : const SizedBox.shrink(),
          ),
          const Spacer(flex: 2),
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 64),
              child: _state == _RecordState.stopped
                  ? _PostRecordControls(
                      onDiscard: _discard,
                      onEdit: () async {
                        final navigator = Navigator.of(context);
                        final saved = await navigator.push<bool>(
                          MaterialPageRoute(
                            builder: (_) =>
                                ClipEditorScreen(filePath: _wavPath!),
                          ),
                        );
                        if (!mounted) return;
                        navigator.pop(saved == true);
                      },
                    )
                  : _RecordButton(
                      state: _state,
                      onTap: switch (_state) {
                        _RecordState.idle      => _startRecording,
                        _RecordState.recording => _stopRecording,
                        _              => null,
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  final _RecordState state;
  final VoidCallback? onTap;
  const _RecordButton({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isRecording = state == _RecordState.recording;
    final isProcessing = state == _RecordState.processing;
    final color = isRecording ? Colors.redAccent : const Color(0xFF6C63FF);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isProcessing ? const Color(0xFF1E1E1E) : color,
          boxShadow: isProcessing
              ? null
              : [
                  BoxShadow(
                    color: color.withValues(alpha: 0.4),
                    blurRadius: 28,
                    spreadRadius: 4,
                  )
                ],
        ),
        child: isProcessing
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white38),
              )
            : Icon(
                isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                color: Colors.white,
                size: 38,
              ),
      ),
    );
  }
}

class _PostRecordControls extends StatelessWidget {
  final VoidCallback onDiscard;
  final VoidCallback onEdit;
  const _PostRecordControls(
      {required this.onDiscard, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ActionChip(
          icon: Icons.delete_outline_rounded,
          label: 'Discard',
          color: Colors.redAccent,
          onTap: onDiscard,
        ),
        const SizedBox(width: 48),
        _ActionChip(
          icon: Icons.tune_rounded,
          label: 'Edit & Save',
          color: const Color(0xFF6C63FF),
          onTap: onEdit,
        ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionChip(
      {required this.icon,
      required this.label,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Icon(icon, color: color, size: 30),
          ),
          const SizedBox(height: 10),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
