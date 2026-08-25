import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';

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
    super.key,
  });

  final Widget title;
  final Widget? leading;
  final Key? appBarKey;
  final Key? surfaceKey;
  final Key? blurKey;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transparent =
        AppColors.surfaceBackgroundModeFor(context) ==
        SurfaceBackgroundMode.transparent;
    final surface = DecoratedBox(
      key: surfaceKey,
      decoration: BoxDecoration(
        color: AppColors.tabHeaderSurfaceFor(context, scrolledUnder: true),
        gradient: AppColors.glassAccentGradientFor(context, intensity: 0.9),
      ),
      // AppBar gives flexibleSpace loose constraints; an empty DecoratedBox
      // would otherwise collapse and leave no painted/blurred surface.
      child: const SizedBox.expand(),
    );

    return AppBar(
      key: appBarKey,
      leading: leading,
      title: title,
      backgroundColor: Colors.transparent,
      foregroundColor: theme.colorScheme.onSurface,
      systemOverlayStyle:
          (theme.brightness == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(statusBarColor: Colors.transparent),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      forceMaterialTransparency: true,
      flexibleSpace: transparent
          ? ClipRect(
              child: BackdropFilter(
                key: blurKey,
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: surface,
              ),
            )
          : surface,
    );
  }
}

/// Blank scrollable space initially occupied by [SurfaceDetailAppBar].
/// It scrolls away, allowing subsequent content to pass behind the glass.
double surfaceDetailAppBarBodyInset(BuildContext context) {
  return MediaQuery.paddingOf(context).top + kToolbarHeight;
}
