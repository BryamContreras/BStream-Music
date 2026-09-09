part of 'music_providers.dart';

/// A resilient Search landing-page category.
///
/// [target] is present when YouTube Music advertised an exact mood/genre
/// destination. Curated fallback cards intentionally omit it and resolve via
/// the regular catalog search instead.
final class SearchBrowseCategory {
  const SearchBrowseCategory({
    required this.id,
    required this.title,
    required this.searchQuery,
    this.target,
  });

  final String id;
  final String title;
  final String searchQuery;
  final InnerTubeBrowseTarget? target;

  bool get isYouTubeMusicCategory => target != null;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SearchBrowseCategory &&
            id == other.id &&
            title == other.title &&
            searchQuery == other.searchQuery &&
            target == other.target;
  }

  @override
  int get hashCode => Object.hash(id, title, searchQuery, target);
}

final class SearchBrowseCatalog {
  SearchBrowseCatalog({
    required List<SearchBrowseCategory> categories,
    required this.usesLiveYouTubeMusicCategories,
  }) : categories = List<SearchBrowseCategory>.unmodifiable(categories);

  final List<SearchBrowseCategory> categories;
  final bool usesLiveYouTubeMusicCategories;
}

/// Always-available categories used while YouTube Music is loading and when
/// its private browse layout changes or the device is offline.
List<SearchBrowseCategory> fallbackSearchBrowseCategories(AppStrings strings) {
  return List<SearchBrowseCategory>.unmodifiable(<SearchBrowseCategory>[
    SearchBrowseCategory(
      id: 'pop',
      title: 'Pop',
      searchQuery: strings.choose('música pop', 'pop music'),
    ),
    SearchBrowseCategory(
      id: 'party',
      title: strings.choose('Fiesta', 'Party'),
      searchQuery: strings.choose('música para fiesta', 'party music'),
    ),
    const SearchBrowseCategory(
      id: 'reggae',
      title: 'Reggae',
      searchQuery: 'reggae',
    ),
    SearchBrowseCategory(
      id: 'chill',
      title: 'Chill',
      searchQuery: strings.choose('música chill', 'chill music'),
    ),
    SearchBrowseCategory(
      id: 'love',
      title: strings.choose('Amor', 'Love'),
      searchQuery: strings.choose('canciones de amor', 'love songs'),
    ),
    SearchBrowseCategory(
      id: 'electronic',
      title: strings.choose('Electrónica', 'Electronic'),
      searchQuery: strings.choose('música electrónica', 'electronic music'),
    ),
    SearchBrowseCategory(
      id: 'classical',
      title: strings.choose('Clásica', 'Classical'),
      searchQuery: strings.choose('música clásica', 'classical music'),
    ),
    const SearchBrowseCategory(id: 'jazz', title: 'Jazz', searchQuery: 'jazz'),
    const SearchBrowseCategory(
      id: 'rock',
      title: 'Rock',
      searchQuery: 'rock music',
    ),
    SearchBrowseCategory(
      id: 'latin',
      title: strings.choose('Latina', 'Latin'),
      searchQuery: strings.choose('música latina', 'latin music'),
    ),
    SearchBrowseCategory(
      id: 'hip-hop',
      title: 'Hip-Hop',
      searchQuery: strings.choose('música hip hop', 'hip hop music'),
    ),
    SearchBrowseCategory(
      id: 'workout',
      title: strings.choose('Entrenamiento', 'Workout'),
      searchQuery: strings.choose('música para entrenar', 'workout music'),
    ),
  ]);
}

