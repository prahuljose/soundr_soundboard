import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_settings.dart';
import '../services/haptics.dart';
import '../services/quick_sounds.dart';
import '../theme/app_colors.dart';
import '../widgets/first_run_tour.dart';

/// All app preferences in one place. Opened from the drawer.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _notificationsGranted = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshNotificationStatus();
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

  // ── Home screen widget / Quick Settings tile ────────────────────────────────

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

  Future<void> _addTile() async {
    if (await QuickSounds.canAddTile()) {
      final code = await QuickSounds.addTile();
      if (!mounted) return;
      if (code == 2) _snack('Soundr tile added to Quick Settings');
      if (code == 1) _snack('The Soundr tile is already in your Quick Settings');
      if (code != null && code >= 0) return; // added, already there, or declined
    }
    if (!mounted) return;
    _showHowTo('Add the Quick Settings tile', const [
      'Swipe down twice from the top of the screen.',
      'Tap the pencil (edit) button.',
      'Drag the Soundr tile into your active tiles.',
    ]);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: Text('Settings',
            style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // ── Appearance ────────────────────────────────────────────────────
          const _SectionLabel('APPEARANCE'),
          _Card(children: [
            ValueListenableBuilder<ThemeMode>(
              valueListenable: AppSettings.themeMode,
              builder: (context, mode, _) {
                final isDark = mode == ThemeMode.dark;
                return _SwitchRow(
                  icon: isDark
                      ? Icons.dark_mode_rounded
                      : Icons.light_mode_rounded,
                  title: 'Dark mode',
                  value: isDark,
                  onChanged: (v) => AppSettings.themeMode.value =
                      v ? ThemeMode.dark : ThemeMode.light,
                );
              },
            ),
            _Divider(c),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Accent colour',
                      style: TextStyle(color: c.textPrimary, fontSize: 15)),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<Color>(
                    valueListenable: AppSettings.accent,
                    builder: (context, current, _) => Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: AppSettings.accentPresets.map((color) {
                        final selected = current == color;
                        return Semantics(
                          button: true,
                          selected: selected,
                          label: 'Accent colour',
                          child: GestureDetector(
                            onTap: () => AppSettings.accent.value = color,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? c.textPrimary
                                      : Colors.transparent,
                                  width: 2.5,
                                ),
                                boxShadow: selected
                                    ? [
                                        BoxShadow(
                                            color: color.withValues(alpha: 0.5),
                                            blurRadius: 8)
                                      ]
                                    : [],
                              ),
                              child: selected
                                  ? const Icon(Icons.check_rounded,
                                      size: 16, color: Colors.white)
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
          ]),

          // ── Soundboard ────────────────────────────────────────────────────
          const _SectionLabel('SOUNDBOARD'),
          _Card(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Button size',
                      style: TextStyle(color: c.textPrimary, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text('Tablets and landscape get extra columns automatically',
                      style: TextStyle(color: c.textMuted, fontSize: 12)),
                  const SizedBox(height: 14),
                  ValueListenableBuilder<GridDensity>(
                    valueListenable: AppSettings.gridDensity,
                    builder: (context, density, _) => Row(
                      children: [
                        for (final d in GridDensity.values) ...[
                          if (d != GridDensity.values.first)
                            const SizedBox(width: 10),
                          Expanded(
                            child: _DensityOption(
                              density: d,
                              selected: d == density,
                              accent: accent,
                              onTap: () {
                                Haptics.selection();
                                AppSettings.gridDensity.value = d;
                              },
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ]),

          // ── Feedback ──────────────────────────────────────────────────────
          const _SectionLabel('FEEDBACK'),
          _Card(children: [
            _SwitchRow(
              icon: Haptics.enabled
                  ? Icons.vibration_rounded
                  : Icons.smartphone_rounded,
              title: 'Haptics',
              subtitle: 'Vibrate lightly on taps',
              value: Haptics.enabled,
              onChanged: (v) async {
                await Haptics.setEnabled(v);
                if (v) Haptics.selection();
                if (mounted) setState(() {});
              },
            ),
            _Divider(c),
            _TapRow(
              icon: _notificationsGranted
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_off_rounded,
              iconColor: _notificationsGranted
                  ? null
                  : Colors.redAccent.withValues(alpha: 0.85),
              title: 'Notifications',
              subtitle: _notificationsGranted
                  ? 'Playback controls in the notification shade'
                  : 'Disabled — tap to enable',
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
              icon: Icons.widgets_rounded,
              title: 'Add home-screen widget',
              subtitle: 'Play your favourites without opening Soundr',
              onTap: _addWidget,
            ),
            _Divider(c),
            _TapRow(
              icon: Icons.bolt_rounded,
              title: 'Add Quick Settings tile',
              subtitle: 'A random favourite, one swipe down',
              onTap: _addTile,
            ),
          ]),

          // ── Help ──────────────────────────────────────────────────────────
          const _SectionLabel('HELP'),
          _Card(children: [
            _TapRow(
              icon: Icons.auto_awesome_rounded,
              title: 'Replay intro tour',
              subtitle: 'Tap, long-press, and where the tools live',
              onTap: () => showFirstRunTour(context),
            ),
          ]),

          const SizedBox(height: 28),
          Center(
            child: Text(
              'Soundr  ·  Offline  ·  No ads  ·  No tracking',
              style: TextStyle(color: c.textMuted, fontSize: 12),
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
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 20, 6, 8),
      child: Text(text,
          style: TextStyle(
            color: c.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          )),
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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.borderSubtle),
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
  final AppColors c;
  const _Divider(this.c);

  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, indent: 52, color: c.borderSubtle);
}

class _SwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final accent = Theme.of(context).colorScheme.primary;
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
          child: Row(children: [
            Icon(icon, size: 20, color: c.iconSecondary),
            const SizedBox(width: 16),
            Expanded(child: _RowText(title: title, subtitle: subtitle)),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: accent,
              activeTrackColor: accent.withValues(alpha: 0.4),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TapRow extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _TapRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(children: [
          Icon(icon, size: 20, color: iconColor ?? c.iconSecondary),
          const SizedBox(width: 16),
          Expanded(child: _RowText(title: title, subtitle: subtitle)),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.iconSecondary),
        ]),
      ),
    );
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
      children: [
        Text(title, style: TextStyle(color: c.textPrimary, fontSize: 15)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!,
              style: TextStyle(color: c.textMuted, fontSize: 12, height: 1.3)),
        ],
      ],
    );
  }
}

/// One of the three button-size choices, drawn as a tiny grid preview.
class _DensityOption extends StatelessWidget {
  final GridDensity density;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _DensityOption({
    required this.density,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>()!;
    final columns = switch (density) {
      GridDensity.compact => 4,
      GridDensity.normal => 3,
      GridDensity.large => 2,
    };
    final cellColor =
        selected ? accent.withValues(alpha: 0.55) : c.textPrimary.withValues(alpha: 0.14);

    return Semantics(
      button: true,
      selected: selected,
      label: '${density.label} buttons',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.12) : c.surfaceElevated.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? accent : c.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: ExcludeSemantics(
            child: Column(
              children: [
                SizedBox(
                  height: 34,
                  child: LayoutBuilder(builder: (context, box) {
                    const gap = 3.0;
                    final cell = (box.maxWidth - gap * (columns - 1)) / columns;
                    final rows = columns == 2 ? 1 : 2;
                    final h = (34 - gap * (rows - 1)) / rows;
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (var r = 0; r < rows; r++) ...[
                          if (r > 0) const SizedBox(height: gap),
                          Row(children: [
                            for (var i = 0; i < columns; i++) ...[
                              if (i > 0) const SizedBox(width: gap),
                              Container(
                                width: cell,
                                height: h,
                                decoration: BoxDecoration(
                                  color: cellColor,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ],
                          ]),
                        ],
                      ],
                    );
                  }),
                ),
                const SizedBox(height: 10),
                Text(
                  density.label,
                  style: TextStyle(
                    color: selected ? accent : c.textSecondary,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
