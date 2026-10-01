import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_settings.dart';
import '../services/haptics.dart';
import '../services/quick_sounds.dart';
import '../theme/app_colors.dart';
import '../widgets/first_run_tour.dart';
import 'widget_sounds_screen.dart';

/// All app preferences in one place. Pushed from the drawer, or shown as the
/// last bottom tab (no back button) when the user picked tabs.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  /// The "On" status colour for notifications (darkened in light mode).
  static const _onGreen = Color(0xFF7FE0C2);

  /// Friendly names for [AppSettings.accentPresets], read by screen readers.
  static const _accentNames = {
    0xFF6C63FF: 'Violet',
    0xFF2196F3: 'Blue',
    0xFF00BCD4: 'Cyan',
    0xFF4CAF50: 'Green',
    0xFFFF9800: 'Orange',
    0xFFE91E63: 'Pink',
  };

  bool _notificationsGranted = true;
  String _widgetSummary = 'Automatic · favourites first';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshNotificationStatus();
    _refreshWidgetSummary();
  }

  Future<void> _refreshWidgetSummary() async {
    try {
      final choice = await QuickSounds.loadChoice();
      if (!mounted) return;
      final n = choice.ids.length;
      setState(() => _widgetSummary =
          choice.mode == WidgetSoundsMode.custom && n > 0
              ? 'Custom · $n ${n == 1 ? 'sound' : 'sounds'}, your order'
              : 'Automatic · favourites first');
    } catch (_) {/* keep the default summary */}
  }

  Future<void> _openWidgetSounds() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const WidgetSoundsScreen()),
    );
    await _refreshWidgetSummary();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Re-check when the user comes back from the system settings page.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshNotificationStatus();
  }

  Future<void> _refreshNotificationStatus() async {
    try {
      final s = await Permission.notification.status;
      if (mounted) setState(() => _notificationsGranted = s.isGranted);
    } catch (_) {}
  }

  // ── Home screen widget ──────────────────────────────────────────────────────

  Future<void> _addWidget() async {
    if (await QuickSounds.canPinWidget() && await QuickSounds.pinWidget()) {
      return; // the launcher shows its own "add widget" prompt
    }
    if (!mounted) return;
    _showHowTo('Add the Soundr widget', const [
      'Long-press an empty spot on your home screen.',
      'Tap Widgets and find Soundr.',
      'Drag "Soundr quick sounds" onto your home screen.',
    ]);
  }

  void _showHowTo(String title, List<String> steps) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                      ),
                      child: Text('${i + 1}',
                          style: TextStyle(
                              color: accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(steps[i],
                          style: TextStyle(
                              color: c.textSecondary, fontSize: 14, height: 1.4)),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  // ── Setters ─────────────────────────────────────────────────────────────────

  void _setThemeMode(ThemeMode mode) {
    if (AppSettings.themeMode.value == mode) return;
    Haptics.selection();
    AppSettings.themeMode.value = mode;
  }

  void _setAccent(Color color) {
    if (AppSettings.accent.value == color) return;
    Haptics.selection();
    AppSettings.accent.value = color;
  }

  void _setNavStyle({required bool tabs}) {
    if (AppSettings.useTabs.value == tabs) return;
    Haptics.selection();
    AppSettings.useTabs.value = tabs;
  }

  void _setDensity(GridDensity d) {
    if (AppSettings.gridDensity.value == d) return;
    Haptics.selection();
    AppSettings.gridDensity.value = d;
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final light = Theme.of(context).brightness == Brightness.light;
    // Pushed from the drawer → back arrow. As a bottom tab there is nothing
    // to go back to, so the bar collapses to just the status-bar inset.
    final canPop = ModalRoute.of(context)?.canPop ?? false;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: canPop,
        toolbarHeight: canPop ? kToolbarHeight : 0,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, canPop ? 0 : 22, 16, 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: Semantics(
              header: true,
              child: Text('Settings',
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                    height: 1.15,
                  )),
            ),
          ),

          // ── Appearance ────────────────────────────────────────────────────
          const _SectionLabel('APPEARANCE', top: 18),
          _Card(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: AppSettings.themeMode,
                builder: (context, mode, _) => _Segmented<ThemeMode>(
                  label: 'Theme',
                  expand: true,
                  pillHeight: 38,
                  selected: mode,
                  onChanged: _setThemeMode,
                  options: const [
                    _Seg(ThemeMode.dark, 'Dark'),
                    _Seg(ThemeMode.light, 'Light'),
                    _Seg(ThemeMode.system, 'System',
                        semanticLabel: 'Match system'),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 10, 4),
              child: ValueListenableBuilder<Color>(
                valueListenable: AppSettings.accent,
                builder: (context, current, _) =>
                    LayoutBuilder(builder: (context, box) {
                  const labelW = 64.0;
                  const presets = AppSettings.accentPresets;
                  final swatches = [
                    for (var i = 0; i < presets.length; i++)
                      _AccentSwatch(
                        color: presets[i],
                        name: _accentNames[presets[i].toARGB32()] ??
                            'Colour ${i + 1}',
                        selected: current.toARGB32() == presets[i].toARGB32(),
                        onTap: () => _setAccent(presets[i]),
                      ),
                  ];
                  final label = Text('Accent',
                      style: TextStyle(color: c.textPrimary, fontSize: 15));
                  // One row when it fits; otherwise the swatches get their
                  // own line so each keeps a full 44px target.
                  if (box.maxWidth >= labelW + presets.length * 44) {
                    return Row(children: [
                      Expanded(child: label),
                      ...swatches,
                    ]);
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 10, bottom: 2),
                        child: label,
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: swatches,
                      ),
                    ],
                  );
                }),
              ),
            ),
          ]),

          // ── Layout ────────────────────────────────────────────────────────
          const _SectionLabel('LAYOUT'),
          _Card(children: [
            _ControlRow(
              title: 'Menu style',
              control: ValueListenableBuilder<bool>(
                valueListenable: AppSettings.useTabs,
                builder: (context, tabs, _) => _Segmented<bool>(
                  label: 'Menu style',
                  selected: tabs,
                  onChanged: (v) => _setNavStyle(tabs: v),
                  options: const [
                    _Seg(false, 'Side menu'),
                    _Seg(true, 'Tabs', semanticLabel: 'Bottom tabs'),
                  ],
                ),
              ),
            ),
            const _Divider(),
            _ControlRow(
              title: 'Button size',
              control: ValueListenableBuilder<GridDensity>(
                valueListenable: AppSettings.gridDensity,
                builder: (context, density, _) => _Segmented<GridDensity>(
                  label: 'Button size',
                  segmentWidth: 40,
                  selected: density,
                  onChanged: _setDensity,
                  options: [
                    for (final d in GridDensity.values)
                      _Seg(
                        d,
                        switch (d) {
                          GridDensity.compact => 'S',
                          GridDensity.normal => 'M',
                          GridDensity.large => 'L',
                        },
                        semanticLabel: switch (d) {
                          GridDensity.compact => 'Small buttons',
                          GridDensity.normal => 'Medium buttons',
                          GridDensity.large => 'Large buttons',
                        },
                      ),
                  ],
                ),
              ),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
            child: Text(
              'Tablets and landscape get extra columns automatically.',
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
          ),

          // ── Feedback ──────────────────────────────────────────────────────
          const _SectionLabel('FEEDBACK'),
          _Card(children: [
            _SwitchRow(
              title: 'Haptics',
              subtitle: 'Vibrate lightly on taps',
              value: Haptics.enabled,
              onChanged: (v) async {
                await Haptics.setEnabled(v);
                if (v) Haptics.selection();
                if (mounted) setState(() {});
              },
            ),
            const _Divider(),
            _TapRow(
              title: 'Notifications',
              subtitle: _notificationsGranted
                  ? 'Playback controls in the shade'
                  : 'Off — tap to turn on in system settings',
              trailing: Text(
                _notificationsGranted ? 'On' : 'Off',
                style: TextStyle(
                  color: _notificationsGranted
                      ? (light
                          ? Color.lerp(_onGreen, Colors.black, 0.45)!
                          : _onGreen)
                      : c.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () async {
                await openAppSettings();
                await _refreshNotificationStatus();
              },
            ),
          ]),

          // ── Home screen ───────────────────────────────────────────────────
          const _SectionLabel('HOME SCREEN'),
          _Card(children: [
            _TapRow(
              title: 'Widget sounds',
              subtitle: _widgetSummary,
              onTap: _openWidgetSounds,
            ),
            const _Divider(),
            _TapRow(
              title: 'Add widget to home screen',
              subtitle: 'Play sounds without opening Soundr',
              onTap: _addWidget,
            ),
          ]),

          // ── Help ──────────────────────────────────────────────────────────
          const _SectionLabel('HELP'),
          _Card(children: [
            _TapRow(
              title: 'Replay intro tour',
              subtitle: 'Tap, long-press, and where the tools live',
              onTap: () =>
                  showFirstRunTour(context, tabs: AppSettings.useTabs.value),
            ),
          ]),

          const SizedBox(height: 22),
          Center(
            child: Text(
              'Soundr · offline · no ads · no tracking',
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Building blocks ──────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  final double top;
  const _SectionLabel(this.text, {this.top = 22});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top, 4, 8),
      child: Semantics(
        header: true,
        child: Text(text,
            style: TextStyle(
              color: c.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.4,
            )),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: Column(children: children),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Divider(height: 1, thickness: 1, indent: 16, color: c.border);
  }
}

class _RowText extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _RowText({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: TextStyle(color: c.textPrimary, fontSize: 15)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!,
              style: TextStyle(
                  color: c.textSecondary, fontSize: 12.5, height: 1.3)),
        ],
      ],
    );
  }
}

/// A title on the left, an inline control (segmented picker) on the right.
class _ControlRow extends StatelessWidget {
  final String title;
  final Widget control;
  const _ControlRow({required this.title, required this.control});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
      child: Row(children: [
        Expanded(
          child: ExcludeSemantics(
            child: Text(title,
                style: TextStyle(color: c.textPrimary, fontSize: 15)),
          ),
        ),
        const SizedBox(width: 12),
        control,
      ]),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(children: [
            Expanded(child: _RowText(title: title, subtitle: subtitle)),
            const SizedBox(width: 12),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: scheme.primary,
              activeThumbColor: scheme.onPrimary,
            ),
          ]),
        ),
      ),
    );
  }
}

