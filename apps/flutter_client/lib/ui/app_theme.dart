import 'package:flutter/material.dart';

class ReadAnywhereTheme {
  static ThemeData light() {
    const background = Color(0xFFF8F1E7);
    const surface = Color(0xFFFFF9F0);
    const text = Color(0xFF3D3028);
    const accent = Color(0xFF9B6A45);

    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.light,
        surface: surface,
        background: background,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: text, height: 1.45),
        bodyLarge: TextStyle(color: text, height: 1.55),
        titleLarge: TextStyle(color: text, fontWeight: FontWeight.w600),
      ),
    );
  }
}
