import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import '../models/sound_model.dart';
import '../services/haptics.dart';
import '../services/sound_prefs.dart';
import '../services/waveforms.dart';
import '../theme/app_colors.dart';
import 'waveform_bars.dart';

/// What happened when the user tapped "Pin to widget".
enum PinResult { pinned, unpinned, full }

/// The long-press sheet for a sound: preview with its real waveform, the
/// main actions, and per-sound playback settings (loop, speed).
class SoundSheet extends StatefulWidget {
  final SoundModel sound;
  final AudioSource? source;

  /// Length in seconds at 1× (already trimmed for clips).
  final double duration;
  final int playCount;
  final Color categoryColor;
  final bool isFavorite;
  final bool isPinned;

  final VoidCallback onToggleFavorite;
  final VoidCallback onShare;
  final VoidCallback onBoards;
  final Future<PinResult> Function() onTogglePin;
  final VoidCallback onManageWidget;
  final VoidCallback? onResetPlays;

  /// User clips only.
  final VoidCallback? onEdit;
  final VoidCallback? onColor;
  final VoidCallback? onDelete;

  const SoundSheet({
    super.key,
    required this.sound,
    required this.source,
    required this.duration,
    required this.playCount,
    required this.categoryColor,
    required this.isFavorite,
    required this.isPinned,
    required this.onToggleFavorite,
    required this.onShare,
    required this.onBoards,
    required this.onTogglePin,
    required this.onManageWidget,
    this.onResetPlays,
    this.onEdit,
    this.onColor,
    this.onDelete,
  });

  @override
  State<SoundSheet> createState() => _SoundSheetState();
}

