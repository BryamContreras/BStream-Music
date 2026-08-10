import 'package:flutter/material.dart';

import 'app_theme.dart';

abstract final class AppColors {
  static const brandGreen = Color(0xFF18C75A);
  static const downloadAccent = Color(0xFF0E9F4D);
  static const downloadAccentDark = Color(0xFF0B8F43);
  static const downloadGradient = <Color>[downloadAccent, downloadAccentDark];
  static const playerControlForeground = Colors.white;
  static const playbackPrimaryBackground = Colors.white;
  static const playbackPrimaryForeground = Color(0xFF07110A);
  static const playbackPrimaryDisabledBackground = Color(0xFFD6DAD7);
  static const playbackPrimaryDisabledForeground = Color(0xFF505751);

  // Neutral overlay surfaces. Keeping these outside the seeded ColorScheme
  // prevents Material 3 from adding a green cast to menus and popovers.
  static const menuBackground = Color(0xF20A0A0A);
  static const menuBorder = Color(0x2EFFFFFF);
  static const menuForeground = Color(0xFFF4F4F4);
  static const neutralSliderInactive = Color(0xFF5A5A5A);

  static Color downloadAccentFor(BuildContext context) {
    return Theme.of(context).extension<AppAccentTheme>()?.seed ??
        downloadAccent;
  }

  static List<Color> downloadGradientFor(BuildContext context) {
    return Theme.of(context).extension<AppAccentTheme>()?.downloadGradient ??
        downloadGradient;
  }

  static Color menuBackgroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? menuBackground
        : colors.surfaceContainerHighest.withValues(alpha: 0.97);
  }

  static Color menuForegroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? menuForeground
        : colors.onSurface;
  }

  static Color menuBorderFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? menuBorder
        : colors.outlineVariant.withValues(alpha: 0.9);
  }

  static Color menuInactiveSliderFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? neutralSliderInactive
        : colors.outlineVariant.withValues(alpha: 0.8);
  }

  /// Shared translucent surface for cards across both appearance modes. The
  /// same alpha keeps search/library cards visually comparable while the
  /// theme supplies the appropriate light or dark base color.
  static Color cardSurfaceFor(BuildContext context) {
    return Theme.of(context).colorScheme.surface.withValues(alpha: 0.64);
  }

  static Color cardBorderFor(BuildContext context) {
    return Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7);
  }

  static Color playbackPrimaryBackgroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? downloadAccentFor(context)
        : colors.primary;
  }

  static Color playbackPrimaryForegroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? playbackPrimaryForeground
        : Colors.black;
  }

  static Color playbackPrimaryDisabledBackgroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? downloadAccentFor(context).withValues(alpha: 0.38)
        : colors.primary.withValues(alpha: 0.38);
  }

  static Color playbackPrimaryDisabledForegroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? playbackPrimaryDisabledForeground
        : Colors.black.withValues(alpha: 0.62);
  }

  static Color playIconForegroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.light
        ? Colors.black
        : colors.onPrimary;
  }

  static Color playIconDisabledForegroundFor(BuildContext context) {
    return playIconForegroundFor(context).withValues(alpha: 0.62);
  }
}
