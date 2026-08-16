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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (colors.brightness == Brightness.dark) {
      final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
      return Color.alphaBlend(accent.withValues(alpha: 0.04), Colors.white);
    }
    final accent = theme.extension<AppAccentTheme>()?.dark ?? colors.primary;
    return Color.alphaBlend(accent.withValues(alpha: 0.12), colors.onSurface);
  }

  static Color menuBorderFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? menuBorder
        : colors.outlineVariant.withValues(alpha: 0.9);
  }

  static Color menuIconFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (colors.brightness == Brightness.dark) {
      final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
      return Color.alphaBlend(accent.withValues(alpha: 0.62), menuForeground);
    }
    final accent = theme.extension<AppAccentTheme>()?.dark ?? colors.primary;
    return Color.alphaBlend(accent.withValues(alpha: 0.72), colors.onSurface);
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final tintedSurface = Color.alphaBlend(
      accent.withValues(alpha: 0.055),
      colors.surface,
    );
    return tintedSurface.withValues(alpha: 0.72);
  }

  static Color cardBorderFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final tintedBorder = Color.alphaBlend(
      accent.withValues(alpha: 0.18),
      colors.outlineVariant,
    );
    return tintedBorder.withValues(alpha: 0.78);
  }

  static Color homeCardSurfaceFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final tintedSurface = Color.alphaBlend(
      accent.withValues(alpha: 0.07),
      colors.surface,
    );
    return tintedSurface.withValues(alpha: 0.78);
  }

  /// Very light wash used by tab surfaces without turning the whole page into
  /// another card. The content underneath remains the dominant surface.
  static Color tabBackgroundOverlayFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    return accent.withValues(alpha: 0.025);
  }

  /// Distinct surface for fixed tab headers. It is slightly more accent-aware
  /// than [cardSurfaceFor], but remains neutral enough to sit above content.
  static Color tabHeaderSurfaceFor(
    BuildContext context, {
    required bool scrolledUnder,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final tintedSurface = Color.alphaBlend(
      accent.withValues(alpha: 0.06),
      colors.surface,
    );
    return scrolledUnder
        ? tintedSurface.withValues(alpha: 0.84)
        : tintedSurface;
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
        : colors.onPrimary;
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
        : colors.onPrimary.withValues(alpha: 0.62);
  }

  static Color playbackTitleFor(BuildContext context) {
    return _accentTextFor(
      context,
      base: neutralTitleFor(context),
      lightStrength: 0.26,
      darkStrength: 0.02,
    );
  }

  static Color neutralTitleFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return colors.brightness == Brightness.dark
        ? Colors.white
        : colors.onSurface;
  }

  static Color contentHeadingFor(BuildContext context) {
    return _accentTextFor(
      context,
      base: neutralTitleFor(context),
      lightStrength: 0.13,
      darkStrength: 0.04,
    );
  }

  static Color contentTitleFor(BuildContext context) {
    return _accentTextFor(
      context,
      base: neutralTitleFor(context),
      lightStrength: 0.10,
      darkStrength: 0.03,
    );
  }

  static Color contentSubtitleFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _accentTextFor(
      context,
      base: colors.onSurfaceVariant,
      lightStrength: 0.05,
      darkStrength: 0.02,
    );
  }

  static Color playbackControlForegroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (colors.brightness == Brightness.dark) {
      return colors.onSurface;
    }
    return Color.alphaBlend(
      colors.primary.withValues(alpha: 0.32),
      colors.onSurface,
    );
  }

  static Color playbackSecondaryControlForegroundFor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (colors.brightness == Brightness.dark) {
      return colors.onSurfaceVariant;
    }
    return Color.alphaBlend(
      colors.primary.withValues(alpha: 0.28),
      colors.onSurfaceVariant,
    );
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

  static Color _accentTextFor(
    BuildContext context, {
    required Color base,
    required double lightStrength,
    required double darkStrength,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accentTheme = theme.extension<AppAccentTheme>();
    final isDark = colors.brightness == Brightness.dark;
    final accent = isDark
        ? accentTheme?.seed ?? colors.primary
        : accentTheme?.dark ?? colors.primary;
    return Color.alphaBlend(
      accent.withValues(alpha: isDark ? darkStrength : lightStrength),
      base,
    );
  }
}
