import 'package:flutter/material.dart';

import 'lyrics_page.dart';

const lyricsPageRouteName = '/lyrics';

const _lyricsRouteTransitionDuration = Duration(milliseconds: 420);
const _lyricsRouteReverseTransitionDuration = Duration(milliseconds: 360);

/// Creates the coordinated transition between the playback surface and Lyrics.
///
/// Keeping this route in one place ensures the full player and the desktop mini
/// player use exactly the same motion in both directions.
PageRoute<void> buildLyricsPageRoute(BuildContext context) {
  return _LyricsPageRoute(
    disableAnimations: MediaQuery.disableAnimationsOf(context),
  );
}

class _LyricsPageRoute extends PageRouteBuilder<void> {
  _LyricsPageRoute({required this.disableAnimations})
    : super(
        settings: const RouteSettings(name: lyricsPageRouteName),
        transitionDuration: disableAnimations
            ? Duration.zero
            : _lyricsRouteTransitionDuration,
        reverseTransitionDuration: disableAnimations
            ? Duration.zero
            : _lyricsRouteReverseTransitionDuration,
        maintainState: true,
        allowSnapshotting: true,
        pageBuilder: (context, animation, secondaryAnimation) => Semantics(
          scopesRoute: true,
          explicitChildNodes: true,
          child: const LyricsPage(),
        ),
        transitionsBuilder: _buildLyricsTransition,
      );

  final bool disableAnimations;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      disableAnimations ? null : _buildPlaybackSurfaceTransition;
}

Widget _buildLyricsTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final motion = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
  final opacity = animation.drive(CurveTween(curve: Curves.easeInOut));

  return FadeTransition(
    key: const ValueKey('lyrics-route-fade-transition'),
    opacity: opacity,
    child: SlideTransition(
      key: const ValueKey('lyrics-route-slide-transition'),
      position: Tween<Offset>(
        begin: const Offset(0, 0.035),
        end: Offset.zero,
      ).animate(motion),
      child: ScaleTransition(
        key: const ValueKey('lyrics-route-scale-transition'),
        scale: Tween<double>(begin: 0.985, end: 1).animate(motion),
        child: RepaintBoundary(
          key: const ValueKey('lyrics-route-repaint-boundary'),
          child: child,
        ),
      ),
    ),
  );
}

Widget? _buildPlaybackSurfaceTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  bool allowSnapshotting,
  Widget? child,
) {
  if (child == null) {
    return null;
  }

  final motion = secondaryAnimation.drive(
    CurveTween(curve: Curves.easeInOutCubic),
  );
  return SlideTransition(
    key: const ValueKey('lyrics-route-player-slide-transition'),
    position: Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(0, -0.008),
    ).animate(motion),
    child: ScaleTransition(
      key: const ValueKey('lyrics-route-player-scale-transition'),
      scale: Tween<double>(begin: 1, end: 0.985).animate(motion),
      child: RepaintBoundary(child: child),
    ),
  );
}
