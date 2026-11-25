import 'package:flutter/material.dart';

abstract final class AppStyle {
  static const controlRadius = 8.0;
  static const panelRadius = 12.0;
  static const motionCurve = Curves.easeOutCubic;

  static Duration motion(BuildContext context, [int milliseconds = 160]) =>
      MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : Duration(milliseconds: milliseconds);

  static List<BoxShadow> shadows(ColorScheme colors, {bool floating = false}) {
    final dark = colors.brightness == Brightness.dark;
    return [
      BoxShadow(
        color: colors.shadow.withValues(alpha: dark ? .25 : .07),
        blurRadius: 4,
        offset: const Offset(0, 1),
      ),
      if (floating)
        BoxShadow(
          color: colors.shadow.withValues(alpha: dark ? .42 : .15),
          blurRadius: 20,
          offset: const Offset(0, 8),
        ),
    ];
  }

  static BoxDecoration panel(
    BuildContext context, {
    Color? color,
    bool floating = false,
    bool shadow = true,
  }) {
    final cs = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: color ?? cs.surface,
      borderRadius: BorderRadius.circular(panelRadius),
      border: Border.all(
        color: MediaQuery.highContrastOf(context)
            ? cs.outline
            : cs.outlineVariant,
      ),
      boxShadow: shadow ? shadows(cs, floating: floating) : null,
    );
  }
}

ThemeData screenClipTheme(Brightness brightness, {bool highContrast = false}) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff315cec),
    brightness: brightness,
    contrastLevel: highContrast ? .5 : 0,
    primary: dark ? const Color(0xffaebfff) : const Color(0xff254cce),
    onPrimary: dark ? const Color(0xff142451) : Colors.white,
    primaryContainer: dark ? const Color(0xff263969) : const Color(0xffe9eeff),
    onPrimaryContainer: dark
        ? const Color(0xffe1e8ff)
        : const Color(0xff203da1),
    surface: dark ? const Color(0xff1d222c) : Colors.white,
    surfaceContainerLowest: dark ? const Color(0xff141820) : Colors.white,
    surfaceContainerLow: dark
        ? const Color(0xff242b37)
        : const Color(0xfff5f7fb),
    surfaceContainer: dark ? const Color(0xff2a3240) : const Color(0xffeff2f8),
    surfaceContainerHigh: dark
        ? const Color(0xff323c4e)
        : const Color(0xffe8edf6),
    onSurface: dark ? const Color(0xffedf1f9) : const Color(0xff172135),
    onSurfaceVariant: dark ? const Color(0xffb5bfd2) : const Color(0xff4e5d74),
    outlineVariant: dark ? const Color(0xff3b4659) : const Color(0xffdce3ee),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark
        ? const Color(0xff151922)
        : const Color(0xfff2f5fa),
    fontFamily: 'SF Pro Text',
    fontFamilyFallback: const [
      'PingFang SC',
      'Segoe UI',
      'Microsoft YaHei',
      'sans-serif',
    ],
    dividerColor: scheme.outlineVariant,
    splashFactory: NoSplash.splashFactory,
  );
  final text = base.textTheme;
  final radius = BorderRadius.circular(AppStyle.controlRadius);
  final shape = RoundedRectangleBorder(borderRadius: radius);
  final fieldBorder = OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: scheme.outlineVariant),
  );

  return base.copyWith(
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        letterSpacing: -.35,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: text.bodyMedium?.copyWith(fontSize: 13, height: 1.4),
      bodySmall: text.bodySmall?.copyWith(fontSize: 12, height: 1.35),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: text.labelMedium?.copyWith(
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(40, 36),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(40, 36),
        shape: shape,
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(36, 34),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: fieldBorder.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
  );
}
