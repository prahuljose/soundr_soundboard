import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'waveform_bars.dart';

/// Voice memo tool tint.
const kVoiceMemoTint = Color(0xFF7CC8FF);

/// Recording red used by the record button.
const kVoiceMemoRecordTint = Color(0xFFFF8FA3);

const _tabular = [FontFeature.tabularFigures()];

bool _isLight(BuildContext context) =>
    Theme.of(context).brightness == Brightness.light;

/// [kVoiceMemoTint] darkened for text on a light background.
Color voiceMemoTintText(BuildContext context) => _isLight(context)
    ? Color.lerp(kVoiceMemoTint, Colors.black, 0.45)!
    : kVoiceMemoTint;

/// Dark ink for content drawn on a tint fill.
final Color _ink = Color.lerp(kVoiceMemoTint, Colors.black, 0.78)!;

// ── Compact row ──────────────────────────────────────────────────────────────

/// A memo that isn't the current one: play button, title, date, a small
/// waveform and the duration. Tapping the row opens it without playing.
class VoiceMemoRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final String duration;
  final List<double> levels;
  final VoidCallback onPlay;
  final VoidCallback onOpen;

  const VoiceMemoRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.duration,
    required this.levels,
    required this.onPlay,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = _isLight(context);
    final bars = light
        ? Color.lerp(kVoiceMemoTint, Colors.black, 0.2)!.withValues(alpha: 0.7)
        : kVoiceMemoTint.withValues(alpha: 0.55);

    return Material(
      color: c.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: SizedBox(
          height: 72,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(children: [
              Material(
                color: c.surfaceElevated.withValues(alpha: light ? 0.7 : 1),
                shape: CircleBorder(side: BorderSide(color: c.border)),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: onPlay,
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: c.textPrimary,
                      size: 22,
                      semanticLabel: 'Play $title',
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textSecondary, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: SizedBox(
                  width: 46,
                  child: WaveformBars(
                    levels: levels,
                    activeColor: bars,
                    idleColor: bars,
                    height: 26,
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  duration,
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    fontFeatures: _tabular,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Expanded player card ─────────────────────────────────────────────────────

/// The open memo: transport, a seekable waveform that fills as it plays,
/// and the memo's actions.
class VoiceMemoPlayerCard extends StatelessWidget {
  final String title;
  final String subtitle;

  /// Player is prepared and can play/seek.
  final bool ready;
  final bool playing;

  /// Playback finished; the main button replays from the start.
  final bool atEnd;
  final int positionMs;
  final int totalMs;
  final List<double> levels;

  /// Null hides the speed chip.
  final double? speed;
  final VoidCallback? onCycleSpeed;

  final VoidCallback onPlayPause;
  final ValueChanged<double> onSeek;
  final VoidCallback onCollapse;
  final VoidCallback onRestart;
  final VoidCallback onAddToSoundboard;
  final VoidCallback onShare;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const VoiceMemoPlayerCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.ready,
    required this.playing,
    required this.atEnd,
    required this.positionMs,
    required this.totalMs,
    required this.levels,
    required this.onPlayPause,
    required this.onSeek,
    required this.onCollapse,
    required this.onRestart,
    required this.onAddToSoundboard,
    required this.onShare,
    required this.onRename,
    required this.onDelete,
    this.speed,
    this.onCycleSpeed,
  });

  static String clock(int ms) {
    final s = max(0, ms) ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  static String speedLabel(double s) =>
      s == s.roundToDouble() ? '${s.toInt()}×' : '$s×';

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = _isLight(context);
    const tint = kVoiceMemoTint;
    final tintText = voiceMemoTintText(context);
    final fill = Color.alphaBlend(
        tint.withValues(alpha: light ? 0.14 : 0.10), c.surfaceCard);
    final line = tint.withValues(alpha: light ? 0.55 : 0.35);
    final chipLine = tint.withValues(alpha: light ? 0.6 : 0.3);
    final progress =
        totalMs > 0 ? (positionMs / totalMs).clamp(0.0, 1.0).toDouble() : 0.0;

    final icon = playing
        ? Icons.pause_rounded
        : atEnd
            ? Icons.replay_rounded
            : Icons.play_arrow_rounded;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: line),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Header ─────────────────────────────────────────────────────
          Row(children: [
            Material(
              color: ready ? tint : tint.withValues(alpha: 0.5),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: ready ? onPlayPause : null,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: ready
                      ? Icon(
                          icon,
                          color: _ink,
                          size: 24,
                          semanticLabel: playing
                              ? 'Pause $title'
                              : atEnd
                                  ? 'Replay $title'
                                  : 'Play $title',
                        )
                      : Padding(
                          padding: const EdgeInsets.all(13),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(_ink),
                            semanticsLabel: 'Loading $title',
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Semantics(
                onTapHint: 'Collapse',
                child: InkWell(
                  onTap: onCollapse,
                  borderRadius: BorderRadius.circular(10),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(color: c.textSecondary, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${clock(positionMs)} / ${clock(totalMs)}',
              style: TextStyle(
                color: tintText,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                fontFeatures: _tabular,
              ),
            ),
          ]),
          const SizedBox(height: 12),

          // ── Scrubber ───────────────────────────────────────────────────
          LayoutBuilder(builder: (context, box) {
            void seekAt(double dx) {
              if (!ready || box.maxWidth <= 0) return;
              onSeek((dx / box.maxWidth).clamp(0.0, 1.0));
            }

            void nudge(int ms) {
              if (!ready || totalMs <= 0) return;
              onSeek(((positionMs + ms) / totalMs).clamp(0.0, 1.0));
            }

            String at(int ms) =>
                '${clock(ms.clamp(0, max(0, totalMs)))} of ${clock(totalMs)}';

            return Semantics(
              slider: true,
              label: 'Playback position',
              value: at(positionMs),
              increasedValue: at(positionMs + 5000),
              decreasedValue: at(positionMs - 5000),
              onIncrease: ready ? () => nudge(5000) : null,
              onDecrease: ready ? () => nudge(-5000) : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => seekAt(d.localPosition.dx),
                onHorizontalDragUpdate: (d) => seekAt(d.localPosition.dx),
                child: ExcludeSemantics(
                  child: WaveformBars(
                    levels: levels,
                    progress: progress,
                    activeColor: light
                        ? Color.lerp(tint, Colors.black, 0.2)!
                        : tint,
                    idleColor: c.textPrimary.withValues(alpha: 0.18),
                    height: 40,
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 12),

          // ── Actions ────────────────────────────────────────────────────
          // On narrow phones Share moves into the overflow menu so the
          // "Add to soundboard" label isn't cut off.
          LayoutBuilder(builder: (context, box) {
            final roomy = box.maxWidth >= 320;
            return Row(children: [
              if (speed != null) ...[
                _OutlinedChip(
                  label: speedLabel(speed!),
                  semanticLabel: 'Playback speed ${speedLabel(speed!)}',
                  line: chipLine,
                  onTap: onCycleSpeed,
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: _OutlinedChip(
                    label: 'Add to soundboard',
                    line: chipLine,
                    onTap: onAddToSoundboard,
                  ),
                ),
              ),
              if (roomy) ...[
                const SizedBox(width: 6),
                _OutlinedIconButton(
                  icon: Icons.ios_share_rounded,
                  tooltip: 'Share $title',
                  line: chipLine,
                  onTap: onShare,
                ),
              ],
              const SizedBox(width: 6),
              _MoreMenu(
                line: chipLine,
                title: title,
                onRestart: ready ? onRestart : null,
                onShare: roomy ? null : onShare,
                onRename: onRename,
                onDelete: onDelete,
              ),
            ]);
          }),
        ],
      ),
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

class _OutlinedChip extends StatelessWidget {
  final String label;
  final String? semanticLabel;
  final Color line;
  final VoidCallback? onTap;

  const _OutlinedChip({
    required this.label,
    required this.line,
    required this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Material(
        color: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFeatures: _tabular,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OutlinedIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color line;
  final VoidCallback onTap;

  const _OutlinedIconButton({
    required this.icon,
    required this.tooltip,
    required this.line,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return IconButton(
      onPressed: onTap,
      tooltip: tooltip,
      icon: Icon(icon, size: 19),
      style: IconButton.styleFrom(
        foregroundColor: c.textPrimary,
        fixedSize: const Size(44, 44),
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: line),
        ),
      ),
    );
  }
}

enum _MoreAction { restart, share, rename, delete }

class _MoreMenu extends StatelessWidget {
  final Color line;
  final String title;
  final VoidCallback? onRestart;

  /// Shown as a menu item only when non-null (narrow layouts).
  final VoidCallback? onShare;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _MoreMenu({
    required this.line,
    required this.title,
    required this.onRestart,
    required this.onShare,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    const danger = Colors.redAccent;
    PopupMenuItem<_MoreAction> item(
            _MoreAction value, IconData icon, String label,
            {Color? color, bool enabled = true}) =>
        PopupMenuItem(
          value: value,
          enabled: enabled,
          child: Row(children: [
            Icon(icon, size: 20, color: color ?? c.iconSecondary),
            const SizedBox(width: 14),
            Text(label,
                style: TextStyle(color: color ?? c.textPrimary, fontSize: 15)),
          ]),
        );

    return PopupMenuButton<_MoreAction>(
      tooltip: 'More actions for $title',
      color: c.surfaceCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.border),
      ),
      position: PopupMenuPosition.under,
      onSelected: (a) => switch (a) {
        _MoreAction.restart => onRestart?.call(),
        _MoreAction.share => onShare?.call(),
        _MoreAction.rename => onRename(),
        _MoreAction.delete => onDelete(),
      },
      itemBuilder: (_) => [
        item(_MoreAction.restart, Icons.skip_previous_rounded, 'Play from start',
            enabled: onRestart != null),
        if (onShare != null)
          item(_MoreAction.share, Icons.ios_share_rounded, 'Share'),
        item(_MoreAction.rename, Icons.edit_outlined, 'Rename'),
        item(_MoreAction.delete, Icons.delete_outline_rounded, 'Delete',
            color: danger),
      ],
      style: IconButton.styleFrom(
        foregroundColor: c.textPrimary,
        fixedSize: const Size(44, 44),
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: line),
        ),
      ),
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
    );
  }
}
