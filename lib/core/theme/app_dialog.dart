import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_theme.dart';

/// The blur applied inside modal dialog surfaces when glass is enabled.
const double appDialogBlurSigma = 14;

const EdgeInsets _defaultDialogInsetPadding = EdgeInsets.symmetric(
  horizontal: 40,
  vertical: 24,
);

/// Shows a Material dialog using the application's dialog surface.
///
/// Route behavior intentionally stays delegated to Flutter's [showDialog], so
/// barrier dismissal, focus traversal, safe areas, foldable positioning, and
/// transitions keep their platform behavior. Glass is painted by
/// [AppAlertDialog] and is therefore clipped to the dialog panel rather than
/// filtering the complete modal barrier.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useSafeArea = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
  TraversalEdgeBehavior? traversalEdgeBehavior,
  bool fullscreenDialog = false,
  bool? requestFocus,
  AnimationStyle? animationStyle,
}) {
  return showDialog<T>(
    context: context,
    builder: (dialogContext) {
      final dialog = builder(dialogContext);
      // Keep direct AlertDialog call sites safe while allowing dialog widgets
      // such as playlist pickers to own an AppAlertDialog internally.
      if (dialog is AlertDialog && dialog is! AppAlertDialog) {
        return AppAlertDialog.fromAlertDialog(dialog);
      }
      return dialog;
    },
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    barrierLabel: barrierLabel,
    useSafeArea: useSafeArea,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    traversalEdgeBehavior: traversalEdgeBehavior,
    fullscreenDialog: fullscreenDialog,
    requestFocus: requestFocus,
    animationStyle: animationStyle,
  );
}

/// An [AlertDialog] whose transparent mode blurs only its own surface.
///
/// The superclass still builds the title, content, scrolling region,
/// [OverflowBar], semantics, and their adaptive paddings. We only replace the
/// final public [Dialog] returned by [AlertDialog.build], keeping those Material
/// details aligned with the installed Flutter SDK.
class AppAlertDialog extends AlertDialog {
  const AppAlertDialog({
    super.key,
    super.icon,
    super.iconPadding,
    super.iconColor,
    super.title,
    super.titlePadding,
    super.titleTextStyle,
    super.content,
    super.contentPadding,
    super.contentTextStyle,
    super.actions,
    super.actionsPadding,
    super.actionsAlignment,
    super.actionsOverflowAlignment,
    super.actionsOverflowDirection,
    super.actionsOverflowButtonSpacing,
    super.buttonPadding,
    super.backgroundColor,
    super.elevation,
    super.shadowColor,
    super.surfaceTintColor,
    super.semanticLabel,
    super.insetPadding,
    super.clipBehavior,
    super.shape,
    super.alignment,
    super.constraints,
    super.scrollable,
  });

  factory AppAlertDialog.fromAlertDialog(AlertDialog dialog) {
    return AppAlertDialog(
      key: dialog.key,
      icon: dialog.icon,
      iconPadding: dialog.iconPadding,
      iconColor: dialog.iconColor,
      title: dialog.title,
      titlePadding: dialog.titlePadding,
      titleTextStyle: dialog.titleTextStyle,
      content: dialog.content,
      contentPadding: dialog.contentPadding,
      contentTextStyle: dialog.contentTextStyle,
      actions: dialog.actions,
      actionsPadding: dialog.actionsPadding,
      actionsAlignment: dialog.actionsAlignment,
      actionsOverflowAlignment: dialog.actionsOverflowAlignment,
      actionsOverflowDirection: dialog.actionsOverflowDirection,
      actionsOverflowButtonSpacing: dialog.actionsOverflowButtonSpacing,
      buttonPadding: dialog.buttonPadding,
      backgroundColor: dialog.backgroundColor,
      elevation: dialog.elevation,
      shadowColor: dialog.shadowColor,
      surfaceTintColor: dialog.surfaceTintColor,
      semanticLabel: dialog.semanticLabel,
      insetPadding: dialog.insetPadding,
      clipBehavior: dialog.clipBehavior,
      shape: dialog.shape,
      alignment: dialog.alignment,
      constraints: dialog.constraints,
      scrollable: dialog.scrollable,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dialog = super.build(context);
    final transparent =
        Theme.of(context).extension<AppSurfaceTheme>()?.backgroundMode ==
        SurfaceBackgroundMode.transparent;
    if (!transparent || dialog is! Dialog) {
      return dialog;
    }
    return _LocalBackdropDialog(dialog: dialog);
  }
}

/// Reproduces the public [Dialog] layout while inserting a backdrop layer as a
/// sibling immediately below its Material. Since the layer is constrained by
/// the same panel Stack and clipped with the resolved shape, pixels outside the
/// panel remain sharp and dialog text is never filtered.
class _LocalBackdropDialog extends StatelessWidget {
  const _LocalBackdropDialog({required this.dialog});

