import 'package:flutter/material.dart';
import 'screens/soundboard_screen.dart';
import 'services/app_settings.dart';
import 'theme/app_colors.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the saved theme + accent before the first frame so the app doesn't
  // flash the defaults on every launch.
  await AppSettings.load();
  runApp(const SoundrApp());
}

class SoundrApp extends StatefulWidget {
  const SoundrApp({super.key});

  @override
  State<SoundrApp> createState() => _SoundrAppState();
}

class _SoundrAppState extends State<SoundrApp> {
  final _themeNotifier = AppSettings.themeMode;
  final _accentNotifier = AppSettings.accent;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _themeNotifier,
      builder: (context, mode, _) => ValueListenableBuilder<Color>(
        valueListenable: _accentNotifier,
        builder: (context, accent, child) => MaterialApp(
          title: 'Soundr Soundboard',
          debugShowCheckedModeBanner: false,
          theme: buildSoundrTheme(Brightness.light, accent),
          darkTheme: buildSoundrTheme(Brightness.dark, accent),
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

ThemeData buildSoundrTheme(Brightness brightness, Color accent) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ),
    useMaterial3: true,
    scaffoldBackgroundColor: c.scaffoldBg,
    // Bundled Outfit font (variable). The 'Outfit' family is declared in
    // pubspec.yaml under flutter.fonts, so this resolves locally — no
    // runtime download, works fully offline.
    fontFamily: 'Outfit',
    textTheme: ThemeData(
      brightness: brightness,
    ).textTheme.apply(fontFamily: 'Outfit'),
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
