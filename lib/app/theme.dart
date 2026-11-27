import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// One seed keeps the light and dark schemes in step.
const Color seedColor = Color(0xFF4F46E5);

const String _windowsFont = 'Microsoft YaHei UI';
const List<String> _windowsFallback = ['Microsoft YaHei', 'Segoe UI'];

ThemeData buildLightTheme() => _buildTheme(Brightness.light);

ThemeData buildDarkTheme() => _buildTheme(Brightness.dark);

/// Flutter Windows falls back to a CJK serif for Chinese when no CJK face is
/// named, so the studio machine's YaHei UI is used with the plain family as a
/// fallback.
final _fontFamily = Platform.isWindows ? _windowsFont : null;

ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final desktop = Platform.isWindows;
  final base = ThemeData(
    fontFamily: _fontFamily,
    fontFamilyFallback: desktop ? _windowsFallback : null,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: desktop ? VisualDensity.compact : VisualDensity.standard,
    splashFactory: desktop ? NoSplash.splashFactory : null,
    splashColor: desktop ? Colors.transparent : null,
    highlightColor: desktop ? Colors.transparent : null,
    hoverColor: desktop ? Colors.transparent : null,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 2,
      titleTextStyle: TextStyle(
        fontFamily: _fontFamily,
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: scheme.surface,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
  );
  if (!desktop) return base;

  final text = base.textTheme
      .copyWith(
        headlineSmall: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: 0,
        ),
        titleLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: 0,
        ),
        titleMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
          letterSpacing: 0,
        ),
        titleSmall: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
          letterSpacing: 0,
        ),
        bodyLarge: TextStyle(
          fontSize: 14,
          color: scheme.onSurface,
          height: 1.55,
        ),
        bodyMedium: TextStyle(
          fontSize: 13.5,
          color: scheme.onSurface,
          height: 1.55,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant,
          height: 1.5,
        ),
        labelLarge: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: scheme.onSurface,
          letterSpacing: 0,
        ),
        labelMedium: TextStyle(
          fontSize: 12,
          color: scheme.onSurfaceVariant,
          letterSpacing: 0,
        ),
        labelSmall: TextStyle(
          fontSize: 11.5,
          color: scheme.onSurfaceVariant,
          letterSpacing: 0,
        ),
      )
      .apply(fontFamily: _windowsFont, fontFamilyFallback: _windowsFallback);

  return base.copyWith(
    textTheme: text,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      dense: true,
      minVerticalPadding: 4,
      visualDensity: VisualDensity.compact,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        overlayColor: Colors.transparent,
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        overlayColor: Colors.transparent,
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        overlayColor: Colors.transparent,
        textStyle: text.labelLarge,
      ),
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStatePropertyAll<Color?>(Colors.transparent),
      ),
    ),
    segmentedButtonTheme: const SegmentedButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStatePropertyAll<Color?>(Colors.transparent),
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    ),
    dividerTheme: const DividerThemeData(thickness: 1, space: 1),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 500),
    ),
  );
}