  final Dialog dialog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dialogTheme = DialogTheme.of(context);
    final useMaterial3 = theme.useMaterial3;
    final shape =
        dialog.shape ??
        dialogTheme.shape ??
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(useMaterial3 ? 28 : 4),
        );
    final backgroundColor =
        dialog.backgroundColor ??
        dialogTheme.backgroundColor ??
        (useMaterial3
            ? theme.colorScheme.surfaceContainerHigh
            : theme.brightness == Brightness.dark
            ? Colors.grey.shade800
            : Colors.white);
    final elevation =
        dialog.elevation ?? dialogTheme.elevation ?? (useMaterial3 ? 6 : 24);
    final shadowColor =
        dialog.shadowColor ??
        dialogTheme.shadowColor ??
        (useMaterial3 ? Colors.transparent : theme.shadowColor);
    final surfaceTintColor =
        dialog.surfaceTintColor ??
        dialogTheme.surfaceTintColor ??
        (useMaterial3 ? Colors.transparent : null);
    final effectivePadding =
        MediaQuery.viewInsetsOf(context) +
        (dialog.insetPadding ??
            dialogTheme.insetPadding ??
            _defaultDialogInsetPadding);
    final constraints =
        dialog.constraints ??
        dialogTheme.constraints ??
        const BoxConstraints(minWidth: 280);

    final panel = Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipPath(
            key: const ValueKey('app-dialog-local-blur-clip'),
            clipper: ShapeBorderClipper(shape: shape),
            clipBehavior: Clip.antiAlias,
            child: BackdropFilter(
              key: const ValueKey('app-dialog-local-backdrop-filter'),
              filter: ui.ImageFilter.blur(
                sigmaX: appDialogBlurSigma,
                sigmaY: appDialogBlurSigma,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Material(
          color: backgroundColor,
          elevation: elevation,
          shadowColor: shadowColor,
          surfaceTintColor: surfaceTintColor,
          shape: shape,
          type: MaterialType.card,
          clipBehavior:
              dialog.clipBehavior ?? dialogTheme.clipBehavior ?? Clip.none,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(
                child: ClipPath(
                  clipper: ShapeBorderClipper(shape: shape),
                  clipBehavior: Clip.antiAlias,
                  child: DecoratedBox(
                    key: const ValueKey('app-dialog-glass-gradient'),
                    decoration: BoxDecoration(
                      // The Material owns the surface/tint. This transparent
                      // base asks the shared helper only for its accent wash,
                      // layered below text and controls.
                      gradient: AppColors.glassSurfaceGradientFor(
                        context,
                        baseColor: Colors.transparent,
                        intensity: 0.82,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                ),
              ),
              ?dialog.child,
            ],
          ),
        ),
      ],
    );

    return Semantics(
      role: dialog.semanticsRole,
      child: AnimatedPadding(
        padding: effectivePadding,
        duration: dialog.insetAnimationDuration,
        curve: dialog.insetAnimationCurve,
        child: MediaQuery.removeViewInsets(
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          context: context,
          child: Align(
            alignment:
                dialog.alignment ?? dialogTheme.alignment ?? Alignment.center,
            child: ConstrainedBox(constraints: constraints, child: panel),
          ),
        ),
      ),
    );
  }
}