class _TapRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _TapRow({
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
            child: Row(children: [
              Expanded(child: _RowText(title: title, subtitle: subtitle)),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ],
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: c.iconSecondary),
            ]),
          ),
        ),
      ),
    );
  }
}

/// One accent choice: a 32px swatch inside a 44px target, ringed when chosen.
class _AccentSwatch extends StatelessWidget {
  final Color color;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  const _AccentSwatch({
    required this.color,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: '$name accent',
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 32,
              height: 32,
              padding: EdgeInsets.all(selected ? 3 : 0),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? c.textPrimary : Colors.transparent,
                  width: 2,
                ),
              ),
              child: DecoratedBox(
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One option of a [_Segmented] control.
class _Seg<T> {
  final T value;
  final String label;
  final String? semanticLabel;
  const _Seg(this.value, this.label, {this.semanticLabel});
}

/// A pill-track segmented picker: the chosen segment is filled with the
/// accent. Each segment's hit area spans the full track height (≥44px).
class _Segmented<T> extends StatelessWidget {
  final String label;
  final List<_Seg<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  /// Stretch the segments to fill the width equally.
  final bool expand;

  /// Fixed segment width (e.g. S / M / L); otherwise sized to the label.
  final double? segmentWidth;
  final double pillHeight;

  const _Segmented({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.expand = false,
    this.segmentWidth,
    this.pillHeight = 36,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.extension<AppColors>()!;
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    const pad = 4.0; // track inset around the pills
    const gap = 4.0; // space between pills
    final trackRadius = expand ? 14.0 : 12.0;
    final pillRadius = expand ? 10.0 : 9.0;

    Widget segment(int i) {
      final o = options[i];
      final isSel = o.value == selected;
      final cell = Padding(
        padding: EdgeInsets.fromLTRB(
          i == 0 ? pad : gap / 2,
          pad,
          i == options.length - 1 ? pad : gap / 2,
          pad,
        ),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: pillHeight,
          width: segmentWidth,
          padding: segmentWidth == null && !expand
              ? const EdgeInsets.symmetric(horizontal: 12)
              : EdgeInsets.zero,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSel ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(pillRadius),
          ),
          child: Text(
            o.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isSel ? scheme.onPrimary : c.textSecondary,
              fontSize: 13,
              fontWeight: isSel ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      );
      final button = Semantics(
        button: true,
        selected: isSel,
        inMutuallyExclusiveGroup: true,
        label: o.semanticLabel ?? o.label,
        excludeSemantics: true,
        child: InkWell(
          onTap: () => onChanged(o.value),
          borderRadius: BorderRadius.circular(trackRadius),
          child: cell,
        ),
      );
      return expand ? Expanded(child: button) : button;
    }

    return Semantics(
      container: true,
      label: label,
      child: Container(
        decoration: BoxDecoration(
          color: light ? c.surfaceElevated : c.scaffoldBg,
          borderRadius: BorderRadius.circular(trackRadius),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [for (var i = 0; i < options.length; i++) segment(i)],
          ),
        ),
      ),
    );
  }
}
