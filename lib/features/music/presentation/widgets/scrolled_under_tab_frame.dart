import 'package:flutter/material.dart';

/// Keeps a tab header outside its scrollable body while reproducing the
/// Material 3 app-bar surface used when content scrolls underneath it.
class ScrolledUnderTabFrame extends StatefulWidget {
  const ScrolledUnderTabFrame({
    required this.header,
    required this.body,
    this.surfaceKey,
    super.key,
  });

  final Widget? header;
  final Widget body;
  final Key? surfaceKey;

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
    final colors = Theme.of(context).colorScheme;
    final animationDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : kThemeChangeDuration;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _handleMetricsNotification,
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.header case final header?)
              Material(
                key: widget.surfaceKey,
                color: _scrolledUnder
                    ? colors.surfaceContainer
                    : colors.surface,
                elevation: _scrolledUnder ? 3 : 0,
                shadowColor: Colors.transparent,
                surfaceTintColor: colors.surfaceTint,
                animationDuration: animationDuration,
                child: header,
              ),
            Expanded(child: widget.body),
          ],
        ),
      ),
    );
  }
}
