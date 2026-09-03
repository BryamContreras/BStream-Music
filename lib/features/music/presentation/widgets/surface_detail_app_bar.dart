import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';

/// Top chrome for album, mix and artist detail routes.
///
/// The route body paints behind this bar so transparent surfaces can sample
/// the scrolling artwork and rows. Accent mode deliberately remains opaque.
class SurfaceDetailAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const SurfaceDetailAppBar({
    required this.title,
    this.leading,
    this.appBarKey,
    this.surfaceKey,
    this.blurKey,
    this.statusBarSurfaceKey,
    super.key,
  });

  final Widget title;
  final Widget? leading;
  final Key? appBarKey;
  final Key? surfaceKey;
  final Key? blurKey;
  final Key? statusBarSurfaceKey;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaceMode = AppColors.surfaceBackgroundModeFor(context);
    final transparent = surfaceMode.usesBackdrop && !surfaceMode.isLiquidGlass;
    final headerSurfaceColor = surfaceMode.isLiquidGlass
        ? theme.colorScheme.surface
        : AppColors.tabHeaderSurfaceFor(context, scrolledUnder: true);
    final surface = DecoratedBox(
      key: surfaceKey,
      decoration: BoxDecoration(
        color: headerSurfaceColor,
        gradient: surfaceMode.isLiquidGlass
            ? null
            : AppColors.glassAccentGradientFor(context, intensity: 0.9),
      ),
      // AppBar gives flexibleSpace loose constraints; an empty DecoratedBox
      // would otherwise collapse and leave no painted/blurred surface.
      child: const SizedBox.expand(),
    );
    final toolbarSurface = transparent
        ? ClipRect(
            child: BackdropFilter(
              key: blurKey,
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: surface,
            ),
          )
        : surface;
    final statusBarHeight = MediaQuery.paddingOf(context).top;
    final systemBarColor = theme.colorScheme.surface;
    final flexibleSpace = Column(
      children: [
        SizedBox(
          key: statusBarSurfaceKey,
          width: double.infinity,
          height: statusBarHeight,
          child: ColoredBox(color: systemBarColor),
        ),
        Expanded(child: toolbarSurface),
      ],
    );

    return AppBar(
      key: appBarKey,
      leading: leading,
      title: title,
      backgroundColor: transparent ? Colors.transparent : headerSurfaceColor,
      foregroundColor: theme.colorScheme.onSurface,
      systemOverlayStyle:
          (theme.brightness == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(statusBarColor: systemBarColor),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      forceMaterialTransparency: transparent,
      flexibleSpace: flexibleSpace,
    );
  }
}

/// Blank scrollable space initially occupied by [SurfaceDetailAppBar].
/// It scrolls away, allowing subsequent content to pass behind the glass.
double surfaceDetailAppBarBodyInset(BuildContext context) {
  return MediaQuery.paddingOf(context).top + kToolbarHeight;
}
