import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shared geometry for the player and lyrics menus. Their surface is independent
/// of the application's accent and Liquid Glass preference.
Future<T?> showAppMenuBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? artworkColor,
  Widget Function(BuildContext, Widget)? surfaceBuilder,
  bool useRootNavigator = false,
}) => showModalBottomSheet<T>(
  context: context,
  useRootNavigator: useRootNavigator,
  isDismissible: true,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: false,
  constraints: const BoxConstraints(maxWidth: 480),
  backgroundColor: Colors.transparent,
  elevation: 0,
  clipBehavior: Clip.none,
  barrierColor: Colors.black.withValues(alpha: .38),
  builder: (context) {
    final content = Builder(builder: builder);
    return surfaceBuilder?.call(context, content) ??
        AppMenuSheetSurface(artworkColor: artworkColor, child: content);
  },
);

/// A bounded menu with a supplied photographic background or an artwork-tinted
/// fallback. Neither treatment uses the application's accent or Liquid Glass.
class AppMenuSheetSurface extends StatelessWidget {
  const AppMenuSheetSurface({
    required this.child,
    this.artworkColor,
    this.background,
    super.key,
  });

  final Color? artworkColor;

  /// A bounded, non-interactive artwork backdrop supplied by playback UI.
  final Widget? background;
  final Widget child;
  static const _radius = BorderRadius.vertical(top: Radius.circular(28));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final artwork = artworkColor;
    final tone = artwork == null ? null : HSLColor.fromColor(artwork);
    final seededColors = ColorScheme.fromSeed(
      seedColor: artwork ?? const Color(0xFF808080),
      brightness: theme.brightness,
    );
    final colors = artwork == null || (tone?.saturation ?? 0) < .05
        ? seededColors.copyWith(
            primary: isDark ? const Color(0xFFD1D1D1) : const Color(0xFF555555),
            onPrimary: isDark ? Colors.black : Colors.white,
          )
        : seededColors;
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: tone == null
          ? (isDark
                ? const [Color(0xFF1B1B1B), Color(0xFF111111)]
                : const [Color(0xFFF5F5F5), Color(0xFFE9E9E9)])
          : [
              tone.withLightness(isDark ? .20 : .95).toColor(),
              tone.withLightness(isDark ? .13 : .89).toColor(),
            ],
    );
    // Keep typography/platform settings, but no accent-specific extension may
    // override the artwork palette inside these two menus.
    final menuTheme = theme.copyWith(
      colorScheme: colors,
      extensions: [
        for (final extension in theme.extensions.values)
          if (extension is! AppAccentTheme && extension is! AppSurfaceTheme)
            extension,
        const AppSurfaceTheme(backgroundMode: SurfaceBackgroundMode.accent),
      ],
    );
    return Theme(
      data: menuTheme,
      child: ClipRRect(
        borderRadius: _radius,
        child: AnimatedContainer(
          key: const ValueKey('app-menu-sheet-surface'),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: _radius,
            gradient: background == null ? gradient : null,
            color: background == null ? null : colors.surface,
            border: Border.all(color: colors.onSurface.withValues(alpha: .12)),
          ),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              if (background != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: RepaintBoundary(child: background!),
                    ),
                  ),
                ),
              Material(
                color: Colors.transparent,
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: colors.onSurface),
                  child: IconTheme.merge(
                    data: IconThemeData(color: colors.primary),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 36,
                          child: Center(
                            child: DecoratedBox(
                              key: const ValueKey('app-menu-sheet-drag-handle'),
                              decoration: BoxDecoration(
                                color: colors.onSurface.withValues(alpha: .38),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: const SizedBox(width: 32, height: 4),
                            ),
                          ),
                        ),
                        Flexible(fit: FlexFit.loose, child: child),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
