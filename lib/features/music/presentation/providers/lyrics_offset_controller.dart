part of 'music_providers.dart';

typedef _LyricsTrackIdentity = String;

final _currentLyricsTrackIdentityProvider = Provider<_LyricsTrackIdentity?>((
  ref,
) {
  final metadata = ref.watch(
    playerControllerProvider.select((player) {
      final snapshot = player.value;
      return (
        trackId: snapshot?.trackId,
        sourceUrl: snapshot?.sourceUrl,
        title: snapshot?.title,
        artist: snapshot?.artist,
        isRemote: snapshot?.isRemote ?? false,
      );
    }),
  );

  final sourceUrl = _trimmedLyricsIdentityPart(metadata.sourceUrl);
  if (sourceUrl.isNotEmpty) {
    return 'source:$sourceUrl';
  }

  final trackId = _trimmedLyricsIdentityPart(metadata.trackId);
  if (trackId.isNotEmpty) {
    final namespace = metadata.isRemote ? 'remote' : 'local';
    return '$namespace:track:$trackId';
  }

  final title = _normalizedLyricsMetadataPart(metadata.title);
  final artist = _normalizedLyricsMetadataPart(metadata.artist);
  if (title.isEmpty && artist.isEmpty) {
    return null;
  }
  final namespace = metadata.isRemote ? 'remote' : 'local';
  return '$namespace:metadata:$title\u0000$artist';
});

final lyricsOffsetControllerProvider =
    NotifierProvider<LyricsOffsetController, Duration>(
      LyricsOffsetController.new,
    );

class LyricsOffsetController extends Notifier<Duration> {
  static const step = Duration(milliseconds: 500);
  static const minimum = Duration(seconds: -10);
  static const maximum = Duration(seconds: 10);

  _LyricsTrackIdentity? _lastIdentity;

  @override
  Duration build() {
    // Keep listening even while the lyrics route is closed. Only the stable
    // playback identity can reset the offset; position, duration, album and
    // status updates intentionally do not.
    _lastIdentity = ref.read(_currentLyricsTrackIdentityProvider);
    ref.listen<_LyricsTrackIdentity?>(_currentLyricsTrackIdentityProvider, (
      _,
      next,
    ) {
      if (next == null) {
        return;
      }
      final previous = _lastIdentity;
      _lastIdentity = next;
      if (previous != null && previous != next && state != Duration.zero) {
        state = Duration.zero;
      }
    });
    return Duration.zero;
  }

  void decrease() => setOffset(state - step);

  void increase() => setOffset(state + step);

  void reset() => setOffset(Duration.zero);

  void setOffset(Duration value) {
    final milliseconds = value.inMilliseconds.clamp(
      minimum.inMilliseconds,
      maximum.inMilliseconds,
    );
    final next = Duration(milliseconds: milliseconds.toInt());
    if (next != state) {
      state = next;
    }
  }
}

String _trimmedLyricsIdentityPart(String? value) => value?.trim() ?? '';

String _normalizedLyricsMetadataPart(String? value) =>
    value?.trim().toLowerCase() ?? '';
