import '../../../../../services/sharing/bstream_track_link.dart';
import '../../../../../services/youtube_music/innertube_search_service.dart';
import '../../../data/datasources/remote_music_datasource.dart';
import 'recommendation_playback_item.dart';

/// Continues a selected recommendation with YouTube Music's related radio.
///
/// The initial queue may contain a Home shelf or only the selected search
/// result. The callback retains its continuation token between invocations;
/// the player owns its lifetime and rejects results from an obsolete queue.
RecommendationQueueExtender buildRelatedRadioQueueExtender({
  required YouTubeMusicRelated related,
  required String seedVideoId,
  required List<RecommendationPlaybackItem> initialQueue,
}) {
  final expanded = List<RecommendationPlaybackItem>.of(initialQueue);
  const linkCodec = BStreamTrackLinkCodec();
  final seenVideoIds = initialQueue
      .map((item) => linkCodec.tryFromTrack(item.track)?.videoId)
      .whereType<String>()
      .toSet();
  final requestedContinuations = <String>{};
  String? continuation;
  var needsInitialPage = true;
  var exhausted = false;

  return () async {
    if (exhausted) {
      return List<RecommendationPlaybackItem>.unmodifiable(expanded);
    }

    final previousLength = expanded.length;
    // A continuation may contain only tracks already shown in the shelf.
    // Follow a bounded number of pages instead of prematurely ending radio.
    for (var request = 0; request < 3; request++) {
      if (!needsInitialPage) {
        final token = continuation;
        if (token == null ||
            token.isEmpty ||
            !requestedContinuations.add(token)) {
          exhausted = true;
          break;
        }
      }
      final page = needsInitialPage
          ? await related.getNext(seedVideoId, radio: true, limit: 30)
          : await related.getNextContinuation(continuation!, limit: 30);
      needsInitialPage = false;
      final nextContinuation = page.continuation?.trim();
      continuation = nextContinuation == null || nextContinuation.isEmpty
          ? null
          : nextContinuation;
      for (final song in page.songs) {
        if (!seenVideoIds.add(song.videoId)) {
          continue;
        }
        expanded.add(
          RecommendationPlaybackItem(track: trackInfoFromInnerTubeSong(song)),
        );
      }
      if (continuation == null) {
        exhausted = true;
      }
      if (expanded.length > previousLength || exhausted) {
        break;
      }
    }
    return List<RecommendationPlaybackItem>.unmodifiable(expanded);
  };
}
