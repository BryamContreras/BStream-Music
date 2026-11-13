import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_shared_widgets.dart';
import '../../../../core/widgets/painted_glass_button_style.dart';

/// Artwork fills the route, including the system status area. Only navigation
/// controls respect the top safe inset, keeping the photo free of a title bar.
class ArtworkDetailScaffold extends StatefulWidget {
  const ArtworkDetailScaffold({
    required this.body,
    required this.bottomNavigationBar,
    required this.backButtonKey,
    this.extendBody = false,
    this.onBack,
    this.backTooltip,
    this.closeButton = false,
    this.selectionToolbar,
    this.statusBarFadeExtent = 20,
    super.key,
  });

  final Widget body;
  final Widget bottomNavigationBar;
  final Key backButtonKey;
  final bool extendBody;
  final VoidCallback? onBack;
  final String? backTooltip;
  final bool closeButton;
  final Widget? selectionToolbar;

  /// Length of the status-area contrast blend below the system inset.
  final double statusBarFadeExtent;

  @override
  State<ArtworkDetailScaffold> createState() => _ArtworkDetailScaffoldState();
}

class _ArtworkDetailScaffoldState extends State<ArtworkDetailScaffold> {
  // The two pinned lenses never overlap, so they share one backdrop input.
  final _navigationBackdropKey = BackdropKey();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final topInset = MediaQuery.paddingOf(context).top;
    final toolbar = widget.selectionToolbar;
    final accent =
        AppColors.surfaceBackgroundModeFor(context) ==
        SurfaceBackgroundMode.accent;
    final backButton = IconButton.filledTonal(
      key: widget.backButtonKey,
      tooltip:
          widget.backTooltip ??
          MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
      style: accent
          ? paintedGlassButtonStyle(
              context,
              circular: true,
            ).copyWith(fixedSize: const WidgetStatePropertyAll(Size.square(48)))
          : IconButton.styleFrom(
              fixedSize: const Size.square(48),
              backgroundColor: Colors.transparent,
              foregroundColor: colors.onSurface,
              shape: const CircleBorder(),
            ),
      icon: Icon(
        widget.closeButton ? Icons.close_rounded : Icons.arrow_back_rounded,
      ),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemStatusBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: colors.surface,
        extendBody: widget.extendBody,
        body: Stack(
          fit: StackFit.expand,
          children: [
            widget.body,
            if (topInset > 0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: topInset + widget.statusBarFadeExtent,
                child: IgnorePointer(
                  child: DecoratedBox(
                    key: const ValueKey('artwork-detail-status-bar-blend'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          colors.surface.withValues(alpha: 0.65),
                          colors.surface.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (accent)
                        backButton
                      else
                        AppInsetHeaderSurface(
                          padding: EdgeInsets.zero,
                          borderRadius: 999,
                          backdropGroupKey: _navigationBackdropKey,
                          child: backButton,
                        ),
                      if (toolbar != null) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: AppInsetHeaderSurface(
                            padding: EdgeInsets.zero,
                            borderRadius: 999,
                            backdropGroupKey: _navigationBackdropKey,
                            child: Material(
                              type: MaterialType.transparency,
                              child: SizedBox(height: 48, child: toolbar),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: widget.bottomNavigationBar,
      ),
    );
  }
}