class _SoundSheetState extends State<SoundSheet>
    with SingleTickerProviderStateMixin {
  static const _bars = 44;

  late final Ticker _ticker;
  late List<double> _levels;
  late bool _favorite = widget.isFavorite;
  late bool _pinned = widget.isPinned;
  late bool _loop = SoundPrefs.loops(widget.sound.id);
  late double _speed = SoundPrefs.speedOf(widget.sound.id);

  SoundHandle? _handle;
  double _progress = 0;
  double _elapsed = 0; // seconds of audio played (at 1×)

  SoundModel get _s => widget.sound;
  bool get _trimmed => _s.isUserClip && _s.trimEnd > _s.trimStart;
  double get _start => _trimmed ? _s.trimStart : 0;
  double get _end => _trimmed ? _s.trimEnd : widget.duration;

  @override
  void initState() {
    super.initState();
    // Created here, not lazily: a lazy ticker first touched in dispose()
    // (sheet closed without playing) would look up TickerMode too late.
    _ticker = createTicker(_onTick);
    _levels = Waveforms.peek(_s, bars: _bars) ?? Waveforms.placeholder(_s.id, _bars);
    Waveforms.of(_s, bars: _bars).then((levels) {
      if (mounted) setState(() => _levels = levels);
    });
  }

  @override
  void dispose() {
    _stopPreview();
    _ticker.dispose();
    super.dispose();
  }

  // ── Preview playback ─────────────────────────────────────────────────────

  Future<void> _togglePreview() async {
    Haptics.light();
    if (_handle != null) {
      _stopPreview();
      setState(() {});
      return;
    }
    final source = widget.source;
    if (source == null) return;
    try {
      final start = Duration(microseconds: (_start * 1e6).round());
      final handle = await SoLoud.instance.play(
        source,
        paused: true,
        looping: _loop,
        loopingStartAt: start,
      );
      if (_trimmed) SoLoud.instance.seek(handle, start);
      SoLoud.instance.setRelativePlaySpeed(handle, _speed);
      SoLoud.instance.setPause(handle, false);
      if (!mounted) {
        SoLoud.instance.stop(handle);
        return;
      }
      setState(() {
        _handle = handle;
        _progress = 0;
        _elapsed = 0;
      });
      _ticker.start();
    } catch (_) {}
  }

  void _onTick(Duration _) {
    final handle = _handle;
    if (handle == null) return;
    if (!SoLoud.instance.getIsValidVoiceHandle(handle)) {
      _finishPreview();
      return;
    }
    final pos = SoLoud.instance.getPosition(handle).inMicroseconds / 1e6;
    // Trimmed clips stop (or loop) at their trim end, not the file's end.
    if (_trimmed && pos >= _end) {
      if (_loop) {
        SoLoud.instance.seek(handle, Duration(microseconds: (_start * 1e6).round()));
      } else {
        _stopPreview();
        _finishPreview();
        return;
      }
    }
    final span = _end - _start;
    setState(() {
      _elapsed = (pos - _start).clamp(0, span).toDouble();
      _progress = span > 0 ? _elapsed / span : 0;
    });
  }

  void _stopPreview() {
    final handle = _handle;
    _handle = null;
    if (_ticker.isActive) _ticker.stop();
    if (handle != null && SoLoud.instance.getIsValidVoiceHandle(handle)) {
      SoLoud.instance.stop(handle);
    }
  }

  void _finishPreview() {
    if (_ticker.isActive) _ticker.stop();
    if (mounted) {
      setState(() {
        _handle = null;
        _progress = 0;
        _elapsed = 0;
      });
    }
  }

  // ── Settings ─────────────────────────────────────────────────────────────

  void _setLoop(bool v) {
    Haptics.selection();
    setState(() => _loop = v);
    SoundPrefs.setLoop(_s.id, v);
    final handle = _handle;
    if (handle != null && SoLoud.instance.getIsValidVoiceHandle(handle)) {
      SoLoud.instance.setLooping(handle, v);
    }
  }

  void _setSpeed(double v) {
    if (v == _speed) return;
    Haptics.selection();
    setState(() => _speed = v);
    SoundPrefs.setSpeed(_s.id, v);
    final handle = _handle;
    if (handle != null && SoLoud.instance.getIsValidVoiceHandle(handle)) {
      SoLoud.instance.setRelativePlaySpeed(handle, v);
    }
  }

  Future<void> _togglePin() async {
    Haptics.selection();
    final result = await widget.onTogglePin();
    if (!mounted) return;
    switch (result) {
      case PinResult.pinned:
        setState(() => _pinned = true);
      case PinResult.unpinned:
        setState(() => _pinned = false);
      case PinResult.full:
        _showWidgetFull();
    }
  }

  void _showWidgetFull() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your widget is full'),
        content: const Text(
            'It already has 8 sounds. Remove one to make room for this one.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onManageWidget();
            },
            child: const Text('Choose sounds'),
          ),
        ],
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  static String _clock(double seconds) {
    final tenths = (seconds * 10).round();
    final m = tenths ~/ 600;
    final s = (tenths % 600) / 10;
    return '$m:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.primary;
    final onAccent = scheme.onPrimary;
    final playing = _handle != null;
    final tabular = [const FontFeature.tabularFigures()];

    final plays = widget.playCount;
    final meta = [
      '${widget.duration.toStringAsFixed(1)} seconds',
      plays == 0 ? 'not played yet' : 'played $plays ${plays == 1 ? 'time' : 'times'}',
    ].join(' · ');

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.handleBar,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // ── Title ───────────────────────────────────────────────────
              Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: widget.categoryColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(_s.category.toUpperCase(),
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.4,
                    )),
              ]),
              const SizedBox(height: 6),
              Text(_s.name,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    height: 1.15,
                  )),
              const SizedBox(height: 4),
              Text(meta, style: TextStyle(color: c.textSecondary, fontSize: 14)),
              const SizedBox(height: 18),

              // ── Preview player ──────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.scaffoldBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: c.border),
                ),
                child: Row(children: [
                  Material(
                    color: accent,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: widget.source == null ? null : _togglePreview,
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: Icon(
                          playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                          color: onAccent,
                          size: 28,
                          semanticLabel: playing ? 'Stop preview' : 'Play preview',
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: WaveformBars(
                            levels: _levels,
                            progress: playing ? _progress : 0,
                            activeColor: accent,
                            idleColor: playing
                                ? c.textPrimary.withValues(alpha: 0.18)
                                : widget.categoryColor.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(children: [
                          Text(_clock(_elapsed / _speed),
                              style: TextStyle(
                                color: playing ? accent : c.textMuted,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                fontFeatures: tabular,
                              )),
                          const Spacer(),
                          Text(_clock(widget.duration / _speed),
                              style: TextStyle(
                                color: c.textMuted,
                                fontSize: 12,
                                fontFeatures: tabular,
                              )),
                        ]),
                      ],
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 14),

              // ── Actions ─────────────────────────────────────────────────
              Row(children: [
                Expanded(
                  child: _ActionTile(
                    icon: _favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                    label: 'Favourite',
                    selected: _favorite,
                    selectedColor: Colors.amber,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _favorite = !_favorite);
                      widget.onToggleFavorite();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.ios_share_rounded,
                    label: 'Share',
                    onTap: widget.onShare,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: Icons.dashboard_customize_rounded,
                    label: 'Add to board',
                    onTap: widget.onBoards,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionTile(
                    icon: _pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    label: _pinned ? 'Pinned' : 'Pin to widget',
                    selected: _pinned,
                    selectedColor: accent,
                    onTap: _togglePin,
                  ),
                ),
              ]),

              // ── Playback ────────────────────────────────────────────────
              const _Label('PLAYBACK'),
              _Group(children: [
                _Row(
                  icon: Icons.repeat_rounded,
                  title: 'Loop',
                  subtitle: _loop ? 'Tap the sound again to stop it' : null,
                  trailing: Switch(
                    value: _loop,
                    onChanged: _setLoop,
                    activeThumbColor: accent,
                    activeTrackColor: accent.withValues(alpha: 0.4),
                  ),
                  onTap: () => _setLoop(!_loop),
                ),
                Divider(height: 1, indent: 52, color: c.borderSubtle),
                _Row(
                  icon: Icons.speed_rounded,
                  title: 'Speed',
                  trailing: _SpeedPicker(
                    value: _speed,
                    onChanged: _setSpeed,
                  ),
                ),
              ]),

              // ── My clip ─────────────────────────────────────────────────
              if (widget.onEdit != null) ...[
                const _Label('MY CLIP'),
                _Group(children: [
                  _Row(
                    icon: Icons.content_cut_rounded,
                    title: 'Edit clip',
                    onTap: widget.onEdit,
                    showChevron: true,
                  ),
                  Divider(height: 1, indent: 52, color: c.borderSubtle),
                  _Row(
                    icon: Icons.palette_outlined,
                    title: 'Change colour',
                    onTap: widget.onColor,
                    showChevron: true,
                  ),
                  Divider(height: 1, indent: 52, color: c.borderSubtle),
                  _Row(
                    icon: Icons.delete_outline_rounded,
                    title: 'Delete clip',
                    color: Colors.redAccent,
                    onTap: widget.onDelete,
                  ),
                ]),
              ],

              if (widget.onResetPlays != null) ...[
                const SizedBox(height: 10),
                Center(
                  child: TextButton(
                    onPressed: widget.onResetPlays,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      minimumSize: const Size(44, 44),
                    ),
                    child: const Text('Reset play count',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final Color? selectedColor;

  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.selectedColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final tint = selected ? (selectedColor ?? Theme.of(context).colorScheme.primary) : null;
    // On a light sheet a pale tint needs a darker shade for readable text.
    final light = Theme.of(context).brightness == Brightness.light;
    final fg = tint == null
        ? c.textPrimary
        : light
            ? Color.lerp(tint, Colors.black, 0.45)!
            : tint;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: tint?.withValues(alpha: 0.14) ?? c.surfaceElevated.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: tint?.withValues(alpha: 0.5) ?? c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 84,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: fg),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                      )),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 22, 2, 8),
      child: Text(text,
          style: TextStyle(
            color: c.textMuted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
          )),
    );
  }
}

