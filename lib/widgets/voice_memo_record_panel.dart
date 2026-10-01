import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'voice_memo_tiles.dart';
import 'waveform_bars.dart';

enum VoiceMemoRecordState { idle, recording, saving }

/// The big round record button pinned to the bottom of the Voice memos screen,
/// with its caption and — while recording — the live level meter and timer.
class VoiceMemoRecordPanel extends StatefulWidget {
  final VoiceMemoRecordState state;
  final Duration elapsed;

  /// Recent input levels (0..1), oldest first. Shown while recording.
  final List<double> levels;
  final VoidCallback onTap;

  const VoiceMemoRecordPanel({
    super.key,
    required this.state,
    required this.elapsed,
    required this.levels,
    required this.onTap,
  });

  @override
  State<VoiceMemoRecordPanel> createState() => _VoiceMemoRecordPanelState();
}

class _VoiceMemoRecordPanelState extends State<VoiceMemoRecordPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _scale = Tween<double>(begin: 1, end: 1.06)
      .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    _syncPulse();
  }

  @override
  void didUpdateWidget(VoiceMemoRecordPanel old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) _syncPulse();
  }

  void _syncPulse() {
    if (widget.state == VoiceMemoRecordState.recording) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    const rec = kVoiceMemoRecordTint;
    final recText = light ? Color.lerp(rec, Colors.black, 0.45)! : rec;
    final ink = Color.lerp(rec, Colors.black, 0.78)!;
    final recording = widget.state == VoiceMemoRecordState.recording;
    final saving = widget.state == VoiceMemoRecordState.saving;

    final caption = switch (widget.state) {
      VoiceMemoRecordState.idle => 'Tap to record',
      VoiceMemoRecordState.recording => 'Recording · tap to stop',
      VoiceMemoRecordState.saving => 'Saving…',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: recording
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          label: 'Recording time',
                          child: Text(
                            _clock(widget.elapsed),
                            style: TextStyle(
                              color: recText,
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ExcludeSemantics(
                          child: SizedBox(
                            width: 200,
                            child: WaveformBars(
                              levels: widget.levels,
                              progress: 1,
                              activeColor: rec,
                              idleColor: rec,
                              height: 36,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          ScaleTransition(
            scale: _scale,
            child: Container(
              width: 84,
              height: 84,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: rec.withValues(alpha: 0.35),
                boxShadow: [
                  BoxShadow(
                    color: rec.withValues(alpha: recording ? 0.32 : 0.2),
                    blurRadius: 28,
                    spreadRadius: -6,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Material(
                color: rec,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: saving ? null : widget.onTap,
                  child: Semantics(
                    button: true,
                    label: recording ? 'Stop recording' : 'Record a memo',
                    child: Center(
                      child: saving
                          ? SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                valueColor: AlwaysStoppedAnimation(ink),
                              ),
                            )
                          : AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOutCubic,
                              width: recording ? 26 : 30,
                              height: recording ? 26 : 30,
                              decoration: BoxDecoration(
                                color: ink,
                                borderRadius:
                                    BorderRadius.circular(recording ? 7 : 15),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            caption,
            style: TextStyle(color: c.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
