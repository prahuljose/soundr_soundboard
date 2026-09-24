import 'package:flutter/material.dart';

import 'clip_repository.dart';

/// How big the soundboard buttons are. Each density sets a *maximum* button
/// width rather than a fixed column count, so phones in landscape and tablets
/// automatically get more columns.
enum GridDensity {
  compact(label: 'Compact', maxExtent: 92, aspectRatio: 0.92),
  normal(label: 'Normal', maxExtent: 130, aspectRatio: 0.9),
  large(label: 'Large', maxExtent: 200, aspectRatio: 1.2);

  const GridDensity({
    required this.label,
    required this.maxExtent,
    required this.aspectRatio,
  });

  final String label;
  final double maxExtent;
  final double aspectRatio;

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

  static final themeMode = ValueNotifier(ThemeMode.dark);
  static final accent = ValueNotifier<Color>(defaultAccent);
  static final gridDensity = ValueNotifier(GridDensity.normal);

  /// Whether the first-run tour has been shown (or skipped).
  static bool tourSeen = false;

  static const _kTheme = 'theme_mode';
  static const _kAccent = 'accent_color';
  static const _kGrid = 'grid_density';
  static const _kTour = 'tour_seen';

  static Future<void> load() async {
    try {
      final theme = await ClipRepository.getString(_kTheme);
      if (theme == 'light') themeMode.value = ThemeMode.light;
      final accentValue = await ClipRepository.getInt(_kAccent);
      if (accentValue != null) accent.value = Color(accentValue);
      gridDensity.value =
          GridDensity.fromName(await ClipRepository.getString(_kGrid));
      tourSeen = await ClipRepository.getBool(_kTour);
    } catch (_) {/* first launch or DB unavailable — keep defaults */}

    themeMode.addListener(() => _save(() => ClipRepository.setString(
        _kTheme, themeMode.value == ThemeMode.light ? 'light' : 'dark')));
    accent.addListener(() => _save(
        () => ClipRepository.setInt(_kAccent, accent.value.toARGB32())));
    gridDensity.addListener(() => _save(
        () => ClipRepository.setString(_kGrid, gridDensity.value.name)));
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
