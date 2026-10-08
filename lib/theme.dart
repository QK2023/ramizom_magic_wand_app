import 'package:flutter/material.dart';

const magicWandAccentColors = <String, Color>{
  'graphite': Color(0xFF292929),
  'sage': Color(0xFF4A6559),
  'blue': Color(0xFF3468A8),
  'violet': Color(0xFF7656A8),
  'rose': Color(0xFFA94F69),
  'amber': Color(0xFFA26524),
};

Color magicWandAccent(String name) =>
    magicWandAccentColors[name] ?? magicWandAccentColors['graphite']!;

ThemeData buildMagicWandTheme({
  Brightness brightness = Brightness.light,
  String accentColor = 'graphite',
}) {
  final dark = brightness == Brightness.dark;
  final generated = ColorScheme.fromSeed(
    seedColor: magicWandAccent(accentColor),
    brightness: brightness,
  );
  final scheme = generated.copyWith(
    primary: accentColor == 'graphite'
        ? (dark ? const Color(0xFFF1F1F1) : const Color(0xFF242424))
        : generated.primary,
    onPrimary: accentColor == 'graphite'
        ? (dark ? const Color(0xFF202020) : Colors.white)
        : generated.onPrimary,
    primaryContainer: accentColor == 'graphite'
        ? (dark ? const Color(0xFF353535) : const Color(0xFFEBEBEB))
        : generated.primaryContainer,
    onPrimaryContainer: accentColor == 'graphite'
        ? (dark ? const Color(0xFFF1F1F1) : const Color(0xFF242424))
        : generated.onPrimaryContainer,
    onSurface: dark ? const Color(0xFFEEEEEE) : const Color(0xFF262626),
    onSurfaceVariant: dark ? const Color(0xFFA5A5A5) : const Color(0xFF777777),
    outlineVariant: dark ? const Color(0xFF383838) : const Color(0xFFE4E4E4),
    surface: dark ? const Color(0xFF1C1C1C) : const Color(0xFFFFFFFF),
    surfaceContainerLowest: dark ? const Color(0xFF242424) : Colors.white,
    surfaceContainerLow: dark
        ? const Color(0xFF171717)
        : const Color(0xFFF7F7F7),
    surfaceContainer: dark ? const Color(0xFF2A2A2A) : const Color(0xFFF3F3F3),
    surfaceContainerHighest: dark
        ? const Color(0xFF323232)
        : const Color(0xFFEBEBEB),
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: .55)),
  );
  final textTheme = Typography.material2021().black
      .apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
        fontFamily: 'Segoe UI',
        fontFamilyFallback: const [
          'Microsoft YaHei',
          'Microsoft JhengHei',
          'sans-serif',
        ],
      )
      .copyWith(
        bodyMedium: TextStyle(
          fontFamily: 'Segoe UI',
          fontFamilyFallback: const ['Microsoft YaHei', 'Microsoft JhengHei'],
          fontSize: 15,
          height: 1.5,
          color: scheme.onSurface,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'Segoe UI',
          fontFamilyFallback: const ['Microsoft YaHei', 'Microsoft JhengHei'],
          fontSize: 16,
          height: 1.5,
          color: scheme.onSurface,
        ),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: 'Segoe UI',
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'Microsoft JhengHei',
      'sans-serif',
    ],
    scaffoldBackgroundColor: scheme.surface,
    textTheme: textTheme,
    dividerColor: scheme.outlineVariant.withValues(alpha: .4),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLowest,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.primary),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 450),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      textStyle: textTheme.bodySmall?.copyWith(
        fontSize: 12,
        color: scheme.onInverseSurface,
      ),
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(7),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered) ? 8 : 5,
      ),
      radius: const Radius.circular(8),
      thumbColor: WidgetStatePropertyAll(
        scheme.onSurfaceVariant.withValues(alpha: .32),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      labelStyle: textTheme.labelLarge?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: scheme.onSurface,
      ),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
        minimumSize: const Size(34, 34),
        padding: const EdgeInsets.all(8),
        iconSize: 18,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerLowest,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
  );
}