class _Group extends StatelessWidget {
  final List<Widget> children;
  const _Group({required this.children});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Material(
      color: c.surfaceElevated.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? color;
  final bool showChevron;

  const _Row({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.color,
    this.showChevron = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final fg = color ?? c.textPrimary;
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
            child: Row(children: [
              Icon(icon, size: 20, color: color ?? c.iconSecondary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: TextStyle(color: fg, fontSize: 15)),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: TextStyle(color: c.textMuted, fontSize: 12)),
                  ],
                ),
              ),
              ?trailing,
              if (showChevron)
                Icon(Icons.chevron_right_rounded, size: 20, color: c.iconSecondary),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 0.5× · 1× · 1.5× · 2× segmented control.
class _SpeedPicker extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  const _SpeedPicker({required this.value, required this.onChanged});

  static String _label(double s) =>
      s == s.roundToDouble() ? '${s.toInt()}×' : '$s×';

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Playback speed',
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: c.scaffoldBg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in SoundPrefs.speeds)
              Semantics(
                button: true,
                selected: s == value,
                label: '${_label(s)} speed',
                child: GestureDetector(
                  onTap: () => onChanged(s),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    width: 46,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: s == value ? scheme.primary : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: ExcludeSemantics(
                      child: Text(_label(s),
                          style: TextStyle(
                            color: s == value ? scheme.onPrimary : c.textSecondary,
                            fontSize: 13,
                            fontWeight: s == value ? FontWeight.w700 : FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          )),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
