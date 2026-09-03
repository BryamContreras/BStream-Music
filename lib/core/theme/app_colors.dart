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

  static SurfaceBackgroundMode surfaceBackgroundModeFor(BuildContext context) {
    return Theme.of(context).extension<AppSurfaceTheme>()?.backgroundMode ??
        SurfaceBackgroundMode.accent;
  }

  /// Shared background for fixed chrome. Accent mode remains deliberately
  /// substantial, while transparent mode keeps enough contrast for labels and
  /// lets the blurred content underneath remain recognizable.
  static Color surfaceChromeFor(
    BuildContext context, {
    double accentModeAlpha = 1,
    double transparentDarkAlpha = 0.34,
    double transparentLightAlpha = 0.42,
    double accentTintAlpha = 0.06,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final mode = surfaceBackgroundModeFor(context);
    if (mode.isLiquidGlass) {
      // LiquidGlassSurface owns the neutral material tint. Callers keep their
      // content layer clear so navigation, search and mini-player share one
      // consistent optical density.
      return Colors.transparent;
    }
    final surfaceAlpha = switch (mode) {
      SurfaceBackgroundMode.accent => accentModeAlpha,
      SurfaceBackgroundMode.transparent =>
        theme.brightness == Brightness.dark
            ? transparentDarkAlpha
            : transparentLightAlpha,
      SurfaceBackgroundMode.liquidGlass => 0.0,
    };
    return Color.alphaBlend(
      accent.withValues(alpha: accentTintAlpha),
      colors.surface.withValues(alpha: surfaceAlpha),
    );
  }

  /// Accent wash painted above translucent surfaces. The colors intentionally
  /// remain semi-transparent so the surface keeps the depth supplied by its
  /// [BackdropFilter] instead of becoming another opaque accent card.
  static LinearGradient glassAccentGradientFor(
    BuildContext context, {
    double intensity = 1,
    AlignmentGeometry begin = Alignment.centerLeft,
    AlignmentGeometry end = Alignment.centerRight,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accentTheme = theme.extension<AppAccentTheme>();
    final seed = accentTheme?.seed ?? colors.primary;
    final dark = accentTheme?.dark ?? colors.primary;
    final mode = surfaceBackgroundModeFor(context);
    final isDark = theme.brightness == Brightness.dark;
    if (mode.isLiquidGlass) {
      return LinearGradient(
        begin: begin,
        end: end,
        colors: <Color>[
          Colors.white.withValues(
            alpha: ((isDark ? 0.025 : 0.065) * intensity).clamp(0, 1),
          ),
          Colors.transparent,
          Colors.black.withValues(
            alpha: ((isDark ? 0.04 : 0.018) * intensity).clamp(0, 1),
          ),
        ],
        stops: const <double>[0, 0.52, 1],
      );
    }
    final edgeAlpha =
        switch (mode) {
          SurfaceBackgroundMode.accent => isDark ? 0.012 : 0.008,
          SurfaceBackgroundMode.transparent => isDark ? 0.018 : 0.012,
          SurfaceBackgroundMode.liquidGlass => isDark ? 0.032 : 0.022,
        } *
        intensity;
    final centerAlpha =
        switch (mode) {
          SurfaceBackgroundMode.accent => isDark ? 0.045 : 0.032,
          SurfaceBackgroundMode.transparent => isDark ? 0.075 : 0.052,
          SurfaceBackgroundMode.liquidGlass => isDark ? 0.105 : 0.074,
        } *
        intensity;

    return LinearGradient(
      begin: begin,
      end: end,
      colors: <Color>[
        dark.withValues(alpha: edgeAlpha.clamp(0, 1)),
        seed.withValues(alpha: centerAlpha.clamp(0, 1)),
        dark.withValues(alpha: edgeAlpha.clamp(0, 1)),
      ],
      stops: const <double>[0, 0.5, 1],
    );
  }

  /// Complete glass fill for widgets whose decoration cannot layer a base
  /// color and an accent wash independently.
  static LinearGradient glassSurfaceGradientFor(
    BuildContext context, {
    required Color baseColor,
    double intensity = 1,
    AlignmentGeometry begin = Alignment.centerLeft,
    AlignmentGeometry end = Alignment.centerRight,
  }) {
    final wash = glassAccentGradientFor(
      context,
      intensity: intensity,
      begin: begin,
      end: end,
    );
    return LinearGradient(
      begin: begin,
      end: end,
      colors: wash.colors
          .map((color) => Color.alphaBlend(color, baseColor))
          .toList(growable: false),
      stops: wash.stops,
    );
  }

  static Color menuBackgroundFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accentTheme = theme.extension<AppAccentTheme>();
    return _menuBackgroundForColors(
      seed: accentTheme?.seed ?? colors.primary,
      dark: accentTheme?.dark ?? colors.primary,
      colors: colors,
      backgroundMode: surfaceBackgroundModeFor(context),
    );
  }

  /// Popup-menu surface used while building the application theme. Keeping
  /// this calculation shared with [menuBackgroundFor] makes overlay routes
  /// react to the persisted surface preference just like in-tree widgets do.
  static Color menuBackgroundForTheme(
    AppAccent accent,
    ColorScheme colors, {
    required SurfaceBackgroundMode backgroundMode,
  }) {
    return _menuBackgroundForColors(
      seed: accent.seedColor,
      dark: accent.darkColor,
      colors: colors,
      backgroundMode: backgroundMode,
    );
  }

  static Color _menuBackgroundForColors({
    required Color seed,
    required Color dark,
    required ColorScheme colors,
    required SurfaceBackgroundMode backgroundMode,
  }) {
    final isDark = colors.brightness == Brightness.dark;
    final tint = isDark ? seed : dark;
    final base = switch (backgroundMode) {
      SurfaceBackgroundMode.accent =>
        isDark
            ? menuBackground
            : colors.surfaceContainerHighest.withValues(alpha: 0.97),
      SurfaceBackgroundMode.transparent => colors.surface.withValues(
        alpha: isDark ? 0.56 : 0.68,
      ),
      SurfaceBackgroundMode.liquidGlass =>
        (isDark ? Colors.black : Colors.white).withValues(
          alpha: isDark ? 0.16 : 0.22,
        ),
    };
    final tintStrength = switch (backgroundMode) {
      SurfaceBackgroundMode.accent => isDark ? 0.075 : 0.06,
      SurfaceBackgroundMode.transparent => isDark ? 0.09 : 0.07,
      SurfaceBackgroundMode.liquidGlass => 0.0,
    };
    return Color.alphaBlend(tint.withValues(alpha: tintStrength), base);
  }

  static Color neutralSurfaceFor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF141414)
        : const Color(0xFFF2F2F2);
  }

  /// Opaque, neutral desktop mini-player background with a restrained wash of
  /// the selected accent. Keeping this surface independent from artwork means
  /// the full player's cover-derived backdrop cannot bleed through it.
  static List<Color> desktopMiniPlayerGradientFor(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = downloadAccentFor(context);
    final base = isDark ? const Color(0xFF0C0D0D) : const Color(0xFFF4F5F4);
    final edgeStrength = isDark ? 0.025 : 0.018;
    final centerStrength = isDark ? 0.055 : 0.038;

    Color tinted(double strength) =>
        Color.alphaBlend(accent.withValues(alpha: strength), base);

    return <Color>[
      tinted(edgeStrength),
      tinted(centerStrength),
      tinted(edgeStrength),
    ];
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
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accentTheme = theme.extension<AppAccentTheme>();
    return _menuBorderForColors(
      seed: accentTheme?.seed ?? colors.primary,
      dark: accentTheme?.dark ?? colors.primary,
      colors: colors,
      backgroundMode: surfaceBackgroundModeFor(context),
    );
  }

  static Color menuBorderForTheme(
    AppAccent accent,
    ColorScheme colors, {
    required SurfaceBackgroundMode backgroundMode,
  }) {
    return _menuBorderForColors(
      seed: accent.seedColor,
      dark: accent.darkColor,
      colors: colors,
      backgroundMode: backgroundMode,
    );
  }

  static Color _menuBorderForColors({
    required Color seed,
    required Color dark,
    required ColorScheme colors,
    required SurfaceBackgroundMode backgroundMode,
  }) {
    final isDark = colors.brightness == Brightness.dark;
    final tint = isDark ? seed : dark;
    final base = isDark ? Colors.white : colors.outlineVariant;
    if (backgroundMode.isLiquidGlass) {
      return (isDark ? Colors.white : Colors.black).withValues(
        alpha: isDark ? 0.2 : 0.12,
      );
    }
    final tintStrength = switch (backgroundMode) {
      SurfaceBackgroundMode.accent => isDark ? 0.22 : 0.16,
      SurfaceBackgroundMode.transparent => isDark ? 0.3 : 0.22,
      SurfaceBackgroundMode.liquidGlass => isDark ? 0.36 : 0.28,
    };
    final alpha = switch (backgroundMode) {
      SurfaceBackgroundMode.accent => isDark ? 0.22 : 0.72,
      SurfaceBackgroundMode.transparent => isDark ? 0.34 : 0.52,
      SurfaceBackgroundMode.liquidGlass => isDark ? 0.46 : 0.64,
    };
    return Color.alphaBlend(
      tint.withValues(alpha: tintStrength),
      base,
    ).withValues(alpha: alpha);
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

  /// Shared surface for content cards.
  ///
  /// [solidInLiquidGlass] is an explicit opt-out for content that should keep
  /// a regular Material-card treatment while the surrounding application
  /// chrome uses Liquid Glass. Accent and transparent modes are unaffected.
  static Color cardSurfaceFor(
    BuildContext context, {
    bool solidInLiquidGlass = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mode = surfaceBackgroundModeFor(context);
    if (mode.isLiquidGlass && !solidInLiquidGlass) {
      return Colors.white.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.045 : 0.14,
      );
    }
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final tintedSurface = Color.alphaBlend(
      accent.withValues(alpha: 0.055),
      colors.surface,
    );
    final translucentSurface = tintedSurface.withValues(alpha: 0.72);
    if (!mode.isLiquidGlass) {
      return translucentSurface;
    }
    return Color.alphaBlend(translucentSurface, theme.scaffoldBackgroundColor);
  }

  static Color cardBorderFor(
    BuildContext context, {
    bool solidInLiquidGlass = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (surfaceBackgroundModeFor(context).isLiquidGlass &&
        !solidInLiquidGlass) {
      return (theme.brightness == Brightness.dark ? Colors.white : Colors.black)
          .withValues(alpha: theme.brightness == Brightness.dark ? 0.2 : 0.11);
    }
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final tintedBorder = Color.alphaBlend(
      accent.withValues(alpha: 0.18),
      colors.outlineVariant,
    );
    final translucentBorder = tintedBorder.withValues(alpha: 0.78);
    if (!surfaceBackgroundModeFor(context).isLiquidGlass) {
      return translucentBorder;
    }
    return Color.alphaBlend(
      translucentBorder,
      cardSurfaceFor(context, solidInLiquidGlass: true),
    );
  }

  /// Shared fill for text inputs. In transparent mode the field remains more
  /// opaque than the glass panel around it, keeping text and icons legible
  /// while still carrying a restrained accent tint.
  static Color inputSurfaceFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.extension<AppAccentTheme>();
    return _inputSurfaceForColors(
      seed: accent?.seed ?? colors.primary,
      dark: accent?.dark ?? colors.primary,
      colors: colors,
      backgroundMode: surfaceBackgroundModeFor(context),
    );
  }

  static Color inputSurfaceForTheme(
    AppAccent accent,
    ColorScheme colors, {
    required SurfaceBackgroundMode backgroundMode,
  }) {
    return _inputSurfaceForColors(
      seed: accent.seedColor,
      dark: accent.darkColor,
      colors: colors,
      backgroundMode: backgroundMode,
    );
  }

  static Color _inputSurfaceForColors({
    required Color seed,
    required Color dark,
    required ColorScheme colors,
    required SurfaceBackgroundMode backgroundMode,
  }) {
    if (backgroundMode.usesBackdrop) {
      final isDark = colors.brightness == Brightness.dark;
      if (backgroundMode.isLiquidGlass) {
        return (isDark ? Colors.black : Colors.white).withValues(
          alpha: isDark ? 0.2 : 0.24,
        );
      }
      final tint = isDark ? seed : dark;
      final base = colors.surface.withValues(alpha: isDark ? 0.74 : 0.82);
      return Color.alphaBlend(
        tint.withValues(alpha: isDark ? 0.10 : 0.08),
        base,
      );
    }
    final isDark = colors.brightness == Brightness.dark;
    final tint = isDark ? seed : dark;
    final base = colors.surfaceContainerHighest.withValues(alpha: 0.9);
    final tintStrength = isDark ? 0.075 : 0.06;
    return Color.alphaBlend(tint.withValues(alpha: tintStrength), base);
  }

  /// Shared surface for dialogs and other modal panels. It follows the same
  /// restrained accent wash as cards without inheriting Material 3's much
  /// brighter surface-container colors.
  static Color dialogSurfaceForTheme(
    AppAccent accent,
    ColorScheme colors, {
    SurfaceBackgroundMode backgroundMode = SurfaceBackgroundMode.accent,
  }) {
    final isDark = colors.brightness == Brightness.dark;
    final tint = isDark ? accent.seedColor : accent.darkColor;
    if (backgroundMode.isLiquidGlass) {
      return (isDark ? Colors.black : Colors.white).withValues(
        alpha: isDark ? 0.2 : 0.26,
      );
    }
    final surfaceAlpha = switch (backgroundMode) {
      SurfaceBackgroundMode.accent => 0.97,
      SurfaceBackgroundMode.transparent => isDark ? 0.7 : 0.78,
      SurfaceBackgroundMode.liquidGlass => 0.0,
    };
    final tintStrength = switch (backgroundMode) {
      SurfaceBackgroundMode.accent => isDark ? 0.08 : 0.06,
      SurfaceBackgroundMode.transparent => isDark ? 0.09 : 0.07,
      SurfaceBackgroundMode.liquidGlass => 0.0,
    };
    return Color.alphaBlend(
      tint.withValues(alpha: tintStrength),
      colors.surface.withValues(alpha: surfaceAlpha),
    );
  }

  static Color dialogBorderForTheme(
    AppAccent accent,
    ColorScheme colors, {
    SurfaceBackgroundMode backgroundMode = SurfaceBackgroundMode.accent,
  }) {
    final usesBackdrop = backgroundMode.usesBackdrop;
    if (backgroundMode.isLiquidGlass) {
      return (colors.brightness == Brightness.dark
              ? Colors.white
              : Colors.black)
          .withValues(
            alpha: colors.brightness == Brightness.dark ? 0.24 : 0.14,
          );
    }
    final tintStrength = switch (backgroundMode) {
      SurfaceBackgroundMode.accent =>
        colors.brightness == Brightness.dark ? 0.24 : 0.18,
      SurfaceBackgroundMode.transparent =>
        colors.brightness == Brightness.dark ? 0.32 : 0.24,
      SurfaceBackgroundMode.liquidGlass =>
        colors.brightness == Brightness.dark ? 0.4 : 0.3,
    };
    return Color.alphaBlend(
      (colors.brightness == Brightness.dark
              ? accent.seedColor
              : accent.darkColor)
          .withValues(alpha: tintStrength),
      colors.outlineVariant,
    ).withValues(alpha: usesBackdrop ? 0.74 : 0.9);
  }

  static Color dialogBarrierForTheme(
    ColorScheme colors, {
    required SurfaceBackgroundMode backgroundMode,
  }) {
    if (backgroundMode == SurfaceBackgroundMode.accent) {
      return Colors.black54;
    }
    final liquid = backgroundMode.isLiquidGlass;
    return Colors.black.withValues(
      alpha: colors.brightness == Brightness.dark
          ? liquid
                ? 0.26
                : 0.32
          : liquid
          ? 0.18
          : 0.22,
    );
  }

  static Color homeCardSurfaceFor(
    BuildContext context, {
    bool solidInLiquidGlass = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (surfaceBackgroundModeFor(context).isLiquidGlass) {
      if (solidInLiquidGlass) {
        return cardSurfaceFor(context, solidInLiquidGlass: true);
      }
      return Colors.white.withValues(
        alpha: theme.brightness == Brightness.dark ? 0.045 : 0.13,
      );
    }
    final accent = theme.extension<AppAccentTheme>()?.seed ?? colors.primary;
    final tintedSurface = Color.alphaBlend(
      accent.withValues(alpha: 0.07),
      colors.surface,
    );
    final mode = surfaceBackgroundModeFor(context);
    return tintedSurface.withValues(alpha: mode.isLiquidGlass ? 0.56 : 0.78);
  }

  /// Very light wash used by tab surfaces without turning the whole page into
  /// another card. The content underneath remains the dominant surface.
  static Color tabBackgroundOverlayFor(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    if (surfaceBackgroundModeFor(context).isLiquidGlass) {
      return Colors.transparent;
    }
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
    final accentDark =
        theme.extension<AppAccentTheme>()?.dark ?? colors.primary;
    final headerAccent = theme.brightness == Brightness.dark
        ? accent
        : accentDark;
    final surfaceMode = surfaceBackgroundModeFor(context);
    if (surfaceMode.isLiquidGlass) {
      final isDark = theme.brightness == Brightness.dark;
      final alpha = isDark
          ? scrolledUnder
                ? 0.12
                : 0.065
          : scrolledUnder
          ? 0.18
          : 0.11;
      return (isDark ? Colors.black : Colors.white).withValues(alpha: alpha);
    }
    if (surfaceMode.usesBackdrop) {
      final base = colors.surface.withValues(
        alpha: theme.brightness == Brightness.dark
            ? scrolledUnder
                  ? 0.52
                  : 0.38
            : scrolledUnder
            ? 0.6
            : 0.46,
      );
      final tintStrength = theme.brightness == Brightness.dark
          ? scrolledUnder
                ? 0.11
                : 0.085
          : scrolledUnder
          ? 0.085
          : 0.065;
      return Color.alphaBlend(
        headerAccent.withValues(alpha: tintStrength),
        base,
      );
    }
    final tintStrength = theme.brightness == Brightness.dark
        ? scrolledUnder
              ? 0.13
              : 0.1
        : scrolledUnder
        ? 0.105
        : 0.08;
    return Color.alphaBlend(
      headerAccent.withValues(alpha: tintStrength),
      colors.surface,
    );
  }

  static Color tabHeaderBorderFor(
    BuildContext context, {
    required bool scrolledUnder,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accentTheme = theme.extension<AppAccentTheme>();
    final accent = theme.brightness == Brightness.dark
        ? accentTheme?.seed ?? colors.primary
        : accentTheme?.dark ?? colors.primary;
    final surfaceMode = surfaceBackgroundModeFor(context);
    if (surfaceMode.isLiquidGlass) {
      return (theme.brightness == Brightness.dark ? Colors.white : Colors.black)
          .withValues(
            alpha: scrolledUnder
                ? theme.brightness == Brightness.dark
                      ? 0.24
                      : 0.14
                : theme.brightness == Brightness.dark
                ? 0.14
                : 0.08,
          );
    }
    final usesBackdrop = surfaceMode.usesBackdrop;
    final tintStrength = usesBackdrop
        ? scrolledUnder
              ? surfaceMode.isLiquidGlass
                    ? 0.4
                    : 0.32
              : surfaceMode.isLiquidGlass
              ? 0.3
              : 0.24
        : scrolledUnder
        ? 0.24
        : 0.16;
    return Color.alphaBlend(
      accent.withValues(alpha: tintStrength),
      colors.outlineVariant,
    ).withValues(alpha: scrolledUnder ? 0.5 : 0.3);
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
