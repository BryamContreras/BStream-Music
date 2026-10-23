import '../../../../../services/sharing/bstream_track_link.dart';
import '../../../../../services/youtube_music/innertube_search_service.dart';
import '../../../data/datasources/remote_music_datasource.dart';
import 'recommendation_playback_item.dart';

/// Uses the library identity when an older history row lacks catalog metadata.
String? relatedRadioVideoId(RecommendationPlaybackItem item) {
  const codec = BStreamTrackLinkCodec();
  return codec.tryFromTrack(item.track)?.videoId ??
      codec.extractVideoId(item.localTrack?.sourceUrl ?? '') ??
      codec.extractVideoId(item.localTrack?.sourceId ?? '');
}

/// Resolves a local-only Continue selection when the player first needs radio.
///
/// The lookup is shared and performed once for this queue. It only supplies a
/// radio seed: the original local entries and current playback stay intact.
RecommendationQueueExtender buildMetadataRelatedRadioQueueExtender({
  required YouTubeMusicSearch search,
  required YouTubeMusicRelated related,
  required RecommendationPlaybackItem selected,
  required List<RecommendationPlaybackItem> initialQueue,
}) {
  final initial = List<RecommendationPlaybackItem>.unmodifiable(initialQueue);
  Future<RecommendationQueueExtender?>? resolution;
  Future<List<RecommendationPlaybackItem>>? inFlight;

  Future<RecommendationQueueExtender?> resolve() async {
    final title = selected.track.title.trim();
    if (title.isEmpty) return null;
    final artist = selected.track.artist.trim();
    final results = await search.searchSongs(
      artist.isEmpty ? title : '$title $artist',
      limit: 5,
    );
    const codec = BStreamTrackLinkCodec();
    for (final result in results) {
      final seed = codec.extractVideoId(result.videoId);
      if (seed == null) continue;
      return buildRelatedRadioQueueExtender(
        related: related,
        seedVideoId: seed,
        initialQueue: initial,
        excludedVideoIds: [seed],
      );
    }
    return null;
  }

  return () {
    final active = inFlight;
    if (active != null) return active;
    late final Future<List<RecommendationPlaybackItem>> operation;
    operation = () async {
      final extender = await (resolution ??= resolve());
      return extender == null ? initial : await extender();
    }();
    inFlight = operation;
    return operation.whenComplete(() {
      if (identical(inFlight, operation)) inFlight = null;
    });
  };
}

/// Continues a selected recommendation with YouTube Music's related radio.
///
/// The initial queue may contain a Home shelf or only the selected search
/// result. The callback retains its continuation token between invocations;
/// the player owns its lifetime and rejects results from an obsolete queue.
RecommendationQueueExtender buildRelatedRadioQueueExtender({
  required YouTubeMusicRelated related,
  required String seedVideoId,
  required List<RecommendationPlaybackItem> initialQueue,
  Iterable<String> excludedVideoIds = const [],
}) {
  final expanded = List<RecommendationPlaybackItem>.of(initialQueue);
  final seenVideoIds = {
    ...initialQueue.map(relatedRadioVideoId).whereType<String>(),
    ...excludedVideoIds,
  };
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
