import 'package:flutter/material.dart';

import 'lyrics_page.dart';
import 'playback_page_transition.dart';

const lyricsPageRouteName = '/lyrics';

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
            : playbackPageTransitionDuration,
        reverseTransitionDuration: disableAnimations
            ? Duration.zero
            : playbackPageReverseTransitionDuration,
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
  return PlaybackPageTransition(
    animation: animation,
    fadeKey: const ValueKey('lyrics-route-fade-transition'),
    slideKey: const ValueKey('lyrics-route-slide-transition'),
    repaintBoundaryKey: const ValueKey('lyrics-route-repaint-boundary'),
    child: child,
  );
}
