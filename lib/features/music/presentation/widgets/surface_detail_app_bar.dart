import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/liquid_glass_surface.dart';

/// Signals only the start and end of vertical scrolling. Liquid Glass can use
/// its existing mobile motion treatment without rebuilding the scrolling body
/// for every update notification.
class GlassScrollMotionNotifier extends ValueNotifier<bool> {
  GlassScrollMotionNotifier() : super(false);

  static const settleDelay = Duration(milliseconds: 180);
  Timer? _settleTimer;

  void reset() {
    _settleTimer?.cancel();
    _settleTimer = null;
    if (value) value = false;
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  bool handleNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    final moving = switch (notification) {
      ScrollStartNotification() ||
      ScrollUpdateNotification() ||
      OverscrollNotification() => true,
      ScrollEndNotification() => false,
      UserScrollNotification(direction: ScrollDirection.idle) => false,
      _ => null,
    };
    if (moving == true) {
      _settleTimer?.cancel();
      _settleTimer = null;
      if (!value) value = true;
    } else if (moving == false && value) {
      // A finger can lift while momentum or another gesture is about to
      // continue. Do not repeatedly destroy/recreate the refractive pipeline
      // during those short gaps. The full resting optics still return once.
      _settleTimer ??= Timer(settleDelay, () {
        _settleTimer = null;
        value = false;
      });
    }
    return false;
  }
}

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
    this.backdropMotion,
    super.key,
  });

  final Widget title;
  final Widget? leading;
  final Key? appBarKey;
  final Key? surfaceKey;
  final Key? blurKey;
  final Key? statusBarSurfaceKey;
  final ValueListenable<bool>? backdropMotion;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final surfaceMode = AppColors.surfaceBackgroundModeFor(context);
    final liquidGlass = surfaceMode.isLiquidGlass;
    final transparent = surfaceMode.usesBackdrop && !liquidGlass;
    final headerSurfaceColor = AppColors.tabHeaderSurfaceFor(
      context,
      scrolledUnder: true,
    );
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
    Widget liquidToolbar(bool moving, Widget child) => LiquidGlassSurface(
      key: const ValueKey('surface-detail-liquid-glass'),
      borderRadius: BorderRadius.zero,
      blurSigma: 8,
      intensity: 1.2,
      edgeTreatment: LiquidGlassEdgeTreatment.bottom,
      backdropMotion: moving,
      child: child,
    );
    final motion = backdropMotion;
    final toolbarSurface = liquidGlass
        ? motion == null
              ? liquidToolbar(false, surface)
              : ValueListenableBuilder<bool>(
                  valueListenable: motion,
                  child: surface,
                  builder: (context, moving, child) =>
                      liquidToolbar(moving, child!),
                )
        : transparent
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
      backgroundColor: transparent || liquidGlass
          ? Colors.transparent
          : headerSurfaceColor,
      foregroundColor: theme.colorScheme.onSurface,
      systemOverlayStyle:
          (theme.brightness == Brightness.dark
                  ? SystemUiOverlayStyle.light
                  : SystemUiOverlayStyle.dark)
              .copyWith(statusBarColor: systemBarColor),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      forceMaterialTransparency: transparent || liquidGlass,
      flexibleSpace: flexibleSpace,
    );
  }
}

/// Blank scrollable space initially occupied by [SurfaceDetailAppBar].
/// It scrolls away, allowing subsequent content to pass behind the glass.
double surfaceDetailAppBarBodyInset(BuildContext context) {
  return MediaQuery.paddingOf(context).top + kToolbarHeight;
}
