import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/liquid_glass_surface.dart';

const _glassMenuVerticalPadding = EdgeInsets.symmetric(vertical: 8);
const _glassMenuBorderRadius = BorderRadius.all(Radius.circular(16));

/// A [PopupMenuButton] that keeps Flutter's route, positioning, focus and
/// semantics while replacing its solid fill with one continuous glass panel.
///
/// The application menus do not use [PopupMenuButton.initialValue]. Grouping
/// their entries under a single surface is therefore safe and avoids a
/// separate blur/gradient restarting on every row.
class GlassPopupMenuButton<T> extends PopupMenuButton<T> {
  // These parameters deliberately stay explicit because [itemBuilder] is
  // transformed before it reaches the superclass constructor.
  // ignore: use_super_parameters
  GlassPopupMenuButton({
    required PopupMenuItemBuilder<T> itemBuilder,
    PopupMenuItemSelected<T>? onSelected,
    PopupMenuCanceled? onCanceled,
    VoidCallback? onOpened,
    String? tooltip,
    EdgeInsetsGeometry padding = const EdgeInsets.all(8),
    Widget? child,
    BorderRadius? borderRadius,
    double? splashRadius,
    Widget? icon,
    double? iconSize,
    Offset offset = Offset.zero,
    bool enabled = true,
    Color? iconColor,
    bool? enableFeedback,
    BoxConstraints? constraints,
    PopupMenuPosition? position,
    bool useRootNavigator = false,
    AnimationStyle? popUpAnimationStyle,
    RouteSettings? routeSettings,
    ButtonStyle? style,
    bool? requestFocus,
    Key? key,
  }) : super(
         key: key,
         itemBuilder: (context) => _glassEntries(itemBuilder(context)),
         onSelected: onSelected,
         onCanceled: onCanceled,
         onOpened: onOpened,
         tooltip: tooltip,
         padding: padding,
         menuPadding: EdgeInsets.zero,
         child: child,
         borderRadius: borderRadius,
         splashRadius: splashRadius,
         icon: icon,
         iconSize: iconSize,
         offset: offset,
         enabled: enabled,
         color: Colors.transparent,
         surfaceTintColor: Colors.transparent,
         elevation: 0,
         shadowColor: Colors.transparent,
         shape: const RoundedSuperellipseBorder(
           borderRadius: _glassMenuBorderRadius,
         ),
         iconColor: iconColor,
         enableFeedback: enableFeedback,
         constraints: constraints,
         position: position,
         // The LiquidGlassSurface clips its interior and owns the only
         // exterior shadow. Let that shadow paint outside the transparent
         // popup route instead of clipping or duplicating it here.
         clipBehavior: Clip.none,
         useRootNavigator: useRootNavigator,
         popUpAnimationStyle: popUpAnimationStyle,
         routeSettings: routeSettings,
         style: style,
         requestFocus: requestFocus,
       );
}

List<PopupMenuEntry<T>> _glassEntries<T>(List<PopupMenuEntry<T>> entries) {
  if (entries.isEmpty) {
    return entries;
  }
  return <PopupMenuEntry<T>>[_GlassPopupMenuEntry<T>(entries: entries)];
}

class _GlassPopupMenuEntry<T> extends PopupMenuEntry<T> {
  const _GlassPopupMenuEntry({required this.entries});

  final List<PopupMenuEntry<T>> entries;

  @override
  double get height =>
      _glassMenuVerticalPadding.vertical +
      entries.fold<double>(0, (height, entry) => height + entry.height);

  @override
  bool represents(T? value) => entries.any((entry) => entry.represents(value));

  @override
  State<_GlassPopupMenuEntry<T>> createState() =>
      _GlassPopupMenuEntryState<T>();
}

class _GlassPopupMenuEntryState<T> extends State<_GlassPopupMenuEntry<T>> {
  Animation<double>? _routeAnimation;
  bool _routeIsAnimating = false;

  static bool _isMoving(AnimationStatus status) =>
      status == AnimationStatus.forward || status == AnimationStatus.reverse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeAnimation = ModalRoute.of(context)?.animation;
    if (identical(routeAnimation, _routeAnimation)) {
      return;
    }
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    _routeAnimation = routeAnimation;
    _routeIsAnimating =
        routeAnimation != null && _isMoving(routeAnimation.status);
    routeAnimation?.addStatusListener(_handleRouteAnimationStatus);
  }

  void _handleRouteAnimationStatus(AnimationStatus status) {
    final routeIsAnimating = _isMoving(status);
    if (!mounted || routeIsAnimating == _routeIsAnimating) {
      return;
    }
    setState(() => _routeIsAnimating = routeIsAnimating);
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleRouteAnimationStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configuredSurface = AppColors.menuBackgroundFor(context);
    final surfaceMode = AppColors.surfaceBackgroundModeFor(context);
    final transparent = surfaceMode.usesBackdrop;
    final glassSurface = configuredSurface.withValues(
      alpha: transparent
          ? configuredSurface.a
          : theme.brightness == Brightness.dark
          ? 0.82
          : 0.88,
    );

    final panel = DecoratedBox(
      key: const ValueKey('glass-popup-menu-surface'),
      decoration: BoxDecoration(
        color: surfaceMode.isLiquidGlass ? Colors.transparent : null,
        gradient: surfaceMode.isLiquidGlass
            ? null
            : AppColors.glassSurfaceGradientFor(
                context,
                baseColor: glassSurface,
                intensity: 1.2,
                begin: AlignmentDirectional.topStart,
                end: AlignmentDirectional.bottomEnd,
              ),
      ),
      child: Padding(
        padding: _glassMenuVerticalPadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: widget.entries,
        ),
      ),
    );
    if (surfaceMode.isLiquidGlass) {
      return LiquidGlassSurface(
        key: const ValueKey('glass-popup-menu-backdrop'),
        borderRadius: _glassMenuBorderRadius,
        blurSigma: 8,
        intensity: 1,
        edgeTreatment: LiquidGlassEdgeTreatment.perimeter,
        backdropMotion: _routeIsAnimating,
        child: panel,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: _glassMenuBorderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: theme.brightness == Brightness.dark ? 0.28 : 0.14,
            ),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRSuperellipse(
        borderRadius: _glassMenuBorderRadius,
        child: BackdropFilter(
          key: const ValueKey('glass-popup-menu-backdrop'),
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: panel,
        ),
      ),
    );
  }
}
