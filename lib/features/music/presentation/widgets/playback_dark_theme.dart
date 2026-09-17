import 'package:flutter/material.dart';

import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_theme.dart';

/// Builds the isolated dark palette used by full-screen playback surfaces.
///
/// The application theme remains untouched, so leaving the player or Lyrics
/// immediately restores the user's selected light or dark appearance.
ThemeData alwaysDarkPlaybackTheme(ThemeData inheritedTheme) {
  final accentTheme = inheritedTheme.extension<AppAccentTheme>();
  final seed = accentTheme?.seed ?? inheritedTheme.colorScheme.primary;
  final darkAccent = accentTheme?.dark ?? inheritedTheme.colorScheme.primary;
  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      ).copyWith(
        surface: const Color(0xFF060806),
        surfaceContainerHighest: const Color(0xFF121612),
        primary: seed,
        primaryContainer: darkAccent,
        secondary: darkAccent,
        tertiary: seed,
      );

  return ThemeData(
    useMaterial3: inheritedTheme.useMaterial3,
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    extensions: inheritedTheme.extensions.values,
    scaffoldBackgroundColor: const Color(0xFF030504),
    platform: inheritedTheme.platform,
    visualDensity: inheritedTheme.visualDensity,
    materialTapTargetSize: inheritedTheme.materialTapTargetSize,
    splashFactory: inheritedTheme.splashFactory,
    pageTransitionsTheme: inheritedTheme.pageTransitionsTheme,
    iconButtonTheme: inheritedTheme.iconButtonTheme,
    filledButtonTheme: inheritedTheme.filledButtonTheme,
    textButtonTheme: inheritedTheme.textButtonTheme,
    tooltipTheme: inheritedTheme.tooltipTheme,
    fontFamily: AppPlatform.isLinux ? 'Roboto' : null,
    fontFamilyFallback: AppPlatform.isLinux ? const [] : null,
  );
}
