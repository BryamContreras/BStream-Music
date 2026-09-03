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

/// Brings the next song gently into place without moving or dimming the
/// outgoing one.
///
/// Keeping the previous surface still is important when several pieces of the
/// player (cover, metadata and mini-player) animate at the same time: two
/// independently moving outgoing trees read as a jump. The incoming surface
/// uses the same short lift and scale everywhere so the change feels like one
/// coordinated event instead of unrelated fades.
Widget smoothTrackChangeTransitionBuilder(
  Widget child,
  Animation<double> animation,
) {
  return _IncomingFadeOverPrevious(
    animation: animation,
    incomingOffset: const Offset(0, 0.025),
    incomingScale: 0.985,
    child: child,
  );
}

class _IncomingFadeOverPrevious extends AnimatedWidget {
  const _IncomingFadeOverPrevious({
    required Animation<double> animation,
    required this.child,
    this.incomingOffset = Offset.zero,
    this.incomingScale = 1,
  }) : super(listenable: animation);

  final Widget child;
  final Offset incomingOffset;
  final double incomingScale;

  Animation<double> get animation => listenable as Animation<double>;

  @override
  Widget build(BuildContext context) {
    // AnimatedSwitcher reverses the outgoing child's animation. It remains
    // the fully opaque, stationary base while the new child fades in above it.
    final outgoing = animation.status == AnimationStatus.reverse;
    final progress = outgoing
        ? 1.0
        : animation.value.clamp(0.0, 1.0).toDouble();
    final translation = Offset.lerp(incomingOffset, Offset.zero, progress)!;
    final scale = incomingScale + ((1 - incomingScale) * progress);
    return Opacity(
      opacity: outgoing ? 1.0 : progress,
      child: FractionalTranslation(
        translation: translation,
        child: Transform.scale(scale: scale, child: child),
      ),
    );
  }
}

/// A short song-change transition that keeps its layout and brightness stable.
class TrackChangeTransition extends StatefulWidget {
  const TrackChangeTransition({
    required this.identity,
    required this.child,
    this.duration = const Duration(milliseconds: 420),
    this.alignment = Alignment.center,
    this.switcherKey,
    this.enabled = true,
    super.key,
  });

  final String identity;
  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;
  final Key? switcherKey;
  final bool enabled;

  @override
  State<TrackChangeTransition> createState() => _TrackChangeTransitionState();
}

class _TrackChangeTransitionState extends State<TrackChangeTransition> {
  int _generation = 0;

  @override
  void didUpdateWidget(covariant TrackChangeTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      // A -> B -> A can happen before B's transition is complete when the user
      // taps next/previous quickly. A generation key prevents the returning A
      // from colliding with its still-mounted outgoing subtree.
      _generation += 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Async player providers briefly expose their idle snapshot while they
    // hydrate. Mount the first real song directly so opening the app never
    // cross-fades from placeholder metadata or duplicates its controls.
    if (!widget.enabled || widget.identity == 'idle') {
      return widget.child;
    }

    final effectiveDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : widget.duration;
    return AnimatedSwitcher(
      key: widget.switcherKey,
      duration: effectiveDuration,
      reverseDuration: effectiveDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: widget.alignment,
        clipBehavior: Clip.none,
        children: <Widget>[...previousChildren, ?currentChild],
      ),
      transitionBuilder: smoothTrackChangeTransitionBuilder,
      child: KeyedSubtree(
        key: ValueKey((widget.identity, _generation)),
        child: widget.child,
      ),
    );
  }
}
