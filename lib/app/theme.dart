import 'dart:io';

import 'package:flutter/material.dart';

/// One seed keeps the light and dark schemes in step.
const Color seedColor = Color(0xFF4F46E5);

ThemeData buildLightTheme() => _buildTheme(Brightness.light);

ThemeData buildDarkTheme() => _buildTheme(Brightness.dark);

/// Flutter Windows falls back to a CJK serif (SimSun) for Chinese text when
/// no CJK font is declared; Segoe UI only covers Latin. Name Microsoft YaHei
/// first so both scripts share one sans-serif stack.
final _fontFamily = Platform.isWindows ? 'Microsoft YaHei UI' : null;

ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );

  return ThemeData(
    fontFamily: _fontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 2,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: scheme.surface,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
  );
}
