import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import 'liquid_glass_surface.dart';

/// Glass material painted directly into a button, without sampling its backdrop.
/// The shared tint keeps it consistent with live glass over scrolling content.
ButtonStyle paintedGlassButtonStyle(
  BuildContext context, {
  bool circular = false,
}) {
  final colors = Theme.of(context).colorScheme;
  final dark = colors.brightness == Brightness.dark;
  return ButtonStyle(
    backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) => colors.onSurface.withValues(
        alpha: states.contains(WidgetState.disabled) ? 0.38 : 1,
      ),
    ),
    elevation: const WidgetStatePropertyAll(0),
    minimumSize: const WidgetStatePropertyAll(Size.square(48)),
    shape: WidgetStatePropertyAll(
      circular ? const CircleBorder() : const StadiumBorder(),
    ),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: (dark ? Colors.white : Colors.black).withValues(
          alpha: states.contains(WidgetState.disabled)
              ? 0.05
              : (dark ? 0.14 : 0.1),
        ),
      ),
    ),
    backgroundBuilder: (context, states, child) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: AppColors.glassSurfaceGradientFor(
          context,
          baseColor: LiquidGlassSurface.materialTintFor(
            context,
            materialOpacity: states.contains(WidgetState.disabled) ? 0.45 : 1,
          ),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: child,
    ),
  );
}
