import '../innertube_search_service.dart';
import 'youtube_music_account_gateway.dart';

/// Adapts the narrow authenticated account Home port to the catalog-facing
/// [YouTubeMusicHome] contract used by presentation providers.
class AuthenticatedYouTubeMusicHome implements YouTubeMusicHome {
  const AuthenticatedYouTubeMusicHome({
    required this.account,
    this.parser = const InnerTubeHomeParser(),
    this.maxContinuationRequests = 1,
  }) : assert(maxContinuationRequests >= 0);

  final YouTubeMusicAccountHome account;
  final InnerTubeHomeParser parser;
  final int maxContinuationRequests;

  @override
  Future<List<InnerTubeHomeSection>> getHome({
    int maxSections = 2,
    int maxItemsPerSection = 8,
  }) async {
    if (maxSections < 1 ||
        maxSections > InnerTubeSearchService.maxHomeSections) {
      throw RangeError.range(
        maxSections,
        1,
        InnerTubeSearchService.maxHomeSections,
        'maxSections',
      );
    }
    if (maxItemsPerSection < 1 ||
        maxItemsPerSection > InnerTubeSearchService.maxResults) {
      throw RangeError.range(
        maxItemsPerSection,
        1,
        InnerTubeSearchService.maxResults,
        'maxItemsPerSection',
      );
    }

    final sections = <InnerTubeHomeSection>[];
    final seenVideoIds = <String>{};
    final seenBrowseIds = <String>{};
    final seenArtistBrowseIds = <String>{};

    void addPage(Object? payload) {
      if (sections.length >= maxSections) return;
      final parsed = parser.parse(
        payload,
        maxSections: maxSections - sections.length,
        maxItemsPerSection: maxItemsPerSection,
      );
      for (final section in parsed) {
        final items = section.items
            .where((item) {
              return switch (item) {
                InnerTubeHomeSongItem(:final song) => seenVideoIds.add(
                  song.videoId,
                ),
                InnerTubeHomeCollection(:final browseId) => seenBrowseIds.add(
                  browseId,
                ),
                InnerTubeHomeArtistItem(:final artist) =>
                  seenArtistBrowseIds.add(artist.browseId),
              };
            })
            .toList(growable: false);
        if (items.isNotEmpty) {
          sections.add(
            InnerTubeHomeSection(title: section.title, items: items),
          );
        }
      }
    }

    var payload = await account.readMusicHomePage();
    addPage(payload);
    final requestedContinuations = <String>{};
    var continuationRequests = 0;
    var continuation = _homeContinuationToken(payload);
    while (sections.length < maxSections &&
        continuation != null &&
        continuationRequests < maxContinuationRequests &&
        requestedContinuations.add(continuation)) {
      continuationRequests += 1;
      payload = await account.readMusicHomePage(continuation: continuation);
      addPage(payload);
      continuation = _homeContinuationToken(payload);
    }
    return List<InnerTubeHomeSection>.unmodifiable(sections);
  }
}

String? _homeContinuationToken(Object? payload) {
  return _findContinuationToken(
        payload,
        containerNames: const <String>[
          'nextContinuationData',
          'reloadContinuationData',
        ],
      ) ??
      _findContinuationToken(
        payload,
        containerNames: const <String>['continuationCommand'],
      );
}

String? _findContinuationToken(
  Object? node, {
  required List<String> containerNames,
}) {
  if (node is Map) {
    for (final containerName in containerNames) {
      final container = node[containerName];
      if (container is! Map) continue;
      final token = (container['continuation'] ?? container['token'])
          ?.toString()
          .trim();
      if (token != null && token.isNotEmpty) return token;
    }
    for (final value in node.values) {
      final token = _findContinuationToken(
        value,
        containerNames: containerNames,
      );
      if (token != null) return token;
    }
  } else if (node is List) {
    for (final value in node) {
      final token = _findContinuationToken(
        value,
        containerNames: containerNames,
      );
      if (token != null) return token;
    }
  }
  return null;
}
