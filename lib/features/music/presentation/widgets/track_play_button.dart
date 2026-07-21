import 'package:flutter/material.dart';

import '../../../../core/platform/app_platform.dart';

/// Shared play/pause control used by every track list.
class TrackPlayButton extends StatelessWidget {
  const TrackPlayButton({
    required this.tooltip,
    required this.isPlaying,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final bool isPlaying;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final buttonSize = AppPlatform.isAndroid ? 38.0 : 52.0;
    final iconSize = AppPlatform.isAndroid ? 30.0 : 26.0;

    return SizedBox.square(
      dimension: buttonSize,
      child: IconButton(
        tooltip: tooltip,
        constraints: BoxConstraints.tight(Size.square(buttonSize)),
        padding: EdgeInsets.zero,
        iconSize: iconSize,
        style: IconButton.styleFrom(
          fixedSize: Size.square(buttonSize),
          minimumSize: Size.square(buttonSize),
          maximumSize: Size.square(buttonSize),
          foregroundColor: colors.onSurface,
          backgroundColor: const Color(0xFF282D2A),
          hoverColor: colors.onSurface.withValues(alpha: 0.1),
          focusColor: colors.onSurface.withValues(alpha: 0.12),
          highlightColor: colors.onSurface.withValues(alpha: 0.14),
          side: BorderSide(color: colors.onSurface.withValues(alpha: 0.09)),
          shape: const CircleBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
        onPressed: onPressed,
      ),
    );
  }
}
