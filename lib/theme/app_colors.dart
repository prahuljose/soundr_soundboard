import 'package:flutter/material.dart';

/// Semantic colour tokens shared across all screens.
/// Add to both [ThemeData.extensions] lists in main.dart.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.scaffoldBg,
    required this.surfaceCard,
    required this.surfaceElevated,
    required this.drawerBg,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.border,
    required this.borderSubtle,
    required this.handleBar,
    required this.iconSecondary,
    required this.snackbarBg,
  });

  final Color scaffoldBg;
  final Color surfaceCard;       // bottom sheets, text field fills, FAB bg
  final Color surfaceElevated;   // emoji picker unselected, color swatch bg
  final Color drawerBg;
  final Color textPrimary;
  final Color textSecondary;     // white54 equivalent
  final Color textMuted;         // white24 equivalent
  final Color border;            // white12 equivalent
  final Color borderSubtle;      // white10 equivalent
  final Color handleBar;         // bottom-sheet handle
  final Color iconSecondary;     // white38 equivalent
  final Color snackbarBg;

  static const dark = AppColors(
    scaffoldBg:      Color(0xFF0E0E0E),
    surfaceCard:     Color(0xFF1A1A1A),
    surfaceElevated: Color(0xFF2A2A2A),
    drawerBg:        Color(0xFF141414),
    textPrimary:     Colors.white,
    textSecondary:   Color(0x8AFFFFFF), // ~white54
    textMuted:       Color(0x3DFFFFFF), // ~white24
    border:          Color(0x1FFFFFFF), // ~white12
    borderSubtle:    Color(0x1AFFFFFF), // ~white10
    handleBar:       Color(0x3FFFFFFF), // ~white24
    iconSecondary:   Color(0x61FFFFFF), // ~white38
    snackbarBg:      Color(0xFF2A2A2A),
  );

  static const light = AppColors(
    scaffoldBg:      Color(0xFFF2F2F7),
    surfaceCard:     Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFE5E5EA),
    drawerBg:        Color(0xFFECECF1),
    textPrimary:     Color(0xFF1C1C1E),
    textSecondary:   Color(0xFF6C6C70),
    textMuted:       Color(0xFFAEAEB2),
    border:          Color(0xFFD1D1D6),
    borderSubtle:    Color(0xFFE5E5EA),
    handleBar:       Color(0xFFC7C7CC),
    iconSecondary:   Color(0xFF8E8E93),
    snackbarBg:      Color(0xFF3A3A3C),
  );

  @override
  AppColors copyWith({
    Color? scaffoldBg,
    Color? surfaceCard,
    Color? surfaceElevated,
    Color? drawerBg,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? border,
    Color? borderSubtle,
    Color? handleBar,
    Color? iconSecondary,
    Color? snackbarBg,
  }) =>
      AppColors(
        scaffoldBg:      scaffoldBg      ?? this.scaffoldBg,
        surfaceCard:     surfaceCard     ?? this.surfaceCard,
        surfaceElevated: surfaceElevated ?? this.surfaceElevated,
        drawerBg:        drawerBg        ?? this.drawerBg,
        textPrimary:     textPrimary     ?? this.textPrimary,
        textSecondary:   textSecondary   ?? this.textSecondary,
        textMuted:       textMuted       ?? this.textMuted,
        border:          border          ?? this.border,
        borderSubtle:    borderSubtle    ?? this.borderSubtle,
        handleBar:       handleBar       ?? this.handleBar,
        iconSecondary:   iconSecondary   ?? this.iconSecondary,
        snackbarBg:      snackbarBg      ?? this.snackbarBg,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      scaffoldBg:      Color.lerp(scaffoldBg,      other.scaffoldBg,      t)!,
      surfaceCard:     Color.lerp(surfaceCard,      other.surfaceCard,     t)!,
      surfaceElevated: Color.lerp(surfaceElevated,  other.surfaceElevated, t)!,
      drawerBg:        Color.lerp(drawerBg,         other.drawerBg,        t)!,
      textPrimary:     Color.lerp(textPrimary,      other.textPrimary,     t)!,
      textSecondary:   Color.lerp(textSecondary,    other.textSecondary,   t)!,
      textMuted:       Color.lerp(textMuted,        other.textMuted,       t)!,
      border:          Color.lerp(border,           other.border,          t)!,
      borderSubtle:    Color.lerp(borderSubtle,     other.borderSubtle,    t)!,
      handleBar:       Color.lerp(handleBar,        other.handleBar,       t)!,
      iconSecondary:   Color.lerp(iconSecondary,    other.iconSecondary,   t)!,
      snackbarBg:      Color.lerp(snackbarBg,       other.snackbarBg,      t)!,
    );
  }
}