/// Localized browse cards from YouTube Music, merged with curated fallbacks so
/// Search remains useful if the server returns only a very small regional set.
final searchBrowseCatalogProvider = FutureProvider<SearchBrowseCatalog>((
  ref,
) async {
  final strings = ref.watch(appStringsProvider);
  final fallback = fallbackSearchBrowseCategories(strings);
  final search = ref.watch(youtubeMusicSearchProvider);
  if (search is! YouTubeMusicMoodsAndGenres) {
    return SearchBrowseCatalog(
      categories: fallback,
      usesLiveYouTubeMusicCategories: false,
    );
  }

  try {
    final sections = await (search as YouTubeMusicMoodsAndGenres)
        .getMoodsAndGenres(maxSections: 8, maxCategoriesPerSection: 24);
    final liveCategories = <SearchBrowseCategory>[];
    final seenTargets = <String>{};
    final seenTitles = <String>{};
    for (final section in sections) {
      for (final category in section.categories) {
        final title = category.title.trim();
        final browseId = category.target.browseId.trim();
        final params = category.target.params.trim();
        if (title.isEmpty || browseId.isEmpty) continue;
        final targetKey = '$browseId\u0000$params';
        final titleKey = _normalizedBrowseCategoryTitle(title);
        if (!seenTargets.add(targetKey) || !seenTitles.add(titleKey)) continue;
        liveCategories.add(
          SearchBrowseCategory(
            id: 'yt:${_stableBrowseCategoryId(targetKey)}',
            title: title,
            searchQuery: title,
            target: InnerTubeBrowseTarget(browseId: browseId, params: params),
          ),
        );
      }
    }
    if (liveCategories.isEmpty) {
      return SearchBrowseCatalog(
        categories: fallback,
        usesLiveYouTubeMusicCategories: false,
      );
    }

    // Retain the regional YouTube order, then fill recognizable evergreen
    // categories that may be absent from a sparse or experimental response.
    for (final category in fallback) {
      if (liveCategories.length >= 24) break;
      if (seenTitles.add(_normalizedBrowseCategoryTitle(category.title))) {
        liveCategories.add(category);
      }
    }
    return SearchBrowseCatalog(
      categories: liveCategories.take(24).toList(growable: false),
      usesLiveYouTubeMusicCategories: true,
    );
  } catch (error, stackTrace) {
    debugPrint('YouTube Music browse categories unavailable: $error');
    debugPrintStack(stackTrace: stackTrace);
    return SearchBrowseCatalog(
      categories: fallback,
      usesLiveYouTubeMusicCategories: false,
    );
  }
});

/// Song queue behind one Search browse card.
///
/// Exact YouTube browse content wins. Some mood pages contain only playlist
/// shelves, so a bounded number of those collections is expanded. Every
/// private-layout/network failure falls back to the existing catalog search.
final searchBrowseCategoryTracksProvider = StreamProvider.autoDispose
    .family<List<TrackInfo>, SearchBrowseCategory>((ref, category) async* {
      final search = ref.watch(youtubeMusicSearchProvider);
      List<TrackInfo>? initialTracks;
      final target = category.target;
      if (target != null && search is YouTubeMusicMoodsAndGenres) {
        try {
          final tracks = await _loadYouTubeMusicBrowseTracks(
            search: search as YouTubeMusicMoodsAndGenres,
            collectionLookup: search is YouTubeMusicCollectionLookup
                ? search as YouTubeMusicCollectionLookup
                : null,
            target: target,
          );
          if (tracks.isNotEmpty) initialTracks = tracks;
        } catch (error, stackTrace) {
          debugPrint('YouTube Music category ${category.title} failed: $error');
          debugPrintStack(stackTrace: stackTrace);
        }
      }

      if (initialTracks == null) {
        final page = await ref
            .watch(remoteMusicDataSourceProvider)
            .searchCategory(category.searchQuery, SearchCategory.songs);
        initialTracks = List<TrackInfo>.unmodifiable(page.tracks.take(60));
      }
      yield initialTracks;

      await for (final enriched in _enrichBrowseTrackDurations(
        initialTracks,
        _browseDurationLookup(search),
        shouldContinue: () => ref.mounted,
      )) {
        if (!ref.mounted) return;
        yield enriched;
      }
    });

