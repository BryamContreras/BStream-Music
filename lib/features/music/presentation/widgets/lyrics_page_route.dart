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

  // Do not transform the whole playback route underneath Lyrics. HomePage
  // keeps every visited tab mounted, so a delegated scale would promote the
  // complete browsing/player stack to another full-screen layer while the
  // lyrics page is also being rasterized. The lyrics surface already fades
  // and slides in, which keeps the handoff fluid without that extra copy.
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
      child: RepaintBoundary(
        key: const ValueKey('lyrics-route-repaint-boundary'),
        child: child,
      ),
    ),
  );
}
