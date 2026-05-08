import 'package:flutter/material.dart';

class ReadAnywhereTheme {
  static ThemeData light() {
    const deepIndigo = Color(0xFF1A1630);
    const indigoSurface = Color(0xFF211C36);
    const indigoCard = Color(0xFF28213F);
    const warmGold = Color(0xFFC9AA78);
    const paper = Color(0xFFF3E7CF);
    const inkBlue = Color(0xFF2A2F4A);

    final scheme = ColorScheme.fromSeed(
      seedColor: warmGold,
      brightness: Brightness.dark,
      primary: warmGold,
      onPrimary: deepIndigo,
      secondary: paper,
      onSecondary: inkBlue,
      surface: indigoSurface,
      onSurface: paper,
      background: deepIndigo,
      onBackground: paper,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: deepIndigo,
      canvasColor: deepIndigo,
      appBarTheme: const AppBarTheme(
        backgroundColor: deepIndigo,
        foregroundColor: paper,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: paper,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: indigoCard,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: warmGold.withOpacity(0.20)),
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: warmGold,
        foregroundColor: deepIndigo,
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: warmGold,
        linearTrackColor: Color(0xFF3A334D),
      ),
      iconTheme: const IconThemeData(color: warmGold),
      listTileTheme: const ListTileThemeData(
        iconColor: warmGold,
        textColor: paper,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: indigoSurface,
        textStyle: TextStyle(color: paper),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: indigoCard,
        contentTextStyle: TextStyle(color: paper),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: warmGold),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: warmGold,
          foregroundColor: deepIndigo,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textTheme: const TextTheme(
        bodySmall: TextStyle(color: Color(0xFFCFC5B5), height: 1.35),
        bodyMedium: TextStyle(color: paper, height: 1.45),
        bodyLarge: TextStyle(color: paper, height: 1.55),
        titleMedium: TextStyle(color: paper, fontWeight: FontWeight.w600),
        titleLarge: TextStyle(color: paper, fontWeight: FontWeight.w700),
      ),
      dividerTheme: DividerThemeData(color: warmGold.withOpacity(0.18)),
    );
  }
}
