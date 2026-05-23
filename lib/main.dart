import 'package:flutter/material.dart';
import 'screens/soundboard_screen.dart';
import 'theme/app_colors.dart';

void main() {
  runApp(const SoundrApp());
}

class SoundrApp extends StatefulWidget {
  const SoundrApp({super.key});

  @override
  State<SoundrApp> createState() => _SoundrAppState();
}

class _SoundrAppState extends State<SoundrApp> {
  final _themeNotifier  = ValueNotifier(ThemeMode.dark);
  final _accentNotifier = ValueNotifier<Color>(const Color(0xFF6C63FF));

  ThemeData _buildTheme(Brightness brightness) {
    final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _accentNotifier.value,
        brightness: brightness,
      ),
      useMaterial3: true,
      scaffoldBackgroundColor: c.scaffoldBg,
      // Bundled Outfit font (variable). The 'Outfit' family is declared in
      // pubspec.yaml under flutter.fonts, so this resolves locally — no
      // runtime download, works fully offline.
      fontFamily: 'Outfit',
      textTheme: ThemeData(brightness: brightness)
          .textTheme
          .apply(fontFamily: 'Outfit'),
      appBarTheme: AppBarTheme(
        backgroundColor: c.scaffoldBg,
        foregroundColor: c.textPrimary,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        iconTheme: IconThemeData(color: c.textSecondary),
        actionsIconTheme: IconThemeData(color: c.textPrimary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surfaceCard,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surfaceCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.snackbarBg,
        contentTextStyle: TextStyle(color: c.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      extensions: [c],
    );
  }

  @override
  void dispose() {
    _themeNotifier.dispose();
    _accentNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeNotifier,
      builder: (context, mode, _) => ValueListenableBuilder<Color>(
        valueListenable: _accentNotifier,
        builder: (context, accent, child) => MaterialApp(
          title: 'Soundr Soundboard',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          themeMode: mode,
          home: SoundboardScreen(
            themeNotifier: _themeNotifier,
            accentNotifier: _accentNotifier,
          ),
        ),
      ),
    );
  }
}