Future<List<TrackInfo>> _loadYouTubeMusicBrowseTracks({
  required YouTubeMusicMoodsAndGenres search,
  required YouTubeMusicCollectionLookup? collectionLookup,
  required InnerTubeBrowseTarget target,
}) async {
  final first = await search.getMoodOrGenre(
    target,
    maxSections: InnerTubeSearchService.maxHomeSections,
    maxItemsPerSection: InnerTubeSearchService.maxResults,
  );
  final pages = <InnerTubeMoodGenrePage>[first];
  final continuation = first.continuation?.trim();
  if (continuation != null && continuation.isNotEmpty) {
    try {
      pages.add(
        await search.getMoodOrGenreContinuation(
          continuation,
          maxSections: 4,
          maxItemsPerSection: 20,
        ),
      );
    } catch (error) {
      // Initial content remains valid when a continuation becomes stale.
      debugPrint('YouTube Music category continuation skipped: $error');
    }
  }

  final songs = <InnerTubeSong>[];
  final collections = <InnerTubeHomeCollection>[];
  for (final page in pages) {
    for (final section in page.sections) {
      songs.addAll(section.songs);
      collections.addAll(section.collections);
    }
  }

  if (songs.length < 20 && collectionLookup != null) {
    final uniqueCollections = <String, InnerTubeHomeCollection>{};
    for (final collection in collections) {
      final browseId = collection.browseId.trim();
      if (browseId.isNotEmpty) {
        uniqueCollections.putIfAbsent(browseId, () => collection);
      }
      if (uniqueCollections.length >= 4) break;
    }
    final resolved = await Future.wait(
      uniqueCollections.keys.map((browseId) async {
        try {
          return await collectionLookup.getCollectionSongs(browseId, limit: 20);
        } catch (error) {
          debugPrint('YouTube Music category collection skipped: $error');
          return const <InnerTubeSong>[];
        }
      }),
    );
    for (final collectionSongs in resolved) {
      songs.addAll(collectionSongs);
    }
  }

  final tracks = <TrackInfo>[];
  final seen = <String>{};
  for (final song in songs) {
    final track = trackInfoFromInnerTubeSong(song);
    final identity = track.id.trim().isNotEmpty ? track.id.trim() : track.url;
    if (identity.isEmpty || !seen.add(identity)) continue;
    tracks.add(track);
    if (tracks.length >= 60) break;
  }
  return List<TrackInfo>.unmodifiable(tracks);
}

Future<Duration?> Function(String videoId)? _browseDurationLookup(
  YouTubeMusicSearch search,
) {
  if (search is YouTubeMusicDurationLookup) {
    return (search as YouTubeMusicDurationLookup).getSongDuration;
  }
  if (search is YouTubeMusicTrackLookup) {
    final trackLookup = search as YouTubeMusicTrackLookup;
    return (videoId) async => (await trackLookup.getSong(videoId))?.duration;
  }
  return null;
}

/// Some compact mood shelves intentionally omit their duration column. The
/// initial list is already visible while this stream fills every missing value
/// in small batches, retaining browse titles, artists, artwork and ordering.
Stream<List<TrackInfo>> _enrichBrowseTrackDurations(
  List<TrackInfo> tracks,
  Future<Duration?> Function(String videoId)? lookup, {
  required bool Function() shouldContinue,
}) async* {
  if (lookup == null) return;
  final missingIndexes = <int>[
    for (var index = 0; index < tracks.length; index++)
      if (tracks[index].duration == null) index,
  ];
  if (missingIndexes.isEmpty) return;

  final enriched = List<TrackInfo>.of(tracks);
  const batchSize = 4;
  for (var offset = 0; offset < missingIndexes.length; offset += batchSize) {
    if (!shouldContinue()) return;
    final batch = missingIndexes.skip(offset).take(batchSize).toList();
    final durations = await Future.wait(
      batch.map((index) => _resolveBrowseDuration(lookup, tracks[index].id)),
    );
    if (!shouldContinue()) return;
    var changed = false;
    for (var resultIndex = 0; resultIndex < batch.length; resultIndex++) {
      final duration = durations[resultIndex];
      if (duration == null || duration <= Duration.zero) continue;
      final trackIndex = batch[resultIndex];
      enriched[trackIndex] = tracks[trackIndex].copyWith(duration: duration);
      changed = true;
    }
    if (changed) yield List<TrackInfo>.unmodifiable(List.of(enriched));
  }
}

Future<Duration?> _resolveBrowseDuration(
  Future<Duration?> Function(String videoId) lookup,
  String videoId,
) async {
  try {
    final duration = await lookup(videoId);
    if (duration != null && duration > Duration.zero) return duration;
  } catch (_) {
    // Transport retries already happen inside InnerTube. A single unavailable
    // video must not discard the category or stop subsequent batches.
  }
  return null;
}

String _normalizedBrowseCategoryTitle(String value) {
  final lower = value.trim().toLowerCase();
  const replacements = <String, String>{
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final character = String.fromCharCode(rune);
    final normalized = replacements[character] ?? character;
    if (RegExp(r'[a-z0-9]').hasMatch(normalized)) buffer.write(normalized);
  }
  return buffer.toString();
}

String _stableBrowseCategoryId(String value) {
  // FNV-1a keeps ValueKeys short and deterministic without exposing opaque
  // navigation parameters in the widget tree or logs.
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
