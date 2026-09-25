import 'package:flutter/material.dart';

import 'clip_repository.dart';

/// How big the soundboard buttons are. Each density sets a *maximum* button
/// width rather than a fixed column count, so phones in landscape and tablets
/// automatically get more columns. Height is fixed per density so a two-line
/// name always fits, however narrow the columns get.
enum GridDensity {
  compact(label: 'Compact', maxExtent: 92, tileHeight: 98),
  normal(label: 'Normal', maxExtent: 130, tileHeight: 118),
  large(label: 'Large', maxExtent: 200, tileHeight: 152);

  const GridDensity({
    required this.label,
    required this.maxExtent,
    required this.tileHeight,
  });

  final String label;
  final double maxExtent;
  final double tileHeight;

  static GridDensity fromName(String? name) =>
      GridDensity.values.firstWhere((d) => d.name == name,
          orElse: () => GridDensity.normal);
}

/// App-wide preferences, persisted in the settings table.
///
/// [load] runs once before `runApp` so the first frame already has the saved
/// theme and accent — no flash of the defaults. Each notifier writes itself
/// back whenever it changes.
class AppSettings {
  AppSettings._();

  static const defaultAccent = Color(0xFF6C63FF);

  static const accentPresets = [
    Color(0xFF6C63FF),
    Color(0xFF2196F3),
    Color(0xFF00BCD4),
    Color(0xFF4CAF50),
    Color(0xFFFF9800),
    Color(0xFFE91E63),
  ];

  static final themeMode = ValueNotifier(ThemeMode.dark);
  static final accent = ValueNotifier<Color>(defaultAccent);
  static final gridDensity = ValueNotifier(GridDensity.normal);

  /// Bottom tabs (true) or the original side menu (false).
  static final useTabs = ValueNotifier(true);

  /// Whether the first-run tour has been shown (or skipped).
  static bool tourSeen = false;

  static const _kTheme = 'theme_mode';
  static const _kAccent = 'accent_color';
  static const _kGrid = 'grid_density';
  static const _kTour = 'tour_seen';
  static const _kTabs = 'nav_bottom_tabs';

  static Future<void> load() async {
    try {
      final theme = await ClipRepository.getString(_kTheme);
      if (theme == 'light') themeMode.value = ThemeMode.light;
      final accentValue = await ClipRepository.getInt(_kAccent);
      if (accentValue != null) accent.value = Color(accentValue);
      gridDensity.value =
          GridDensity.fromName(await ClipRepository.getString(_kGrid));
      tourSeen = await ClipRepository.getBool(_kTour);
      useTabs.value = await ClipRepository.getBool(_kTabs, defaultValue: true);
    } catch (_) {/* first launch or DB unavailable — keep defaults */}

    themeMode.addListener(() => _save(() => ClipRepository.setString(
        _kTheme, themeMode.value == ThemeMode.light ? 'light' : 'dark')));
    accent.addListener(() => _save(
        () => ClipRepository.setInt(_kAccent, accent.value.toARGB32())));
    gridDensity.addListener(() => _save(
        () => ClipRepository.setString(_kGrid, gridDensity.value.name)));
    useTabs.addListener(
        () => _save(() => ClipRepository.setBool(_kTabs, useTabs.value)));
  }

  static Future<void> markTourSeen() async {
    tourSeen = true;
    await _save(() => ClipRepository.setBool(_kTour, true));
  }

  static Future<void> _save(Future<void> Function() write) async {
    try {
      await write();
    } catch (_) {/* best-effort — the in-memory value still applies */}
  }
}
