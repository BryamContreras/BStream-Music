import 'package:flutter/material.dart';

/// Returns an identity that changes only when the presented song changes.
///
/// Player updates such as position, buffering and play/pause must not restart
/// the visual transition. Remote and local sources still get a stable fallback
/// when a backend cannot provide a track id.
String playbackVisualIdentity({
  String? trackId,
  String? sourceUrl,
  String? title,
  String? artist,
  String? thumbnailUrl,
}) {
  final normalizedTrackId = _nonEmpty(trackId);
  if (normalizedTrackId != null) {
    return 'track:$normalizedTrackId';
  }

  final normalizedSource = _nonEmpty(sourceUrl);
  if (normalizedSource != null) {
    return 'source:$normalizedSource';
  }

  final normalizedTitle = _nonEmpty(title) ?? '';
  final normalizedArtist = _nonEmpty(artist) ?? '';
  final normalizedThumbnail = _nonEmpty(thumbnailUrl) ?? '';
  if (normalizedTitle.isEmpty &&
      normalizedArtist.isEmpty &&
      normalizedThumbnail.isEmpty) {
    return 'idle';
  }
  return 'metadata:$normalizedTitle\u0000$normalizedArtist\u0000$normalizedThumbnail';
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

/// Fades the incoming child over an opaque outgoing child.
///
/// A conventional cross-fade makes both children partially transparent at
/// the same time. Over a dark player surface that creates a noticeable dip in
/// luminance, as if the whole player blinked. Keeping the outgoing child fully
/// opaque until the incoming one covers it preserves the perceived brightness
/// throughout the transition.
Widget noDimmingFadeTransitionBuilder(
  Widget child,
  Animation<double> animation,
) {
  return _IncomingFadeOverPrevious(animation: animation, child: child);
}

class _IncomingFadeOverPrevious extends AnimatedWidget {
  const _IncomingFadeOverPrevious({
    required Animation<double> animation,
    required this.child,
  }) : super(listenable: animation);

  final Widget child;

  Animation<double> get animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    // AnimatedSwitcher reverses the outgoing child's animation. It remains
    // the fully opaque base while the new child fades in above it.
    final opacity = animation.status == AnimationStatus.reverse
        ? 1.0
        : animation.value.clamp(0.0, 1.0).toDouble();
    return Opacity(opacity: opacity, child: child);
  }
}

/// A short song-change transition that keeps its layout and brightness stable.
class TrackChangeTransition extends StatelessWidget {
  const TrackChangeTransition({
    required this.identity,
    required this.child,
    this.duration = const Duration(milliseconds: 420),
    this.alignment = Alignment.center,
    this.switcherKey,
    super.key,
  });

  final String identity;
  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;
  final Key? switcherKey;

  @override
  Widget build(BuildContext context) {
    // Async player providers briefly expose their idle snapshot while they
    // hydrate. Mount the first real song directly so opening the app never
    // cross-fades from placeholder metadata or duplicates its controls.
    if (identity == 'idle') {
      return child;
    }

    final effectiveDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : duration;
    return AnimatedSwitcher(
      key: switcherKey,
      duration: effectiveDuration,
      reverseDuration: effectiveDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: noDimmingFadeTransitionBuilder,
      child: KeyedSubtree(key: ValueKey(identity), child: child),
    );
  }
}
