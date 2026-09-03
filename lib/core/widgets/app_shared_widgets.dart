import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/app_ui.dart';
import 'liquid_glass_surface.dart';

/// Adds the lighter blur used behind text inputs when transparent surfaces are
/// enabled. The field's themed fill supplies the shared menu tint.
class AppSurfaceInput extends StatelessWidget {
  const AppSurfaceInput({
    required this.child,
    this.borderRadius = 8,
    this.blur = true,
    super.key,
  });

  final Widget child;
  final double borderRadius;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final mode = AppColors.surfaceBackgroundModeFor(context);
    if (!blur || !mode.usesBackdrop) {
      return child;
    }
    if (mode.isLiquidGlass) {
      return LiquidGlassSurface(
        borderRadius: BorderRadius.circular(borderRadius),
        blurSigma: 10,
        intensity: 0.9,
        child: child,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: child,
      ),
    );
  }
}

/// Accent-aware surface for internal page headings such as downloaded songs
/// and playlist names.
class AppInsetHeaderSurface extends StatelessWidget {
  const AppInsetHeaderSurface({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 6),
    this.borderRadius = appCardRadius,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    final mode = AppColors.surfaceBackgroundModeFor(context);
    final transparent = mode.usesBackdrop;
    final surface = DecoratedBox(
      key: const ValueKey('app-inset-header-surface'),
      decoration: BoxDecoration(
        color: transparent
            ? null
            : AppColors.tabHeaderSurfaceFor(context, scrolledUnder: true),
        gradient: mode.isLiquidGlass
            ? null
            : transparent
            ? AppColors.glassSurfaceGradientFor(
                context,
                baseColor: AppColors.menuBackgroundFor(context),
                intensity: 1.2,
              )
            : AppColors.glassAccentGradientFor(context, intensity: 0.9),
        borderRadius: radius,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (!transparent) {
      return surface;
    }
    if (mode.isLiquidGlass) {
      return LiquidGlassSurface(
        key: const ValueKey('app-inset-header-liquid-glass'),
        borderRadius: radius,
        blurSigma: 12,
        intensity: 1.02,
        child: surface,
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: surface,
      ),
    );
  }
}

/// A page-section heading that uses the shared [appSectionTitleStyle].
class AppSectionTitle extends StatelessWidget {
  const AppSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: appSectionTitleStyle(context));
  }
}

/// A list-entry card used across Settings, Library, and other pages.
/// All list cards share the same surface, border, radius, padding,
/// typography, and minimum height.
class AppListCard extends StatelessWidget {
  const AppListCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent,
    this.status,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? accent;
  final bool? status;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final highlight = accent ?? colors.primary;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: appContentMaxWidth),
      child: Material(
        color: appListCardSurface(context),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(appCardRadius),
          side: BorderSide(color: appListCardBorder(context)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: appListCardMinHeight),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                appListCardPaddingHorizontal,
                appListCardPaddingVertical,
                12,
                appListCardPaddingVertical,
              ),
              child: Row(
                children: [
                  Container(
                    width: appListCardIconSize,
                    height: appListCardIconSize,
                    decoration: BoxDecoration(
                      color: highlight.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(
                        appListCardIconRadius,
                      ),
                      border: Border.all(
                        color: highlight.withValues(alpha: 0.24),
                      ),
                    ),
                    child: Icon(icon, color: highlight, size: 24),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: appListCardTitleStyle(context),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: appListCardSubtitleStyle(context),
                        ),
                      ],
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(width: 8),
                    Icon(
                      status!
                          ? Icons.check_circle_rounded
                          : Icons.error_rounded,
                      color: status! ? colors.primary : colors.error,
                      size: 19,
                    ),
                  ],
                  if (trailing case final trailing?) ...[
                    const SizedBox(width: 8),
                    trailing,
                  ] else if (onTap != null) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A folder/list-shell wrapper for list items that need hover highlight
/// and a card-like surface.
class AppCardShell extends StatefulWidget {
  const AppCardShell({required this.child, super.key});

  final Widget child;

  @override
  State<AppCardShell> createState() => _AppCardShellState();
}

class _AppCardShellState extends State<AppCardShell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(appCardRadius),
      side: BorderSide(
        color: _hovered ? colors.primary : appListCardBorder(context),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        decoration: ShapeDecoration(
          color: appListCardSurface(context),
          shape: shape,
        ),
        child: Material(
          color: Colors.transparent,
          elevation: 0,
          shadowColor: const Color(0x14000000),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(appCardRadius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// A colored icon container used inside [AppListCard] entries that need
/// a gradient background instead of a solid accent tint.
class AppCardIcon extends StatelessWidget {
  const AppCardIcon({required this.icon, this.size = 58, super.key});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).extension<AppAccentTheme>();
    final gradientColors = accent == null
        ? const [Color(0xFF18C75A), Color(0xFF0B8F43), Color(0xFF076B35)]
        : [accent.seed, accent.dark, accent.dark.withValues(alpha: 0.78)];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(appCardRadius),
      ),
      child: Icon(icon, color: Theme.of(context).colorScheme.onPrimary),
    );
  }
}

/// A plain icon container used inside [AppListCard] when no gradient is needed.
class AppCardIconPlain extends StatelessWidget {
  const AppCardIconPlain({required this.icon, this.size = 58, super.key});

  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(appCardRadius),
      ),
      child: Icon(icon, color: colors.onSurfaceVariant, size: 20),
    );
  }
}
