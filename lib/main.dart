import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/soundboard_screen.dart';

void main() {
  runApp(const SoundrApp());
}

class SoundrApp extends StatelessWidget {
  const SoundrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Soundr',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF6C63FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(
          ThemeData(brightness: Brightness.dark).textTheme,
        ),
      ),
      home: const SoundboardScreen(),
    );
  }
}
