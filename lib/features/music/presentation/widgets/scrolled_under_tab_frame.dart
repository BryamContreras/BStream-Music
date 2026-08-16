import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Keeps a tab header outside its scrollable body while reproducing the
/// Material 3 app-bar surface used when content scrolls underneath it.
class ScrolledUnderTabFrame extends StatefulWidget {
  const ScrolledUnderTabFrame({
    required this.header,
    required this.body,
    this.surfaceKey,
    this.headerHorizontalPadding = 16,
    super.key,
  });

  final Widget? header;
  final Widget body;
  final Key? surfaceKey;
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

  @override
  Widget build(BuildContext context) {
    final animationDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kThemeChangeDuration;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.tabBackgroundOverlayFor(context),
      ),
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: _handleMetricsNotification,
        child: NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.header case final header?)
                Material(
                  key: widget.surfaceKey,
                  color: AppColors.tabHeaderSurfaceFor(
                    context,
                    scrolledUnder: _scrolledUnder,
                  ),
                  elevation: _scrolledUnder ? 1 : 0,
                  shadowColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  animationDuration: animationDuration,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: widget.headerHorizontalPadding,
                      vertical: 8,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: header,
                      ),
                    ),
                  ),
                ),
              Expanded(child: widget.body),
            ],
          ),
        ),
      ),
    );
  }
}
