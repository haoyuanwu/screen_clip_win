import 'package:flutter/material.dart';

ThemeData screenClipTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff007aff),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff141820)
        : const Color(0xfff5f6fa),
    fontFamily: 'SF Pro Text',
    fontFamilyFallback: const [
      'PingFang SC',
      'Segoe UI',
      'Microsoft YaHei',
      'sans-serif',
    ],
    dividerColor: dark ? const Color(0xff343c4b) : const Color(0xffe3e7ef),
    textTheme: ThemeData(brightness: brightness).textTheme.apply(
      fontFamily: 'SF Pro Text',
      bodyColor: dark ? const Color(0xffe6eaf3) : const Color(0xff222b40),
      displayColor: dark ? const Color(0xffe6eaf3) : const Color(0xff222b40),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xff232a36) : Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
