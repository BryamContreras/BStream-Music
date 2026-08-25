import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show ScrollCacheExtent, SliverPaintOrder;

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_ui.dart';

/// Hosts a tab's slivers in one scroll view and pins its dynamic header above
/// them. Keeping both in the same viewport lets content genuinely paint behind
/// translucent headers without predicting their text-scaled height.
class ScrolledUnderTabFrame extends StatefulWidget {
  const ScrolledUnderTabFrame({
    required this.header,
    required this.slivers,
    this.surfaceKey,
    this.scrollKey,
    this.scrollCacheExtent,
    this.headerTransitionKey,
    this.headerTransitionDuration = Duration.zero,
    this.headerHorizontalPadding = appTabTitleHorizontalPadding,
    super.key,
  });

  final Widget? header;
  final List<Widget> slivers;
  final Key? surfaceKey;
  final Key? scrollKey;
  final ScrollCacheExtent? scrollCacheExtent;
  final Key? headerTransitionKey;
  final Duration headerTransitionDuration;
  final double headerHorizontalPadding;

  @override
  State<ScrolledUnderTabFrame> createState() => _ScrolledUnderTabFrameState();
}

class _ScrolledUnderTabFrameState extends State<ScrolledUnderTabFrame> {
  bool _scrolledUnder = false;

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0 && notification is ScrollUpdateNotification) {
      _updateFromMetrics(notification.metrics);
    }
    return false;
  }

  bool _handleMetricsNotification(ScrollMetricsNotification notification) {
    if (notification.depth == 0) {
      _updateFromMetrics(notification.metrics);
    }
    return false;
  }

  void _updateFromMetrics(ScrollMetrics metrics) {
    final next = switch (metrics.axisDirection) {
      AxisDirection.down => metrics.extentBefore > 0,
      AxisDirection.up => metrics.extentAfter > 0,
      AxisDirection.left || AxisDirection.right => _scrolledUnder,
    };
    if (next == _scrolledUnder || !mounted) return;
    setState(() => _scrolledUnder = next);
  }

  Widget _buildHeaderSurface(
    BuildContext context,
    Widget header, {
    required Duration animationDuration,
  }) {
    final surface = Material(
      key: widget.surfaceKey,
      color: AppColors.tabHeaderSurfaceFor(
        context,
        scrolledUnder: _scrolledUnder,
      ),
      elevation: _scrolledUnder ? 1 : 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      animationDuration: animationDuration,
      child: DecoratedBox(
        key: const ValueKey('tab-header-accent-gradient'),
        decoration: BoxDecoration(
          gradient: AppColors.glassAccentGradientFor(
            context,
            intensity: _scrolledUnder ? 1 : 0.76,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: widget.headerHorizontalPadding,
            vertical: appTabTitleVerticalPadding,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Align(alignment: Alignment.centerLeft, child: header),
          ),
        ),
      ),
    );
    if (AppColors.surfaceBackgroundModeFor(context) !=
        SurfaceBackgroundMode.transparent) {
      return surface;
    }
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: surface,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final animationDuration = disableAnimations
        ? Duration.zero
        : kThemeChangeDuration;
    final headerTransitionDuration = disableAnimations
        ? Duration.zero
        : widget.headerTransitionDuration;
    final header = switch (widget.header) {
      final header? => _buildHeaderSurface(
        context,
        header,
        animationDuration: animationDuration,
      ),
      null => const SizedBox.shrink(
        key: ValueKey('scrolled-under-tab-hidden-header'),
      ),
    };

    final hasHeaderTransition =
        widget.headerTransitionKey != null ||
        widget.headerTransitionDuration != Duration.zero;
    final pinnedHeader = hasHeaderTransition
        ? ConstrainedBox(
            // A transitioning pinned sliver needs a positive extent even when
            // hidden. Otherwise the viewport may lazily unmount it and defer
            // an incoming header by a frame when the extent becomes non-zero.
            constraints: const BoxConstraints(minHeight: 0.001),
            child: ClipRect(
              child: AnimatedSwitcher(
                key: widget.headerTransitionKey,
                duration: headerTransitionDuration,
                reverseDuration: headerTransitionDuration,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.topCenter,
                  children: <Widget>[...previousChildren, ?currentChild],
                ),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    alignment: AlignmentDirectional.topStart,
                    child: child,
                  ),
                ),
                child: header,
              ),
            ),
          )
        : widget.header == null
        ? null
        : header;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.tabBackgroundOverlayFor(context),
      ),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: _handleMetricsNotification,
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: CustomScrollView(
            key: widget.scrollKey,
            scrollCacheExtent: widget.scrollCacheExtent,
            // The first sliver paints last, keeping the glass above content so
            // BackdropFilter can sample the already-painted rows underneath.
            paintOrder: SliverPaintOrder.firstIsTop,
            slivers: [
              if (pinnedHeader != null) PinnedHeaderSliver(child: pinnedHeader),
              ...widget.slivers,
            ],
          ),
        ),
      ),
    );
  }
}
