import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'innertube_exceptions.dart';
import 'innertube_models.dart';
import 'innertube_retry_policy.dart';
import 'innertube_transport.dart';

export 'innertube_exceptions.dart';
export 'innertube_models.dart';
export 'innertube_retry_policy.dart';
export 'innertube_transport.dart';

/// Maximum number of songs resolved for an album, playlist, or generated mix.
///
/// Catalog searches deliberately keep their smaller 20-result limit; detail
/// pages opt into this separate bound so a large response is not truncated by
/// the discovery limit.
const int innerTubeDetailResultLimit = 100;

/// Optional persistence boundary for YouTube's anonymous visitor identifier.
///
/// Implementations belong to the application layer (for example backed by
/// SharedPreferences); this service deliberately remains storage-agnostic.
abstract interface class InnerTubeVisitorDataStore {
  Future<String?> read();

  Future<void> write(String visitorData);

  Future<void> clear();
}

abstract interface class YouTubeMusicSearch {
  Future<List<InnerTubeSong>> searchSongs(String query, {int limit = 20});
}

abstract interface class YouTubeMusicCatalogSearch {
  Future<List<InnerTubeSong>> searchVideos(String query, {int limit = 20});

  Future<List<InnerTubeAlbum>> searchAlbums(String query, {int limit = 20});
}

/// Artist-only YouTube Music catalog search.
///
/// Kept separate from [YouTubeMusicCatalogSearch] so existing catalog adapters
/// that only support videos and albums remain source-compatible.
abstract interface class YouTubeMusicArtistSearch {
  Future<List<InnerTubeArtist>> searchArtists(String query, {int limit = 20});
}

abstract interface class YouTubeMusicTrackLookup {
  /// Returns the metadata for [videoId], or `null` when YouTube reports that
  /// the video is not currently playable music.
  Future<InnerTubeSong?> getSong(String videoId);
}

abstract interface class YouTubeMusicHome {
  Future<List<InnerTubeHomeSection>> getHome({
    int maxSections = 2,
    int maxItemsPerSection = 8,
  });
}

abstract interface class YouTubeMusicCollectionLookup {
  Future<List<InnerTubeSong>> getCollectionSongs(
    String browseId, {
    int limit = innerTubeDetailResultLimit,
  });
}

/// Resolves a public playlist's header metadata and songs together.
///
/// Implementations should obtain both from the same initial browse response,
/// rather than issuing a second request only for the title or artwork.
abstract interface class YouTubeMusicCollectionDetailLookup {
  Future<InnerTubeCollectionDetail> getCollectionDetail(
    String browseId, {
    int limit = innerTubeDetailResultLimit,
  });
}

abstract interface class YouTubeMusicAlbumLookup {
  Future<List<InnerTubeSong>> getAlbumSongs(
    String browseId, {
    int limit = innerTubeDetailResultLimit,
  });
}

abstract interface class YouTubeMusicRelated {
  /// Resolves YouTube Music's watch-next queue for [videoId].
  ///
  /// When [radio] is true the service requests `RDAMVM<videoId>` and
  /// transparently falls back to a plain watch-next request when the generated
  /// radio is empty or contains only the seed.
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = innerTubeDetailResultLimit,
  });

  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = innerTubeDetailResultLimit,
  });

  /// Follows the browse endpoint advertised by [getNext].
  Future<InnerTubeRelatedPage> getRelated(String browseId, {int limit = 20});

  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = 20,
  });
}

abstract interface class YouTubeMusicArtistLookup {
  /// Returns albums and singles exposed on a YouTube Music artist page.
  Future<List<InnerTubeAlbum>> getArtistReleases(
    String artistBrowseId, {
    int limit = 20,
  });
}

abstract interface class YouTubeMusicArtistProfileLookup {
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  });
}

abstract interface class YouTubeMusicPlaylistQueueLookup {
  Future<InnerTubeNextPage> getPlaylistNext(
    String playlistId, {
    String? videoId,
    int limit = innerTubeDetailResultLimit,
  });
}

class InnerTubeSearchService
    implements
        YouTubeMusicSearch,
        YouTubeMusicCatalogSearch,
        YouTubeMusicArtistSearch,
        YouTubeMusicTrackLookup,
        YouTubeMusicHome,
        YouTubeMusicCollectionLookup,
        YouTubeMusicCollectionDetailLookup,
        YouTubeMusicAlbumLookup,
        YouTubeMusicRelated,
        YouTubeMusicArtistLookup,
        YouTubeMusicArtistProfileLookup,
        YouTubeMusicPlaylistQueueLookup {
  factory InnerTubeSearchService({
    InnerTubeTransport? transport,
    InnerTubeVisitorDataStore? visitorDataStore,
    InnerTubeSearchParser parser = const InnerTubeSearchParser(),
    InnerTubeAlbumParser albumParser = const InnerTubeAlbumParser(),
    InnerTubeArtistSearchParser artistSearchParser =
        const InnerTubeArtistSearchParser(),
    InnerTubeHomeParser homeParser = const InnerTubeHomeParser(),
    InnerTubePlayerParser playerParser = const InnerTubePlayerParser(),
    InnerTubeNextParser nextParser = const InnerTubeNextParser(),
    InnerTubeRelatedParser relatedParser = const InnerTubeRelatedParser(),
    InnerTubeArtistParser artistParser = const InnerTubeArtistParser(),
    InnerTubeBootstrapParser bootstrapParser = const InnerTubeBootstrapParser(),
    Uri? endpoint,
    Uri? browseEndpoint,
    Uri? playerEndpoint,
    Uri? nextEndpoint,
    Uri? bootstrapUri,
    String language = 'es-419',
    String region = 'NI',
    String userAgent = defaultUserAgent,
    Duration requestTimeout = const Duration(seconds: 10),
    InnerTubeRetryPolicy retryPolicy = const InnerTubeRetryPolicy(),
    InnerTubeRetryDelay retryDelay = defaultInnerTubeRetryDelay,
    InnerTubeRetryClock retryClock = defaultInnerTubeRetryClock,
  }) {
    final normalizedLanguage = language.trim();
    final normalizedRegion = region.trim().toUpperCase();
    final normalizedUserAgent = userAgent.trim();
    if (normalizedLanguage.isEmpty) {
      throw ArgumentError.value(language, 'language', 'Must not be empty.');
    }
    if (normalizedRegion.isEmpty) {
      throw ArgumentError.value(region, 'region', 'Must not be empty.');
    }
    if (normalizedUserAgent.isEmpty) {
      throw ArgumentError.value(userAgent, 'userAgent', 'Must not be empty.');
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be positive.',
      );
    }

    return InnerTubeSearchService._(
      transport:
          transport ?? IoInnerTubeTransport(connectionTimeout: requestTimeout),
      visitorDataStore: visitorDataStore,
      parser: parser,
      albumParser: albumParser,
      artistSearchParser: artistSearchParser,
      homeParser: homeParser,
      playerParser: playerParser,
      nextParser: nextParser,
      relatedParser: relatedParser,
      artistParser: artistParser,
      bootstrapParser: bootstrapParser,
      endpoint:
          endpoint ?? Uri.parse('https://music.youtube.com/youtubei/v1/search'),
      browseEndpoint:
          browseEndpoint ??
          Uri.parse('https://music.youtube.com/youtubei/v1/browse'),
      playerEndpoint:
          playerEndpoint ??
          Uri.parse('https://music.youtube.com/youtubei/v1/player'),
      nextEndpoint:
          nextEndpoint ??
          Uri.parse('https://music.youtube.com/youtubei/v1/next'),
      bootstrapUri: bootstrapUri ?? Uri.parse('https://music.youtube.com/'),
      language: normalizedLanguage,
      region: normalizedRegion,
      userAgent: normalizedUserAgent,
      requestTimeout: requestTimeout,
      retryPolicy: retryPolicy,
      retryDelay: retryDelay,
      retryClock: retryClock,
    );
  }

  InnerTubeSearchService._({
    required InnerTubeTransport transport,
    required InnerTubeVisitorDataStore? visitorDataStore,
    required InnerTubeSearchParser parser,
    required InnerTubeAlbumParser albumParser,
    required InnerTubeArtistSearchParser artistSearchParser,
    required InnerTubeHomeParser homeParser,
    required InnerTubePlayerParser playerParser,
    required InnerTubeNextParser nextParser,
    required InnerTubeRelatedParser relatedParser,
    required InnerTubeArtistParser artistParser,
    required InnerTubeBootstrapParser bootstrapParser,
    required Uri endpoint,
    required Uri browseEndpoint,
    required Uri playerEndpoint,
    required Uri nextEndpoint,
    required Uri bootstrapUri,
    required String language,
    required String region,
    required String userAgent,
    required Duration requestTimeout,
    required InnerTubeRetryPolicy retryPolicy,
    required InnerTubeRetryDelay retryDelay,
    required InnerTubeRetryClock retryClock,
  }) : this._initialized(
         transport,
         visitorDataStore,
         parser,
         albumParser,
         artistSearchParser,
         homeParser,
         playerParser,
         nextParser,
         relatedParser,
         artistParser,
         bootstrapParser,
         endpoint,
         browseEndpoint,
         playerEndpoint,
         nextEndpoint,
         bootstrapUri,
         language,
         region,
         userAgent,
         requestTimeout,
         retryPolicy,
         retryDelay,
         retryClock,
       );

  InnerTubeSearchService._initialized(
    this._transport,
    this._visitorDataStore,
    this._parser,
    this._albumParser,
    this._artistSearchParser,
    this._homeParser,
    this._playerParser,
    this._nextParser,
    this._relatedParser,
    this._artistParser,
    this._bootstrapParser,
    this._endpoint,
    this._browseEndpoint,
    this._playerEndpoint,
    this._nextEndpoint,
    this._bootstrapUri,
    this._language,
    this._region,
    this._userAgent,
    this._requestTimeout,
    this._retryPolicy,
    this._retryDelay,
    this._retryClock,
  );

  static const int maxResults = 20;
  static const int maxDetailResults = innerTubeDetailResultLimit;
  static const int maxHomeSections = 6;
  static const int _maxHomeContinuationRequests = 1;
  static const int maxDetailContinuationRequests = 4;
  static const int _artistDurationLookupConcurrency = 3;
  static const String songsFilter = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';
  static const String videosFilter = 'EgWKAQIQAWoMEA4QChADEAQQCRAF';
  static const String albumsFilter = 'EgWKAQIYAWoMEA4QChADEAQQCRAF';
  static const String artistsFilter = 'EgWKAQIgAWoMEA4QChADEAQQCRAF';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/140.0.0.0 Safari/537.36';

  final InnerTubeTransport _transport;
  final InnerTubeVisitorDataStore? _visitorDataStore;
  final InnerTubeSearchParser _parser;
  final InnerTubeAlbumParser _albumParser;
  final InnerTubeArtistSearchParser _artistSearchParser;
  final InnerTubeHomeParser _homeParser;
  final InnerTubePlayerParser _playerParser;
  final InnerTubeNextParser _nextParser;
  final InnerTubeRelatedParser _relatedParser;
  final InnerTubeArtistParser _artistParser;
  final InnerTubeBootstrapParser _bootstrapParser;
  final Uri _endpoint;
  final Uri _browseEndpoint;
  final Uri _playerEndpoint;
  final Uri _nextEndpoint;
  final Uri _bootstrapUri;
  final String _language;
  final String _region;
  final String _userAgent;
  final Duration _requestTimeout;
  final InnerTubeRetryPolicy _retryPolicy;
  final InnerTubeRetryDelay _retryDelay;
  final InnerTubeRetryClock _retryClock;

  bool _disposed = false;
  Future<InnerTubeConfiguration>? _configurationFuture;
  Future<InnerTubeConfiguration>? _freshConfigurationFuture;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = maxResults,
  }) async {
    _ensureActive();
    _validateResultLimit(limit);
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final decoded = await _searchCatalog(normalizedQuery, filter: songsFilter);
    return _parser.parse(decoded, limit: limit);
  }

  @override
  Future<List<InnerTubeSong>> searchVideos(
    String query, {
    int limit = maxResults,
  }) async {
    _ensureActive();
    _validateResultLimit(limit);
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final decoded = await _searchCatalog(normalizedQuery, filter: videosFilter);
    return _parser.parse(decoded, limit: limit);
  }

  @override
  Future<List<InnerTubeAlbum>> searchAlbums(
    String query, {
    int limit = maxResults,
  }) async {
    _ensureActive();
    _validateResultLimit(limit);
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final decoded = await _searchCatalog(normalizedQuery, filter: albumsFilter);
    return _albumParser.parse(decoded, limit: limit);
  }

  @override
  Future<List<InnerTubeArtist>> searchArtists(
    String query, {
    int limit = maxResults,
  }) async {
    _ensureActive();
    _validateResultLimit(limit);
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return const [];
    }

    final decoded = await _searchCatalog(
      normalizedQuery,
      filter: artistsFilter,
    );
    return _artistSearchParser.parse(decoded, limit: limit);
  }

  Future<Object?> _searchCatalog(String query, {required String filter}) async {
    var configuration = await _configuration();
    var response = await _requestSearch(query, filter, configuration);
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestSearch(query, filter, configuration);
    }

    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw InnerTubeHttpException(response.statusCode, response.body);
    }

    late final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(
        'YouTube Music returned invalid JSON: ${error.message}',
      );
    }
    return decoded;
  }

  @override
  Future<List<InnerTubeHomeSection>> getHome({
    int maxSections = 2,
    int maxItemsPerSection = 8,
  }) async {
    _ensureActive();
    if (maxSections < 1 || maxSections > maxHomeSections) {
      throw RangeError.range(maxSections, 1, maxHomeSections, 'maxSections');
    }
    if (maxItemsPerSection < 1 || maxItemsPerSection > maxResults) {
      throw RangeError.range(
        maxItemsPerSection,
        1,
        maxResults,
        'maxItemsPerSection',
      );
    }

    var configuration = await _configuration();
    var response = await _requestBrowse(
      configuration,
      browseId: 'FEmusic_home',
    );
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestBrowse(configuration, browseId: 'FEmusic_home');
    }

    var decoded = _decodeHomeResponse(response);
    final sections = <InnerTubeHomeSection>[];
    final seenVideoIds = <String>{};
    final seenBrowseIds = <String>{};
    final seenArtistBrowseIds = <String>{};
    sections.addAll(
      _homeParser._parse(
        decoded,
        maxSections: maxSections,
        maxItemsPerSection: maxItemsPerSection,
        seenVideoIds: seenVideoIds,
        seenBrowseIds: seenBrowseIds,
        seenArtistBrowseIds: seenArtistBrowseIds,
      ),
    );

    final requestedContinuationTokens = <String>{};
    var continuationRequests = 0;
    var continuation = _homeContinuationToken(decoded);
    while (sections.length < maxSections &&
        continuation != null &&
        continuationRequests < _maxHomeContinuationRequests &&
        requestedContinuationTokens.add(continuation)) {
      continuationRequests += 1;
      try {
        response = await _requestBrowse(
          configuration,
          continuation: continuation,
        );
        if (_needsFreshConfiguration(response.statusCode)) {
          configuration = await _freshConfiguration();
          response = await _requestBrowse(
            configuration,
            continuation: continuation,
          );
        }

        decoded = _decodeHomeResponse(response);
        sections.addAll(
          _homeParser._parse(
            decoded,
            maxSections: maxSections - sections.length,
            maxItemsPerSection: maxItemsPerSection,
            seenVideoIds: seenVideoIds,
            seenBrowseIds: seenBrowseIds,
            seenArtistBrowseIds: seenArtistBrowseIds,
          ),
        );
        continuation = _homeContinuationToken(decoded);
      } on InnerTubeException {
        if (sections.isEmpty) {
          rethrow;
        }
        break;
      }
    }
    return List.unmodifiable(sections);
  }

  Object? _decodeHomeResponse(InnerTubeHttpResponse response) {
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw InnerTubeHttpException(response.statusCode, response.body);
    }
    try {
      return jsonDecode(response.body);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(
        'YouTube Music returned invalid JSON: ${error.message}',
      );
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
        if (container is! Map) {
          continue;
        }
        final token = _nonEmptyText(
          container['continuation'] ?? container['token'],
        );
        if (token != null) {
          return token;
        }
      }
      for (final value in node.values) {
        final token = _findContinuationToken(
          value,
          containerNames: containerNames,
        );
        if (token != null) {
          return token;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final token = _findContinuationToken(
          value,
          containerNames: containerNames,
        );
        if (token != null) {
          return token;
        }
      }
    }
    return null;
  }

  String? _nonEmptyText(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  @override
  Future<List<InnerTubeSong>> getCollectionSongs(
    String browseId, {
    int limit = maxDetailResults,
  }) async => (await getCollectionDetail(browseId, limit: limit)).songs;

  @override
  Future<InnerTubeCollectionDetail> getCollectionDetail(
    String browseId, {
    int limit = maxDetailResults,
  }) async {
    _ensureActive();
    final normalizedBrowseId = browseId.trim();
    if (!_collectionBrowseIdPattern.hasMatch(normalizedBrowseId)) {
      throw ArgumentError.value(
        browseId,
        'browseId',
        'Must be a YouTube Music playlist browse ID beginning with VL.',
      );
    }
    _validateDetailResultLimit(limit);
    final page = await _getDetailPage(
      browseId: normalizedBrowseId,
      limit: limit,
      isAlbum: false,
    );
    final header = _InnerTubeCollectionHeaderParser(
      _parser,
    ).parse(page.initialPayload);
    return InnerTubeCollectionDetail(
      browseId: normalizedBrowseId,
      title: header.title,
      subtitle: header.subtitle,
      thumbnailUrl: header.thumbnailUrl,
      songs: page.songs,
    );
  }

  @override
  Future<List<InnerTubeSong>> getAlbumSongs(
    String browseId, {
    int limit = maxDetailResults,
  }) async {
    _ensureActive();
    final normalizedBrowseId = browseId.trim();
    if (!_albumBrowseIdPattern.hasMatch(normalizedBrowseId)) {
      throw ArgumentError.value(
        browseId,
        'browseId',
        'Must be a YouTube Music album browse ID beginning with MPRE.',
      );
    }
    _validateDetailResultLimit(limit);
    final page = await _getDetailPage(
      browseId: normalizedBrowseId,
      limit: limit,
      isAlbum: true,
    );
    return page.songs;
  }

  Future<_InnerTubeDetailPage> _getDetailPage({
    required String browseId,
    required int limit,
    required bool isAlbum,
  }) async {
    var configuration = await _configuration();
    var response = await _requestBrowse(configuration, browseId: browseId);
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestBrowse(configuration, browseId: browseId);
    }

    var decoded = _decodeDetailResponse(response);
    final initialPayload = decoded;
    final songs = <InnerTubeSong>[];
    final seenVideoIds = <String>{};
    String? fallbackAlbumTitle;
    var fallbackAlbumArtists = const <String>[];
    var fallbackAlbumArtistBrowseIds = const <String?>[];

    void addPage(Object? payload) {
      final List<InnerTubeSong> pageSongs;
      if (isAlbum) {
        final page = _albumParser._parseSongPage(
          payload,
          limit: maxDetailResults,
          fallbackAlbumTitle: fallbackAlbumTitle,
          fallbackAlbumArtists: fallbackAlbumArtists,
          fallbackAlbumArtistBrowseIds: fallbackAlbumArtistBrowseIds,
        );
        fallbackAlbumTitle = page.albumTitle;
        fallbackAlbumArtists = page.albumArtists;
        fallbackAlbumArtistBrowseIds = page.albumArtistBrowseIds;
        pageSongs = page.songs;
      } else {
        pageSongs = _parser.parseDetailSongs(payload, limit: maxDetailResults);
      }
      for (final song in pageSongs) {
        if (seenVideoIds.add(song.videoId)) {
          songs.add(song);
          if (songs.length == limit) break;
        }
      }
    }

    addPage(decoded);
    final requestedContinuationTokens = <String>{};
    var continuationRequests = 0;
    var continuation = _homeContinuationToken(decoded);
    while (songs.length < limit &&
        continuation != null &&
        continuationRequests < maxDetailContinuationRequests &&
        requestedContinuationTokens.add(continuation)) {
      continuationRequests += 1;
      try {
        response = await _requestBrowse(
          configuration,
          continuation: continuation,
        );
        if (_needsFreshConfiguration(response.statusCode)) {
          configuration = await _freshConfiguration();
          response = await _requestBrowse(
            configuration,
            continuation: continuation,
          );
        }
        decoded = _decodeDetailResponse(response);
        addPage(decoded);
        continuation = _homeContinuationToken(decoded);
      } on InnerTubeException {
        if (songs.isEmpty) rethrow;
        break;
      }
    }
    return _InnerTubeDetailPage(
      initialPayload: initialPayload,
      songs: List.unmodifiable(songs),
    );
  }

  Object? _decodeDetailResponse(InnerTubeHttpResponse response) {
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw InnerTubeHttpException(response.statusCode, response.body);
    }
    try {
      return jsonDecode(response.body);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(
        'YouTube Music returned invalid JSON: ${error.message}',
      );
    }
  }

  @override
  Future<InnerTubeSong?> getSong(String videoId) async {
    _ensureActive();
    final normalizedVideoId = _validateVideoId(videoId);
    final decoded = await _getPlayerPayload(normalizedVideoId);
    return _playerParser.parse(decoded, expectedVideoId: normalizedVideoId);
  }

  Future<Object?> _getPlayerPayload(String normalizedVideoId) async {
    var configuration = await _configuration();
    var response = await _requestPlayer(normalizedVideoId, configuration);
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestPlayer(normalizedVideoId, configuration);
    }

    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw InnerTubeHttpException(response.statusCode, response.body);
    }

    try {
      return jsonDecode(response.body);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(
        'YouTube Music returned invalid JSON: ${error.message}',
      );
    }
  }

  Future<Duration?> _getSongDuration(String videoId) async {
    final normalizedVideoId = _validateVideoId(videoId);
    final decoded = await _getPlayerPayload(normalizedVideoId);
    return _playerParser.parseDuration(
      decoded,
      expectedVideoId: normalizedVideoId,
    );
  }

  @override
  Future<InnerTubeNextPage> getNext(
    String videoId, {
    bool radio = false,
    int limit = maxDetailResults,
  }) async {
    _ensureActive();
    final normalizedVideoId = _validateVideoId(videoId);
    _validateDetailResultLimit(limit);

    final requestedPlaylistId = radio ? 'RDAMVM$normalizedVideoId' : null;
    final page = await _loadNextPage(
      videoId: normalizedVideoId,
      playlistId: requestedPlaylistId,
      limit: limit,
    );
    if (!radio || page.songs.length > 1) {
      return page;
    }

    return _loadNextPage(videoId: normalizedVideoId, limit: limit);
  }

  @override
  Future<InnerTubeNextPage> getPlaylistNext(
    String playlistId, {
    String? videoId,
    int limit = maxDetailResults,
  }) {
    _ensureActive();
    final normalizedPlaylistId = playlistId.trim();
    if (!RegExp(r'^[A-Za-z0-9_-]{10,200}$').hasMatch(normalizedPlaylistId)) {
      throw ArgumentError.value(
        playlistId,
        'playlistId',
        'Must be a valid YouTube Music playlist id.',
      );
    }
    final normalizedVideoId = videoId == null
        ? null
        : _validateVideoId(videoId);
    _validateDetailResultLimit(limit);
    return _loadNextPage(
      videoId: normalizedVideoId,
      playlistId: normalizedPlaylistId,
      limit: limit,
    );
  }

  @override
  Future<InnerTubeNextPage> getNextContinuation(
    String continuation, {
    int limit = maxDetailResults,
  }) async {
    _ensureActive();
    final normalizedContinuation = _validateContinuation(continuation);
    _validateDetailResultLimit(limit);
    return _loadNextPage(continuation: normalizedContinuation, limit: limit);
  }

  Future<InnerTubeNextPage> _loadNextPage({
    String? videoId,
    String? playlistId,
    String? continuation,
    required int limit,
  }) async {
    var configuration = await _configuration();
    var response = await _requestNext(
      configuration,
      videoId: videoId,
      playlistId: playlistId,
      continuation: continuation,
    );
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestNext(
        configuration,
        videoId: videoId,
        playlistId: playlistId,
        continuation: continuation,
      );
    }
    return _nextParser.parse(_decodeDetailResponse(response), limit: limit);
  }

  @override
  Future<InnerTubeRelatedPage> getRelated(
    String browseId, {
    int limit = maxResults,
  }) async {
    _ensureActive();
    final normalizedBrowseId = _validateRelatedBrowseId(browseId);
    _validateResultLimit(limit);
    return _loadRelatedPage(browseId: normalizedBrowseId, limit: limit);
  }

  @override
  Future<InnerTubeRelatedPage> getRelatedContinuation(
    String continuation, {
    int limit = maxResults,
  }) async {
    _ensureActive();
    final normalizedContinuation = _validateContinuation(continuation);
    _validateResultLimit(limit);
    return _loadRelatedPage(continuation: normalizedContinuation, limit: limit);
  }

  Future<InnerTubeRelatedPage> _loadRelatedPage({
    String? browseId,
    String? continuation,
    required int limit,
  }) async {
    var configuration = await _configuration();
    var response = await _requestBrowse(
      configuration,
      browseId: browseId,
      continuation: continuation,
    );
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestBrowse(
        configuration,
        browseId: browseId,
        continuation: continuation,
      );
    }
    return _relatedParser.parse(_decodeDetailResponse(response), limit: limit);
  }

  @override
  Future<List<InnerTubeAlbum>> getArtistReleases(
    String artistBrowseId, {
    int limit = maxResults,
  }) async {
    _ensureActive();
    final normalizedBrowseId = artistBrowseId.trim();
    if (!_artistBrowseIdPattern.hasMatch(normalizedBrowseId)) {
      throw ArgumentError.value(
        artistBrowseId,
        'artistBrowseId',
        'Must be a valid YouTube Music artist browse ID.',
      );
    }
    _validateResultLimit(limit);

    var configuration = await _configuration();
    var response = await _requestBrowse(
      configuration,
      browseId: normalizedBrowseId,
    );
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestBrowse(
        configuration,
        browseId: normalizedBrowseId,
      );
    }
    return _albumParser.parse(_decodeDetailResponse(response), limit: limit);
  }

  @override
  Future<InnerTubeArtistProfile> getArtistProfile(
    String artistBrowseId, {
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = maxResults,
    int releaseLimit = maxResults,
  }) async {
    _ensureActive();
    final normalizedBrowseId = artistBrowseId.trim();
    if (!_artistBrowseIdPattern.hasMatch(normalizedBrowseId)) {
      throw ArgumentError.value(
        artistBrowseId,
        'artistBrowseId',
        'Must be a valid YouTube Music artist browse ID.',
      );
    }
    _validateResultLimit(songLimit);
    _validateResultLimit(releaseLimit);

    var configuration = await _configuration();
    var response = await _requestBrowse(
      configuration,
      browseId: normalizedBrowseId,
    );
    if (_needsFreshConfiguration(response.statusCode)) {
      configuration = await _freshConfiguration();
      response = await _requestBrowse(
        configuration,
        browseId: normalizedBrowseId,
      );
    }
    final profile = _artistParser.parse(
      _decodeDetailResponse(response),
      artistBrowseId: normalizedBrowseId,
      fallbackName: fallbackName,
      fallbackThumbnailUrl: fallbackThumbnailUrl,
      songLimit: songLimit,
      releaseLimit: releaseLimit,
    );
    return _enrichArtistSongDurations(profile);
  }

  /// Artist browse shelves commonly omit their duration column even though
  /// the player endpoint exposes an exact `lengthSeconds` for the same ID.
  /// Resolve only missing values, with a small worker pool, and retain every
  /// richer field parsed from the profile response.
  Future<InnerTubeArtistProfile> _enrichArtistSongDurations(
    InnerTubeArtistProfile profile,
  ) async {
    final songs = profile.popularSongs;
    final missingIndexes = <int>[
      for (var index = 0; index < songs.length; index++)
        if (songs[index].duration == null) index,
    ];
    if (missingIndexes.isEmpty) {
      return profile;
    }

    final enrichedSongs = List<InnerTubeSong>.of(songs);
    var cursor = 0;

    Future<void> resolveNext() async {
      while (cursor < missingIndexes.length) {
        final missingIndex = missingIndexes[cursor++];
        try {
          final duration = await _getSongDuration(songs[missingIndex].videoId);
          if (duration != null) {
            enrichedSongs[missingIndex] = _copySongWithDuration(
              songs[missingIndex],
              duration,
            );
          }
        } catch (_) {
          // Duration enrichment is optional. A transient player-endpoint
          // failure must not prevent the artist profile itself from opening.
        }
      }
    }

    final workerCount = math.min(
      _artistDurationLookupConcurrency,
      missingIndexes.length,
    );
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => resolveNext()),
    );

    return InnerTubeArtistProfile(
      artist: profile.artist,
      popularSongs: enrichedSongs,
      albums: profile.albums,
      singles: profile.singles,
      relatedArtists: profile.relatedArtists,
      description: profile.description,
      subscriberCount: profile.subscriberCount,
      monthlyListenerCount: profile.monthlyListenerCount,
      channelId: profile.channelId,
      playPlaylistId: profile.playPlaylistId,
      radioPlaylistId: profile.radioPlaylistId,
      radioSeedVideoId: profile.radioSeedVideoId,
      isSubscribed: profile.isSubscribed,
    );
  }

  InnerTubeSong _copySongWithDuration(InnerTubeSong song, Duration duration) {
    return InnerTubeSong(
      videoId: song.videoId,
      title: song.title,
      artists: song.artists,
      artistBrowseIds: song.artistBrowseIds,
      album: song.album,
      albumBrowseId: song.albumBrowseId,
      duration: duration,
      thumbnailUrl: song.thumbnailUrl,
    );
  }

  String _validateVideoId(String videoId) {
    final normalizedVideoId = videoId.trim();
    if (!_videoIdPattern.hasMatch(normalizedVideoId)) {
      throw ArgumentError.value(
        videoId,
        'videoId',
        'Must be an 11-character YouTube video ID.',
      );
    }
    return normalizedVideoId;
  }

  String _validateContinuation(String continuation) {
    final normalized = continuation.trim();
    if (normalized.isEmpty || normalized.length > 4096) {
      throw ArgumentError.value(
        continuation,
        'continuation',
        'Must be a non-empty YouTube continuation token.',
      );
    }
    return normalized;
  }

  String _validateRelatedBrowseId(String browseId) {
    final normalized = browseId.trim();
    if (!_relatedBrowseIdPattern.hasMatch(normalized)) {
      throw ArgumentError.value(
        browseId,
        'browseId',
        'Must be a valid YouTube Music related browse ID.',
      );
    }
    return normalized;
  }

  Future<InnerTubeHttpResponse> _requestSearch(
    String query,
    String filter,
    InnerTubeConfiguration configuration,
  ) async {
    final uri = _endpoint.replace(
      queryParameters: <String, String>{
        ..._endpoint.queryParameters,
        'key': configuration.apiKey,
        'prettyPrint': 'false',
      },
    );
    final body = <String, Object>{
      'context': <String, Object>{
        'client': <String, Object>{
          'clientName': configuration.clientName,
          'clientVersion': configuration.clientVersion,
          'hl': _language,
          'gl': _region,
          'visitorData': configuration.visitorData,
        },
      },
      'query': query,
      'params': filter,
    };

    return _sendWithRetry(
      () => _transport.postJson(
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=UTF-8',
          'Origin': 'https://music.youtube.com',
          HttpHeaders.refererHeader: 'https://music.youtube.com/',
          HttpHeaders.userAgentHeader: _userAgent,
          'X-YouTube-Client-Name': configuration.contextClientName,
          'X-YouTube-Client-Version': configuration.clientVersion,
          'X-Goog-Visitor-Id': configuration.visitorData,
        },
        body: body,
        timeout: _requestTimeout,
      ),
    );
  }

  Future<InnerTubeHttpResponse> _requestPlayer(
    String videoId,
    InnerTubeConfiguration configuration,
  ) async {
    final uri = _playerEndpoint.replace(
      queryParameters: <String, String>{
        ..._playerEndpoint.queryParameters,
        'key': configuration.apiKey,
        'prettyPrint': 'false',
      },
    );
    final body = <String, Object>{
      'context': <String, Object>{
        'client': <String, Object>{
          'clientName': configuration.clientName,
          'clientVersion': configuration.clientVersion,
          'hl': _language,
          'gl': _region,
          'visitorData': configuration.visitorData,
        },
      },
      'videoId': videoId,
    };

    return _sendWithRetry(
      () => _transport.postJson(
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=UTF-8',
          'Origin': 'https://music.youtube.com',
          HttpHeaders.refererHeader: 'https://music.youtube.com/',
          HttpHeaders.userAgentHeader: _userAgent,
          'X-YouTube-Client-Name': configuration.contextClientName,
          'X-YouTube-Client-Version': configuration.clientVersion,
          'X-Goog-Visitor-Id': configuration.visitorData,
        },
        body: body,
        timeout: _requestTimeout,
      ),
    );
  }

  Future<InnerTubeHttpResponse> _requestNext(
    InnerTubeConfiguration configuration, {
    String? videoId,
    String? playlistId,
    String? continuation,
  }) async {
    final hasInitialEndpoint = videoId != null || playlistId != null;
    if (hasInitialEndpoint == (continuation != null)) {
      throw ArgumentError(
        'Provide either an initial video/playlist endpoint or a continuation.',
      );
    }
    final uri = _nextEndpoint.replace(
      queryParameters: <String, String>{
        ..._nextEndpoint.queryParameters,
        'key': configuration.apiKey,
        'prettyPrint': 'false',
      },
    );
    final body = <String, Object>{
      'context': <String, Object>{
        'client': <String, Object>{
          'clientName': configuration.clientName,
          'clientVersion': configuration.clientVersion,
          'hl': _language,
          'gl': _region,
          'visitorData': configuration.visitorData,
        },
      },
      'videoId': ?videoId,
      'playlistId': ?playlistId,
      'continuation': ?continuation,
      if (hasInitialEndpoint) 'isAudioOnly': true,
      if (videoId != null) 'params': 'wAEB',
    };

    return _sendWithRetry(
      () => _transport.postJson(
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=UTF-8',
          'Origin': 'https://music.youtube.com',
          HttpHeaders.refererHeader: 'https://music.youtube.com/',
          HttpHeaders.userAgentHeader: _userAgent,
          'X-YouTube-Client-Name': configuration.contextClientName,
          'X-YouTube-Client-Version': configuration.clientVersion,
          'X-Goog-Visitor-Id': configuration.visitorData,
        },
        body: body,
        timeout: _requestTimeout,
      ),
    );
  }

  Future<InnerTubeHttpResponse> _requestBrowse(
    InnerTubeConfiguration configuration, {
    String? browseId,
    String? continuation,
  }) async {
    if ((browseId == null) == (continuation == null)) {
      throw ArgumentError(
        'Exactly one of browseId or continuation must be provided.',
      );
    }
    final uri = _browseEndpoint.replace(
      queryParameters: <String, String>{
        ..._browseEndpoint.queryParameters,
        'key': configuration.apiKey,
        'prettyPrint': 'false',
      },
    );
    final body = <String, Object>{
      'context': <String, Object>{
        'client': <String, Object>{
          'clientName': configuration.clientName,
          'clientVersion': configuration.clientVersion,
          'hl': _language,
          'gl': _region,
          'visitorData': configuration.visitorData,
        },
      },
      'browseId': ?browseId,
      'continuation': ?continuation,
    };

    return _sendWithRetry(
      () => _transport.postJson(
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.contentTypeHeader: 'application/json; charset=UTF-8',
          'Origin': 'https://music.youtube.com',
          HttpHeaders.refererHeader: 'https://music.youtube.com/',
          HttpHeaders.userAgentHeader: _userAgent,
          'X-YouTube-Client-Name': configuration.contextClientName,
          'X-YouTube-Client-Version': configuration.clientVersion,
          'X-Goog-Visitor-Id': configuration.visitorData,
        },
        body: body,
        timeout: _requestTimeout,
      ),
    );
  }

  bool _needsFreshConfiguration(int statusCode) {
    return statusCode == HttpStatus.badRequest ||
        statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden;
  }

  Future<InnerTubeHttpResponse> _sendWithRetry(
    Future<InnerTubeHttpResponse> Function() send,
  ) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 1; attempt <= _retryPolicy.maxAttempts; attempt++) {
      _ensureActive();
      InnerTubeHttpResponse? response;
      try {
        response = await send();
      } on Object catch (error, stackTrace) {
        if (!_isRetryableTransportError(error)) {
          Error.throwWithStackTrace(_translateRequestError(error), stackTrace);
        }
        lastError = error;
        lastStackTrace = stackTrace;
      }

      if (response != null &&
          (!_retryPolicy.shouldRetryStatus(response.statusCode) ||
              attempt == _retryPolicy.maxAttempts)) {
        return response;
      }

      if (attempt == _retryPolicy.maxAttempts) {
        final error = lastError;
        if (error != null) {
          Error.throwWithStackTrace(
            _translateRequestError(error),
            lastStackTrace ?? StackTrace.current,
          );
        }
        return response!;
      }

      final delay = _retryPolicy.delayBeforeRetry(
        retryNumber: attempt,
        response: response,
        now: _retryClock(),
      );
      if (delay > Duration.zero) {
        await _retryDelay(delay);
      }
      _ensureActive();
    }
    throw StateError('InnerTube retry loop ended without a result.');
  }

  bool _isRetryableTransportError(Object error) {
    return error is TimeoutException ||
        error is SocketException ||
        error is HttpException ||
        error is InnerTubeTimeoutException ||
        error is InnerTubeTransportException;
  }

  Object _translateRequestError(Object error) {
    if (error is InnerTubeException) {
      return error;
    }
    if (error is TimeoutException) {
      return const InnerTubeTimeoutException();
    }
    if (error is SocketException || error is HttpException) {
      return InnerTubeTransportException(error);
    }
    if (error is FormatException) {
      return InnerTubeFormatException(error.message);
    }
    return error;
  }

  Future<InnerTubeConfiguration> _configuration() {
    return _configurationFuture ??= _guardConfigurationLoad(
      _loadConfiguration(preferPersistedVisitorData: true),
    );
  }

  Future<InnerTubeConfiguration> _freshConfiguration() {
    final existing = _freshConfigurationFuture;
    if (existing != null) {
      return existing;
    }
    final load = _guardConfigurationLoad(
      _loadConfiguration(preferPersistedVisitorData: false),
    );
    _configurationFuture = load;
    _freshConfigurationFuture = load;
    load.then<void>(
      (_) {
        if (identical(_freshConfigurationFuture, load)) {
          _freshConfigurationFuture = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_freshConfigurationFuture, load)) {
          _freshConfigurationFuture = null;
        }
      },
    );
    return load;
  }

  Future<InnerTubeConfiguration> _guardConfigurationLoad(
    Future<InnerTubeConfiguration> load,
  ) {
    late final Future<InnerTubeConfiguration> guarded;
    guarded = load.catchError((Object error) {
      if (identical(_configurationFuture, guarded)) {
        _configurationFuture = null;
      }
      throw error;
    });
    return guarded;
  }

  Future<InnerTubeConfiguration> _loadConfiguration({
    required bool preferPersistedVisitorData,
  }) async {
    final uri = _bootstrapUri.replace(
      queryParameters: <String, String>{
        ..._bootstrapUri.queryParameters,
        'hl': _language,
        'gl': _region,
      },
    );
    final response = await _sendWithRetry(
      () => _transport.get(
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'text/html,application/xhtml+xml',
          HttpHeaders.userAgentHeader: _userAgent,
        },
        timeout: _requestTimeout,
      ),
    );
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw InnerTubeHttpException(response.statusCode, response.body);
    }
    final bootstrapConfiguration = _bootstrapParser.parse(response.body);
    final store = _visitorDataStore;
    if (store == null) {
      return bootstrapConfiguration;
    }

    String? persistedVisitorData;
    if (preferPersistedVisitorData) {
      try {
        final stored = (await store.read())?.trim();
        if (stored != null && stored.isNotEmpty && stored.length <= 4096) {
          persistedVisitorData = stored;
        }
      } on Object {
        // Persistence is an optional optimization. A storage failure must not
        // make catalog requests unusable.
      }
    }

    final visitorData =
        persistedVisitorData ?? bootstrapConfiguration.visitorData;
    if (persistedVisitorData == null) {
      try {
        await store.write(visitorData);
      } on Object {
        // Continue with the fresh bootstrap identity when persistence fails.
      }
    }
    return InnerTubeConfiguration(
      apiKey: bootstrapConfiguration.apiKey,
      clientVersion: bootstrapConfiguration.clientVersion,
      visitorData: visitorData,
      clientName: bootstrapConfiguration.clientName,
      contextClientName: bootstrapConfiguration.contextClientName,
    );
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _transport.close();
  }

  void _ensureActive() {
    if (_disposed) {
      throw StateError('The InnerTube search service is disposed.');
    }
  }

  void _validateResultLimit(int limit) {
    if (limit < 1 || limit > maxResults) {
      throw RangeError.range(limit, 1, maxResults, 'limit');
    }
  }

  void _validateDetailResultLimit(int limit) {
    if (limit < 1 || limit > maxDetailResults) {
      throw RangeError.range(limit, 1, maxDetailResults, 'limit');
    }
  }

  static final RegExp _videoIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
  static final RegExp _albumBrowseIdPattern = RegExp(
    r'^MPRE[A-Za-z0-9_-]{1,200}$',
  );
  static final RegExp _collectionBrowseIdPattern = RegExp(
    r'^VL[A-Za-z0-9_-]{1,200}$',
  );
  static final RegExp _relatedBrowseIdPattern = RegExp(
    r'^[A-Za-z0-9_-]{2,200}$',
  );
  static final RegExp _artistBrowseIdPattern = RegExp(
    r'^(?:UC|MPLA)[A-Za-z0-9_-]{2,200}$',
  );
}

class InnerTubeConfiguration {
  const InnerTubeConfiguration({
    required this.apiKey,
    required this.clientVersion,
    required this.visitorData,
    this.clientName = 'WEB_REMIX',
    this.contextClientName = '67',
  });

  final String apiKey;
  final String clientVersion;
  final String visitorData;
  final String clientName;
  final String contextClientName;
}

class InnerTubeBootstrapParser {
  const InnerTubeBootstrapParser();

  InnerTubeConfiguration parse(String html) {
    final apiKey = _extract(html, 'INNERTUBE_API_KEY');
    final clientVersion = _extract(html, 'INNERTUBE_CLIENT_VERSION');
    final visitorData = _extract(html, 'VISITOR_DATA');
    if (apiKey == null || clientVersion == null || visitorData == null) {
      throw const InnerTubeFormatException(
        'YouTube Music bootstrap configuration is incomplete.',
      );
    }
    return InnerTubeConfiguration(
      apiKey: apiKey,
      clientVersion: clientVersion,
      visitorData: visitorData,
      clientName: _extract(html, 'INNERTUBE_CLIENT_NAME') ?? 'WEB_REMIX',
      contextClientName:
          _extractNumber(html, 'INNERTUBE_CONTEXT_CLIENT_NAME') ?? '67',
    );
  }

  String? _extract(String html, String key) {
    final expression = RegExp(
      '"${RegExp.escape(key)}"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"',
    );
    final match = expression.firstMatch(html);
    if (match == null) {
      return null;
    }
    try {
      final value = jsonDecode('"${match.group(1)}"');
      return value is String && value.trim().isNotEmpty ? value : null;
    } on FormatException {
      return null;
    }
  }

  String? _extractNumber(String html, String key) {
    final expression = RegExp('"${RegExp.escape(key)}"\\s*:\\s*(\\d+)');
    return expression.firstMatch(html)?.group(1);
  }
}

class InnerTubeSearchParser {
  const InnerTubeSearchParser();

  static final RegExp _durationPattern = RegExp(r'^\d+:\d{2}(?::\d{2})?$');

  List<InnerTubeSong> parse(Object? payload, {int limit = 20}) {
    _validateLimit(limit, maximum: InnerTubeSearchService.maxResults);
    return _parse(payload, limit: limit);
  }

  List<InnerTubeSong> parseDetailSongs(
    Object? payload, {
    int limit = innerTubeDetailResultLimit,
  }) {
    _validateLimit(limit, maximum: InnerTubeSearchService.maxDetailResults);
    return _parse(payload, limit: limit);
  }

  List<InnerTubeSong> _parse(Object? payload, {required int limit}) {
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music response must be a JSON object.',
      );
    }

    final results = <InnerTubeSong>[];
    final seenVideoIds = <String>{};
    for (final candidate in _songItemRenderers(payload)) {
      final song = candidate.isTwoRow
          ? _parseTwoRowSong(candidate.renderer)
          : _parseSong(candidate.renderer);
      if (song == null || !seenVideoIds.add(song.videoId)) {
        continue;
      }
      results.add(song);
      if (results.length == limit) {
        break;
      }
    }
    return List.unmodifiable(results);
  }

  void _validateLimit(int limit, {required int maximum}) {
    if (limit < 1 || limit > maximum) {
      throw RangeError.range(limit, 1, maximum, 'limit');
    }
  }

  InnerTubeSong? _parseSong(Map<dynamic, dynamic> renderer) {
    final columns = _maps(renderer['flexColumns']).toList(growable: false);
    final titleRuns = columns.isEmpty
        ? const <Map<dynamic, dynamic>>[]
        : _columnRuns(columns.first).toList(growable: false);
    final title = _firstText(titleRuns);
    final videoId =
        _text(
          renderer['playlistItemData'] is Map
              ? (renderer['playlistItemData'] as Map)['videoId']
              : null,
        ) ??
        _watchVideoId(titleRuns) ??
        _findWatchVideoId(renderer['overlay']);
    if (videoId == null || title == null) {
      return null;
    }

    final metadataRuns = <Map<dynamic, dynamic>>[];
    for (final column in columns.skip(1)) {
      metadataRuns.addAll(_columnRuns(column));
    }
    for (final column in _maps(renderer['fixedColumns'])) {
      metadataRuns.addAll(_columnRuns(column));
    }

    final artists = <String>[];
    final artistBrowseIds = <String?>[];
    String? album;
    String? albumBrowseId;
    Duration? duration;
    for (final run in metadataRuns) {
      final text = _text(run['text']);
      if (text == null) {
        continue;
      }
      final pageType = _browsePageType(run);
      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
        final artistText = _artistText(run['text']);
        if (artistText != null) {
          final existingIndex = artists.indexOf(artistText);
          final browseId = _browseId(run);
          if (existingIndex < 0) {
            artists.add(artistText);
            artistBrowseIds.add(browseId);
          } else if (artistBrowseIds[existingIndex] == null) {
            artistBrowseIds[existingIndex] = browseId;
          }
        }
      } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' && album == null) {
        album = text;
        albumBrowseId = _validatedAlbumBrowseId(run);
      }
      duration ??= _parseDuration(text);
    }

    if (artists.isEmpty && columns.length > 1) {
      for (final run in _columnRuns(columns[1])) {
        final text = _artistText(run['text']);
        if (text == null ||
            _isSeparator(text) ||
            _parseDuration(text) != null) {
          continue;
        }
        if (_browsePageType(run) == 'MUSIC_PAGE_TYPE_ALBUM') {
          break;
        }
        artists.add(text);
        artistBrowseIds.add(null);
        break;
      }
    }

    return InnerTubeSong(
      videoId: videoId,
      title: title,
      artists: artists,
      artistBrowseIds: artistBrowseIds,
      album: album,
      albumBrowseId: albumBrowseId,
      duration: duration,
      thumbnailUrl: _thumbnailUrl(renderer),
    );
  }

  InnerTubeSong? _parseTwoRowSong(Map<dynamic, dynamic> renderer) {
    final titleRuns = _runs(renderer['title']).toList(growable: false);
    final title = _firstText(titleRuns);
    final videoId =
        _watchVideoId(titleRuns) ??
        _findWatchVideoId(renderer['navigationEndpoint']) ??
        _findWatchVideoId(renderer['overlay']);
    if (videoId == null || title == null) {
      return null;
    }

    final metadataRuns = _runs(renderer['subtitle']).toList(growable: false);
    final artists = <String>[];
    final artistBrowseIds = <String?>[];
    String? album;
    String? albumBrowseId;
    Duration? duration;
    for (final run in metadataRuns) {
      final text = _text(run['text']);
      if (text == null) {
        continue;
      }
      final pageType = _browsePageType(run);
      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
        final artistText = _artistText(run['text']);
        if (artistText != null) {
          final existingIndex = artists.indexOf(artistText);
          final browseId = _browseId(run);
          if (existingIndex < 0) {
            artists.add(artistText);
            artistBrowseIds.add(browseId);
          } else if (artistBrowseIds[existingIndex] == null) {
            artistBrowseIds[existingIndex] = browseId;
          }
        }
      } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' && album == null) {
        album = text;
        albumBrowseId = _validatedAlbumBrowseId(run);
      }
      duration ??= _parseDuration(text);
    }

    if (artists.isEmpty) {
      for (final run in metadataRuns) {
        final text = _artistText(run['text']);
        if (text == null ||
            _isSeparator(text) ||
            _parseDuration(text) != null ||
            _browsePageType(run) == 'MUSIC_PAGE_TYPE_ALBUM') {
          continue;
        }
        artists.add(text);
        artistBrowseIds.add(null);
        break;
      }
    }

    return InnerTubeSong(
      videoId: videoId,
      title: title,
      artists: artists,
      artistBrowseIds: artistBrowseIds,
      album: album,
      albumBrowseId: albumBrowseId,
      duration: duration,
      thumbnailUrl: _thumbnailUrl(renderer),
    );
  }

  Iterable<_InnerTubeSongRenderer> _songItemRenderers(Object? node) sync* {
    if (node is Map) {
      final responsive = node['musicResponsiveListItemRenderer'];
      if (responsive is Map) {
        yield _InnerTubeSongRenderer(responsive, isTwoRow: false);
      }
      final twoRow = node['musicTwoRowItemRenderer'];
      if (twoRow is Map) {
        yield _InnerTubeSongRenderer(twoRow, isTwoRow: true);
      }
      for (final value in node.values) {
        yield* _songItemRenderers(value);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _songItemRenderers(value);
      }
    }
  }

  Iterable<Map<dynamic, dynamic>> _runs(Object? textRenderer) sync* {
    if (textRenderer is! Map) {
      return;
    }
    yield* _maps(textRenderer['runs']);
  }

  Iterable<Map<dynamic, dynamic>> _columnRuns(
    Map<dynamic, dynamic> column,
  ) sync* {
    final flex = column['musicResponsiveListItemFlexColumnRenderer'];
    final fixed = column['musicResponsiveListItemFixedColumnRenderer'];
    final renderer = flex is Map ? flex : (fixed is Map ? fixed : null);
    if (renderer is! Map) {
      return;
    }
    final text = renderer['text'];
    if (text is! Map) {
      return;
    }
    yield* _maps(text['runs']);
  }

  String? _firstText(Iterable<Map<dynamic, dynamic>> runs) {
    for (final run in runs) {
      final text = _text(run['text']);
      if (text != null) {
        return text;
      }
    }
    return null;
  }

  String? _watchVideoId(Iterable<Map<dynamic, dynamic>> runs) {
    for (final run in runs) {
      final endpoint = run['navigationEndpoint'];
      if (endpoint is! Map) {
        continue;
      }
      final watch = endpoint['watchEndpoint'];
      if (watch is Map) {
        final videoId = _text(watch['videoId']);
        if (videoId != null) {
          return videoId;
        }
      }
    }
    return null;
  }

  String? _findWatchVideoId(Object? node) {
    if (node is Map) {
      final watch = node['watchEndpoint'];
      if (watch is Map) {
        final videoId = _text(watch['videoId']);
        if (videoId != null) {
          return videoId;
        }
      }
      for (final value in node.values) {
        final videoId = _findWatchVideoId(value);
        if (videoId != null) {
          return videoId;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final videoId = _findWatchVideoId(value);
        if (videoId != null) {
          return videoId;
        }
      }
    }
    return null;
  }

  String? _browsePageType(Map<dynamic, dynamic> run) {
    final navigation = run['navigationEndpoint'];
    if (navigation is! Map) {
      return null;
    }
    final browse = navigation['browseEndpoint'];
    if (browse is! Map) {
      return null;
    }
    final configs = browse['browseEndpointContextSupportedConfigs'];
    if (configs is! Map) {
      return null;
    }
    final musicConfig = configs['browseEndpointContextMusicConfig'];
    if (musicConfig is! Map) {
      return null;
    }
    return _text(musicConfig['pageType']);
  }

  String? _browseId(Map<dynamic, dynamic> run) {
    final navigation = run['navigationEndpoint'];
    if (navigation is! Map) {
      return null;
    }
    final browse = navigation['browseEndpoint'];
    if (browse is! Map) {
      return null;
    }
    final browseId = _text(browse['browseId']);
    if (browseId == null || browseId.length > 256) {
      return null;
    }
    return browseId;
  }

  String? _validatedAlbumBrowseId(Map<dynamic, dynamic> run) {
    final browseId = _browseId(run);
    return browseId != null &&
            InnerTubeSearchService._albumBrowseIdPattern.hasMatch(browseId)
        ? browseId
        : null;
  }

  String? _thumbnailUrl(Map<dynamic, dynamic> renderer) {
    final thumbnail = renderer['thumbnail'] ?? renderer['thumbnailRenderer'];
    if (thumbnail is! Map) {
      return null;
    }
    final musicThumbnail = thumbnail['musicThumbnailRenderer'];
    final thumbnailData = musicThumbnail is Map
        ? musicThumbnail['thumbnail']
        : thumbnail;
    if (thumbnailData is! Map) {
      return null;
    }

    String? selectedUrl;
    var selectedArea = -1;
    for (final candidate in _maps(thumbnailData['thumbnails'])) {
      var url = _text(candidate['url']);
      if (url == null) {
        continue;
      }
      if (url.startsWith('//')) {
        url = 'https:$url';
      }
      final width = _integer(candidate['width']) ?? 0;
      final height = _integer(candidate['height']) ?? 0;
      final area = width * height;
      if (area >= selectedArea) {
        selectedArea = area;
        selectedUrl = url;
      }
    }
    return selectedUrl;
  }

  Duration? _parseDuration(String value) {
    final normalized = value.trim();
    if (!_durationPattern.hasMatch(normalized)) {
      return null;
    }
    final parts = normalized.split(':').map(int.parse).toList();
    if (parts.skip(1).any((part) => part >= 60)) {
      return null;
    }
    var seconds = 0;
    for (final part in parts) {
      seconds = (seconds * 60) + part;
    }
    return seconds <= 0 ? null : Duration(seconds: seconds);
  }

  bool _isSeparator(String value) {
    final normalized = value.trim();
    return normalized.isEmpty ||
        normalized == '\u2022' ||
        normalized == '\u00b7' ||
        normalized == '\u00e2\u20ac\u00a2';
  }

  Iterable<Map<dynamic, dynamic>> _maps(Object? value) sync* {
    if (value is! List) {
      return;
    }
    for (final item in value) {
      if (item is Map) {
        yield item;
      }
    }
  }

  String? _text(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is String || value is num || value is bool) {
      final normalized = value.toString().trim();
      return normalized.isEmpty ? null : normalized;
    }
    if (value is Map) {
      final simpleText = _text(value['simpleText']);
      if (simpleText != null) {
        return simpleText;
      }

      final nestedText = _text(value['text']);
      if (nestedText != null) {
        return nestedText;
      }

      final runs = value['runs'];
      if (runs is List) {
        final parts = <String>[];
        for (final run in runs) {
          if (run is Map) {
            final text = _text(run['text']);
            if (text != null) {
              parts.add(text);
            }
          }
        }
        final joined = parts.join();
        if (joined.trim().isNotEmpty) {
          return joined.trim();
        }
      }

      final accessibilityLabel = _text(
        (value['accessibilityData'] as Map?)?['label'],
      );
      if (accessibilityLabel != null) {
        return accessibilityLabel;
      }
    }
    return null;
  }

  String? _artistText(Object? value) {
    final text = _text(value);
    if (text == null) {
      return null;
    }
    final normalized = text.trim().toLowerCase();
    if (normalized == 'ir al artista' || normalized == 'go to artist') {
      return null;
    }
    if (normalized.contains('{runs:') ||
        normalized.contains('simpletext:') ||
        normalized.contains('navigationendpoint:')) {
      return null;
    }
    return text.trim();
  }

  int? _integer(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}

final class _InnerTubeDetailPage {
  const _InnerTubeDetailPage({
    required this.initialPayload,
    required this.songs,
  });

  final Object? initialPayload;
  final List<InnerTubeSong> songs;
}

final class _InnerTubeCollectionHeader {
  const _InnerTubeCollectionHeader({
    this.title,
    this.subtitle,
    this.thumbnailUrl,
  });

  final String? title;
  final String? subtitle;
  final String? thumbnailUrl;
}

/// Reads only the playlist header from a browse response.
///
/// Limiting the traversal to a recognized header renderer prevents a song or
/// recommendation nested later in the payload from becoming the collection's
/// title or artwork.
final class _InnerTubeCollectionHeaderParser {
  const _InnerTubeCollectionHeaderParser(this._songParser);

  final InnerTubeSearchParser _songParser;

  _InnerTubeCollectionHeader parse(Object? payload) {
    final header = _findHeader(payload);
    if (header == null) {
      return const _InnerTubeCollectionHeader();
    }
    final title = _firstText(header, const <String>['title', 'headline']);
    return _InnerTubeCollectionHeader(
      title: title,
      subtitle: _ownerOrSubtitle(header, title: title),
      thumbnailUrl: _largestThumbnailUrl(header),
    );
  }

  Map<dynamic, dynamic>? _findHeader(Object? node) {
    if (node is Map) {
      for (final rendererName in const <String>[
        'musicDetailHeaderRenderer',
        'musicEditablePlaylistDetailHeaderRenderer',
        'musicResponsiveHeaderRenderer',
        'musicImmersiveHeaderRenderer',
      ]) {
        final renderer = node[rendererName];
        if (renderer is Map) {
          return renderer;
        }
      }
      for (final value in node.values) {
        final header = _findHeader(value);
        if (header != null) {
          return header;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final header = _findHeader(value);
        if (header != null) {
          return header;
        }
      }
    }
    return null;
  }

  String? _firstText(Map<dynamic, dynamic> renderer, List<String> keys) {
    for (final key in keys) {
      final text = _songParser._text(renderer[key]);
      if (text != null) {
        return text;
      }
    }
    return null;
  }

  String? _ownerOrSubtitle(
    Map<dynamic, dynamic> header, {
    required String? title,
  }) {
    final directOwner = _firstText(header, const <String>[
      'owner',
      'straplineTextOne',
    ]);
    if (_isUsefulSubtitle(directOwner, title: title)) {
      return directOwner;
    }

    for (final key in const <String>[
      'subtitle',
      'straplineTextOne',
      'secondSubtitle',
    ]) {
      final owner = _linkedOwner(header[key]);
      if (_isUsefulSubtitle(owner, title: title)) {
        return owner;
      }
    }

    for (final key in const <String>[
      'subtitle',
      'secondSubtitle',
      'straplineTextOne',
    ]) {
      final subtitle = _songParser._text(header[key]);
      if (_isUsefulSubtitle(subtitle, title: title)) {
        return subtitle;
      }
    }
    return null;
  }

  String? _linkedOwner(Object? textRenderer) {
    if (textRenderer is! Map || textRenderer['runs'] is! List) {
      return null;
    }
    for (final run in textRenderer['runs'] as List) {
      if (run is! Map) {
        continue;
      }
      final navigation = run['navigationEndpoint'];
      final browse = navigation is Map ? navigation['browseEndpoint'] : null;
      final browseId = browse is Map
          ? _songParser._text(browse['browseId'])
          : null;
      if (browseId == null || !browseId.startsWith('UC')) {
        continue;
      }
      final owner = _songParser._text(run['text']);
      if (owner != null) {
        return owner;
      }
    }
    return null;
  }

  bool _isUsefulSubtitle(String? value, {required String? title}) {
    final normalized = value?.trim();
    return normalized != null &&
        normalized.isNotEmpty &&
        normalized != '\u2022' &&
        normalized != '\u00b7' &&
        normalized.toLowerCase() != title?.trim().toLowerCase();
  }

  String? _largestThumbnailUrl(Object? node) {
    String? selectedUrl;
    var selectedArea = -1;

    void visit(Object? value) {
      if (value is Map) {
        final thumbnails = value['thumbnails'];
        if (thumbnails is List) {
          for (final rawThumbnail in thumbnails) {
            if (rawThumbnail is! Map) {
              continue;
            }
            var url = _songParser._text(rawThumbnail['url']);
            if (url == null) {
              continue;
            }
            if (url.startsWith('//')) {
              url = 'https:$url';
            }
            final width = _songParser._integer(rawThumbnail['width']) ?? 0;
            final height = _songParser._integer(rawThumbnail['height']) ?? 0;
            final area = width * height;
            if (selectedUrl == null || area >= selectedArea) {
              selectedUrl = url;
              selectedArea = area;
            }
          }
        }
        for (final child in value.values) {
          visit(child);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child);
        }
      }
    }

    visit(node);
    return selectedUrl;
  }
}

/// Parses artist-only search responses without treating song credits as
/// standalone artist results.
class InnerTubeArtistSearchParser {
  const InnerTubeArtistSearchParser({
    this._searchParser = const InnerTubeSearchParser(),
  });

  final InnerTubeSearchParser _searchParser;

  List<InnerTubeArtist> parse(Object? payload, {int limit = 20}) {
    if (limit < 1 || limit > InnerTubeSearchService.maxResults) {
      throw RangeError.range(
        limit,
        1,
        InnerTubeSearchService.maxResults,
        'limit',
      );
    }
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music artist search response must be a JSON object.',
      );
    }

    final artists = <InnerTubeArtist>[];
    final seenBrowseIds = <String>{};
    for (final candidate in _artistItemRenderers(payload)) {
      final artist = candidate.isTwoRow
          ? _parseTwoRowArtist(candidate.renderer)
          : _parseResponsiveArtist(candidate.renderer);
      if (artist == null || !seenBrowseIds.add(artist.browseId)) {
        continue;
      }
      artists.add(artist);
      if (artists.length == limit) break;
    }
    return List<InnerTubeArtist>.unmodifiable(artists);
  }

  InnerTubeArtist? _parseResponsiveArtist(Map<dynamic, dynamic> renderer) {
    final columns = _searchParser
        ._maps(renderer['flexColumns'])
        .toList(growable: false);
    final titleRuns = columns.isEmpty
        ? const <Map<dynamic, dynamic>>[]
        : _searchParser._columnRuns(columns.first).toList(growable: false);
    return _parseArtist(renderer, titleRuns);
  }

  InnerTubeArtist? _parseTwoRowArtist(Map<dynamic, dynamic> renderer) {
    return _parseArtist(
      renderer,
      _searchParser._runs(renderer['title']).toList(growable: false),
    );
  }

  InnerTubeArtist? _parseArtist(
    Map<dynamic, dynamic> renderer,
    List<Map<dynamic, dynamic>> titleRuns,
  ) {
    final name = _searchParser._artistText(_searchParser._firstText(titleRuns));
    if (name == null) return null;

    final browseId =
        _directArtistBrowseId(renderer['navigationEndpoint']) ??
        _artistBrowseIdFromRuns(titleRuns);
    if (browseId == null) return null;

    return InnerTubeArtist(
      browseId: browseId,
      name: name,
      thumbnailUrl: _searchParser._thumbnailUrl(renderer),
    );
  }

  String? _artistBrowseIdFromRuns(Iterable<Map<dynamic, dynamic>> runs) {
    for (final run in runs) {
      final browseId = _directArtistBrowseId(run['navigationEndpoint']);
      if (browseId != null) return browseId;
    }
    return null;
  }

  String? _directArtistBrowseId(Object? endpoint) {
    if (endpoint is! Map) return null;
    final browse = endpoint['browseEndpoint'];
    if (browse is! Map) return null;
    final browseId = _searchParser._text(browse['browseId']);
    if (browseId == null ||
        !InnerTubeSearchService._artistBrowseIdPattern.hasMatch(browseId)) {
      return null;
    }

    final configs = browse['browseEndpointContextSupportedConfigs'];
    final musicConfig = configs is Map
        ? configs['browseEndpointContextMusicConfig']
        : null;
    final pageType = musicConfig is Map
        ? _searchParser._text(musicConfig['pageType'])
        : null;
    if (pageType != null && pageType != 'MUSIC_PAGE_TYPE_ARTIST') {
      return null;
    }
    return browseId;
  }

  Iterable<_InnerTubeSongRenderer> _artistItemRenderers(Object? node) sync* {
    if (node is Map) {
      final responsive = node['musicResponsiveListItemRenderer'];
      if (responsive is Map) {
        yield _InnerTubeSongRenderer(responsive, isTwoRow: false);
      }
      final twoRow = node['musicTwoRowItemRenderer'];
      if (twoRow is Map) {
        yield _InnerTubeSongRenderer(twoRow, isTwoRow: true);
      }
      for (final value in node.values) {
        yield* _artistItemRenderers(value);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _artistItemRenderers(value);
      }
    }
  }
}

class InnerTubeAlbumParser {
  const InnerTubeAlbumParser({
    this._songParser = const InnerTubeSearchParser(),
  });

  final InnerTubeSearchParser _songParser;

  List<InnerTubeAlbum> parse(Object? payload, {int limit = 20}) {
    _validateSearchLimit(limit);
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music album search response must be a JSON object.',
      );
    }

    final albums = <InnerTubeAlbum>[];
    final seenBrowseIds = <String>{};
    for (final candidate in _albumItemRenderers(payload)) {
      final album = candidate.isTwoRow
          ? _parseTwoRowAlbum(candidate.renderer)
          : _parseResponsiveAlbum(candidate.renderer);
      if (album == null || !seenBrowseIds.add(album.browseId)) {
        continue;
      }
      albums.add(album);
      if (albums.length == limit) {
        break;
      }
    }
    return List.unmodifiable(albums);
  }

  List<InnerTubeSong> parseSongs(
    Object? payload, {
    int limit = innerTubeDetailResultLimit,
  }) => _parseSongPage(payload, limit: limit).songs;

  _InnerTubeAlbumSongPage _parseSongPage(
    Object? payload, {
    required int limit,
    String? fallbackAlbumTitle,
    List<String> fallbackAlbumArtists = const [],
    List<String?> fallbackAlbumArtistBrowseIds = const [],
  }) {
    _validateSongLimit(limit);
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music album response must be a JSON object.',
      );
    }

    final header = _findAlbumHeader(payload);
    final headerAlbumTitle = header == null
        ? null
        : _textFromRenderer(header['title']);
    final headerAlbumArtistMetadata = header == null
        ? const _InnerTubeArtists(names: [], browseIds: [])
        : _headerArtists(header);
    final albumTitle = headerAlbumTitle ?? fallbackAlbumTitle;
    final albumArtists = headerAlbumArtistMetadata.names.isEmpty
        ? fallbackAlbumArtists
        : headerAlbumArtistMetadata.names;
    final albumArtistBrowseIds = headerAlbumArtistMetadata.names.isEmpty
        ? _alignedArtistBrowseIds(
            fallbackAlbumArtists,
            fallbackAlbumArtistBrowseIds,
          )
        : headerAlbumArtistMetadata.browseIds;
    final trackShelf = _findAlbumTrackShelf(payload);
    final songs = _songParser.parseDetailSongs(
      trackShelf ?? payload,
      limit: limit,
    );
    return _InnerTubeAlbumSongPage(
      albumTitle: albumTitle,
      albumArtists: List.unmodifiable(albumArtists),
      albumArtistBrowseIds: List.unmodifiable(albumArtistBrowseIds),
      songs: List.unmodifiable(
        songs.map((song) {
          final artists = <String>[];
          final artistBrowseIds = <String?>[];
          for (var index = 0; index < song.artists.length; index += 1) {
            final artist = _songParser._artistText(song.artists[index]);
            if (artist == null) {
              continue;
            }
            artists.add(artist);
            artistBrowseIds.add(
              index < song.artistBrowseIds.length
                  ? song.artistBrowseIds[index]
                  : null,
            );
          }
          final resolvedArtists = artists.isEmpty ? albumArtists : artists;
          final resolvedArtistBrowseIds = artists.isEmpty
              ? albumArtistBrowseIds
              : artistBrowseIds;
          final songAlbum = song.album ?? albumTitle;
          return InnerTubeSong(
            videoId: song.videoId,
            title: song.title,
            artists: resolvedArtists,
            artistBrowseIds: resolvedArtistBrowseIds,
            album: songAlbum,
            duration: song.duration,
            thumbnailUrl: song.thumbnailUrl,
          );
        }),
      ),
    );
  }

  InnerTubeAlbum? _parseResponsiveAlbum(Map<dynamic, dynamic> renderer) {
    final columns = _songParser
        ._maps(renderer['flexColumns'])
        .toList(growable: false);
    final titleRuns = columns.isEmpty
        ? const <Map<dynamic, dynamic>>[]
        : _songParser._columnRuns(columns.first).toList(growable: false);
    final title = _songParser._firstText(titleRuns);
    final browseId =
        _findAlbumBrowseId(renderer['navigationEndpoint']) ??
        _findAlbumBrowseId(titleRuns);
    if (title == null || browseId == null) {
      return null;
    }

    final metadataRuns = <Map<dynamic, dynamic>>[];
    for (final column in columns.skip(1)) {
      metadataRuns.addAll(_songParser._columnRuns(column));
    }
    final metadata = _parseMetadata(metadataRuns);
    return InnerTubeAlbum(
      browseId: browseId,
      title: title,
      artists: metadata.artists,
      artistBrowseIds: metadata.artistBrowseIds,
      year: metadata.year,
      type: metadata.type,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
      playlistId: _findPlaylistId(renderer),
    );
  }

  InnerTubeAlbum? _parseTwoRowAlbum(Map<dynamic, dynamic> renderer) {
    final title = _textFromRenderer(renderer['title']);
    final browseId =
        _findAlbumBrowseId(renderer['navigationEndpoint']) ??
        _findAlbumBrowseId(renderer['title']);
    if (title == null || browseId == null) {
      return null;
    }
    final metadata = _parseMetadata(_songParser._runs(renderer['subtitle']));
    return InnerTubeAlbum(
      browseId: browseId,
      title: title,
      artists: metadata.artists,
      artistBrowseIds: metadata.artistBrowseIds,
      year: metadata.year,
      type: metadata.type,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
      playlistId: _findPlaylistId(renderer),
    );
  }

  _InnerTubeAlbumMetadata _parseMetadata(Iterable<Map<dynamic, dynamic>> runs) {
    final artists = <String>[];
    final artistBrowseIds = <String?>[];
    final untypedText = <String>[];
    String? year;
    for (final run in runs) {
      final text = _songParser._text(run['text']);
      if (text == null || _songParser._isSeparator(text)) {
        continue;
      }
      final pageType = _songParser._browsePageType(run);
      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
        final artistText = _songParser._artistText(run['text']);
        if (artistText != null) {
          final existingIndex = artists.indexOf(artistText);
          final browseId = _songParser._browseId(run);
          if (existingIndex < 0) {
            artists.add(artistText);
            artistBrowseIds.add(browseId);
          } else if (artistBrowseIds[existingIndex] == null) {
            artistBrowseIds[existingIndex] = browseId;
          }
        }
      } else if (_yearPattern.hasMatch(text) && year == null) {
        year = text;
      } else if (pageType != 'MUSIC_PAGE_TYPE_ALBUM') {
        final genericText = _songParser._artistText(run['text']);
        if (genericText != null) {
          untypedText.add(genericText);
        }
      }
    }

    final type = untypedText.isEmpty ? null : untypedText.first;
    if (artists.isEmpty && untypedText.length > 1) {
      for (final candidate in untypedText.skip(1)) {
        if (!artists.contains(candidate)) {
          artists.add(candidate);
          artistBrowseIds.add(null);
        }
      }
    }
    return _InnerTubeAlbumMetadata(
      artists: List.unmodifiable(artists),
      artistBrowseIds: List.unmodifiable(artistBrowseIds),
      year: year,
      type: type,
    );
  }

  Iterable<_InnerTubeAlbumRenderer> _albumItemRenderers(Object? node) sync* {
    if (node is Map) {
      final responsive = node['musicResponsiveListItemRenderer'];
      if (responsive is Map) {
        yield _InnerTubeAlbumRenderer(responsive, isTwoRow: false);
      }
      final twoRow = node['musicTwoRowItemRenderer'];
      if (twoRow is Map) {
        yield _InnerTubeAlbumRenderer(twoRow, isTwoRow: true);
      }
      for (final value in node.values) {
        yield* _albumItemRenderers(value);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _albumItemRenderers(value);
      }
    }
  }

  String? _findAlbumBrowseId(Object? node) {
    if (node is Map) {
      final browse = node['browseEndpoint'];
      if (browse is Map) {
        final browseId = _songParser._text(browse['browseId']);
        if (browseId != null && _albumBrowseIdPattern.hasMatch(browseId)) {
          return browseId;
        }
      }
      for (final value in node.values) {
        final browseId = _findAlbumBrowseId(value);
        if (browseId != null) {
          return browseId;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final browseId = _findAlbumBrowseId(value);
        if (browseId != null) {
          return browseId;
        }
      }
    }
    return null;
  }

  String? _findPlaylistId(Object? node) {
    String? preferred;
    String? fallback;

    void visit(Object? value) {
      if (preferred != null) {
        return;
      }
      if (value is Map) {
        for (final endpointName in const <String>[
          'watchEndpoint',
          'watchPlaylistEndpoint',
        ]) {
          final endpoint = value[endpointName];
          if (endpoint is! Map) {
            continue;
          }
          final playlistId = _songParser._text(endpoint['playlistId']);
          if (playlistId == null || !_playlistIdPattern.hasMatch(playlistId)) {
            continue;
          }
          if (playlistId.startsWith('OLAK5uy_')) {
            preferred = playlistId;
            return;
          }
          fallback ??= playlistId;
        }
        for (final nested in value.values) {
          visit(nested);
        }
      } else if (value is List) {
        for (final nested in value) {
          visit(nested);
        }
      }
    }

    visit(node);
    return preferred ?? fallback;
  }

  Map<dynamic, dynamic>? _findAlbumHeader(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'musicResponsiveHeaderRenderer',
        'musicDetailHeaderRenderer',
        'musicImmersiveHeaderRenderer',
      ]) {
        final renderer = node[key];
        if (renderer is Map) {
          return renderer;
        }
      }
      for (final value in node.values) {
        final header = _findAlbumHeader(value);
        if (header != null) {
          return header;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final header = _findAlbumHeader(value);
        if (header != null) {
          return header;
        }
      }
    }
    return null;
  }

  Map<dynamic, dynamic>? _findAlbumTrackShelf(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'musicShelfRenderer',
        'musicPlaylistShelfRenderer',
      ]) {
        final renderer = node[key];
        if (renderer is Map && _containsSongRow(renderer['contents'])) {
          return renderer;
        }
      }
      for (final value in node.values) {
        final shelf = _findAlbumTrackShelf(value);
        if (shelf != null) {
          return shelf;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final shelf = _findAlbumTrackShelf(value);
        if (shelf != null) {
          return shelf;
        }
      }
    }
    return null;
  }

  bool _containsSongRow(Object? contents) {
    if (contents is! List) {
      return false;
    }
    return contents.any(
      (item) =>
          item is Map &&
          (item['musicResponsiveListItemRenderer'] is Map ||
              item['musicTwoRowItemRenderer'] is Map),
    );
  }

  _InnerTubeArtists _headerArtists(Map<dynamic, dynamic> header) {
    final artists = <String>[];
    final artistBrowseIds = <String?>[];

    void visit(Object? node) {
      if (node is Map) {
        final text = _songParser._artistText(node['text']);
        if (text != null &&
            _songParser._browsePageType(node) == 'MUSIC_PAGE_TYPE_ARTIST') {
          final existingIndex = artists.indexOf(text);
          final browseId = _songParser._browseId(node);
          if (existingIndex < 0) {
            artists.add(text);
            artistBrowseIds.add(browseId);
          } else if (artistBrowseIds[existingIndex] == null) {
            artistBrowseIds[existingIndex] = browseId;
          }
        }
        for (final value in node.values) {
          visit(value);
        }
      } else if (node is List) {
        for (final value in node) {
          visit(value);
        }
      }
    }

    visit(header);
    if (artists.isNotEmpty) {
      return _InnerTubeArtists(
        names: List.unmodifiable(artists),
        browseIds: List.unmodifiable(artistBrowseIds),
      );
    }

    for (final key in const <String>[
      'straplineTextOne',
      'subtitle',
      'secondSubtitle',
    ]) {
      for (final run in _songParser._runs(header[key])) {
        final text = _songParser._artistText(run['text']);
        if (text == null ||
            _songParser._isSeparator(text) ||
            _yearPattern.hasMatch(text) ||
            _looksLikeAlbumType(text) ||
            _looksLikeAlbumSummary(text)) {
          continue;
        }
        artists.add(text);
        artistBrowseIds.add(null);
        return _InnerTubeArtists(
          names: List.unmodifiable(artists),
          browseIds: List.unmodifiable(artistBrowseIds),
        );
      }
    }
    return const _InnerTubeArtists(names: [], browseIds: []);
  }

  List<String?> _alignedArtistBrowseIds(
    List<String> artists,
    List<String?> browseIds,
  ) {
    if (artists.length == browseIds.length) {
      return browseIds;
    }
    return List<String?>.filled(artists.length, null);
  }

  String? _textFromRenderer(Object? renderer) {
    if (renderer is String) {
      final normalized = renderer.trim();
      return normalized.isEmpty ? null : normalized;
    }
    if (renderer is! Map) {
      return null;
    }
    final simpleText = _songParser._text(renderer['simpleText']);
    return simpleText ?? _songParser._firstText(_songParser._runs(renderer));
  }

  bool _looksLikeAlbumType(String value) {
    switch (value.trim().toLowerCase()) {
      case 'album':
      case 'álbum':
      case 'single':
      case 'sencillo':
      case 'ep':
        return true;
      default:
        return false;
    }
  }

  bool _looksLikeAlbumSummary(String value) {
    final normalized = value.toLowerCase();
    return _songParser._parseDuration(value) != null ||
        normalized.contains('canción') ||
        normalized.contains('cancion') ||
        normalized.contains('song') ||
        normalized.contains('pista') ||
        normalized.contains('track');
  }

  void _validateSearchLimit(int limit) {
    if (limit < 1 || limit > InnerTubeSearchService.maxResults) {
      throw RangeError.range(
        limit,
        1,
        InnerTubeSearchService.maxResults,
        'limit',
      );
    }
  }

  void _validateSongLimit(int limit) {
    if (limit < 1 || limit > InnerTubeSearchService.maxDetailResults) {
      throw RangeError.range(
        limit,
        1,
        InnerTubeSearchService.maxDetailResults,
        'limit',
      );
    }
  }

  static final RegExp _albumBrowseIdPattern = RegExp(
    r'^MPRE[A-Za-z0-9_-]{1,200}$',
  );
  static final RegExp _playlistIdPattern = RegExp(r'^[A-Za-z0-9_-]{10,200}$');
  static final RegExp _yearPattern = RegExp(r'^\d{4}$');
}

class _InnerTubeAlbumRenderer {
  const _InnerTubeAlbumRenderer(this.renderer, {required this.isTwoRow});

  final Map<dynamic, dynamic> renderer;
  final bool isTwoRow;
}

class _InnerTubeAlbumMetadata {
  const _InnerTubeAlbumMetadata({
    required this.artists,
    required this.artistBrowseIds,
    required this.year,
    required this.type,
  });

  final List<String> artists;
  final List<String?> artistBrowseIds;
  final String? year;
  final String? type;
}

class _InnerTubeAlbumSongPage {
  const _InnerTubeAlbumSongPage({
    required this.songs,
    required this.albumTitle,
    required this.albumArtists,
    required this.albumArtistBrowseIds,
  });

  final List<InnerTubeSong> songs;
  final String? albumTitle;
  final List<String> albumArtists;
  final List<String?> albumArtistBrowseIds;
}

class _InnerTubeArtists {
  const _InnerTubeArtists({required this.names, required this.browseIds});

  final List<String> names;
  final List<String?> browseIds;
}

class _InnerTubeSongRenderer {
  const _InnerTubeSongRenderer(this.renderer, {required this.isTwoRow});

  final Map<dynamic, dynamic> renderer;
  final bool isTwoRow;
}

class InnerTubeArtistParser {
  const InnerTubeArtistParser({
    this._songParser = const InnerTubeSearchParser(),
    this._albumParser = const InnerTubeAlbumParser(),
  });

  final InnerTubeSearchParser _songParser;
  final InnerTubeAlbumParser _albumParser;

  InnerTubeArtistProfile parse(
    Object? payload, {
    required String artistBrowseId,
    String? fallbackName,
    String? fallbackThumbnailUrl,
    int songLimit = 20,
    int releaseLimit = 20,
  }) {
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music artist response must be a JSON object.',
      );
    }
    if (songLimit < 1 || songLimit > InnerTubeSearchService.maxResults) {
      throw RangeError.range(
        songLimit,
        1,
        InnerTubeSearchService.maxResults,
        'songLimit',
      );
    }
    if (releaseLimit < 1 || releaseLimit > InnerTubeSearchService.maxResults) {
      throw RangeError.range(
        releaseLimit,
        1,
        InnerTubeSearchService.maxResults,
        'releaseLimit',
      );
    }

    final header = _findArtistHeader(payload);
    final resolvedName = _firstNonEmpty(<String?>[
      header == null ? null : _textFromRenderer(header['title']),
      fallbackName,
      artistBrowseId,
    ])!;
    final thumbnailUrl = _firstNonEmpty(<String?>[
      header == null ? null : _largestThumbnailUrl(header),
      fallbackThumbnailUrl,
    ]);
    final popularShelf = _findPopularSongsShelf(payload);
    final popularSongs = popularShelf == null
        ? const <InnerTubeSong>[]
        : _songParser.parseDetailSongs(popularShelf, limit: songLimit);

    final albums = <InnerTubeAlbum>[];
    final singles = <InnerTubeAlbum>[];
    final seenBrowseIds = <String>{};
    final relatedArtists = <InnerTubeArtist>[];
    final seenRelatedArtistBrowseIds = <String>{artistBrowseId.trim()};
    for (final shelf in _carouselShelves(payload)) {
      if (relatedArtists.length < 12) {
        for (final artist in _artistsFromCarousel(shelf)) {
          final browseId = artist.browseId.trim();
          if (browseId.isEmpty || !seenRelatedArtistBrowseIds.add(browseId)) {
            continue;
          }
          relatedArtists.add(
            browseId == artist.browseId
                ? artist
                : InnerTubeArtist(
                    browseId: browseId,
                    name: artist.name,
                    thumbnailUrl: artist.thumbnailUrl,
                  ),
          );
          if (relatedArtists.length == 12) break;
        }
      }
      final title = _carouselShelfTitle(shelf).toLowerCase();
      final releases = _albumParser.parse(shelf, limit: releaseLimit);
      for (final release in releases) {
        if (!seenBrowseIds.add(release.browseId)) continue;
        if (_isSinglesSection(title) || _isSingleType(release.type)) {
          if (singles.length < releaseLimit) singles.add(release);
        } else if (albums.length < releaseLimit) {
          albums.add(release);
        }
      }
    }

    // Some artist layouts omit carousel titles. Preserve those releases by
    // classifying their metadata after the explicitly titled shelves.
    for (final release in _albumParser.parse(payload, limit: releaseLimit)) {
      if (!seenBrowseIds.add(release.browseId)) continue;
      if (_isSingleType(release.type)) {
        if (singles.length < releaseLimit) singles.add(release);
      } else if (albums.length < releaseLimit) {
        albums.add(release);
      }
    }

    final subscription = _findSubscription(payload);
    final startRadio = _findStartRadio(payload);
    final playPlaylistId = header == null
        ? null
        : _findHeaderPlayPlaylistId(header);
    final channelId = _firstNonEmpty(<String?>[
      subscription?.channelId,
      artistBrowseId.startsWith('UC') ? artistBrowseId : null,
    ]);
    return InnerTubeArtistProfile(
      artist: InnerTubeArtist(
        browseId: artistBrowseId,
        name: resolvedName,
        thumbnailUrl: thumbnailUrl,
      ),
      description: _findDescription(payload),
      subscriberCount: _findSubscriberCount(header ?? payload),
      monthlyListenerCount: _findMonthlyListenerCount(header ?? payload),
      channelId: channelId,
      playPlaylistId: playPlaylistId,
      radioPlaylistId: startRadio?.playlistId ?? _findRadioPlaylistId(payload),
      radioSeedVideoId: startRadio?.videoId ?? _findRadioVideoId(payload),
      isSubscribed: subscription?.isSubscribed,
      popularSongs: popularSongs,
      albums: albums,
      singles: singles,
      relatedArtists: relatedArtists,
    );
  }

  Map<dynamic, dynamic>? _findArtistHeader(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'musicImmersiveHeaderRenderer',
        'musicVisualHeaderRenderer',
        'musicResponsiveHeaderRenderer',
      ]) {
        final renderer = node[key];
        if (renderer is Map) return renderer;
      }
      for (final value in node.values) {
        final result = _findArtistHeader(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findArtistHeader(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  Map<dynamic, dynamic>? _findPopularSongsShelf(Object? node) {
    Map<dynamic, dynamic>? fallback;

    void visit(Object? value) {
      if (value is Map) {
        final renderer = value['musicShelfRenderer'];
        if (renderer is Map && _containsResponsiveSong(renderer['contents'])) {
          fallback ??= renderer;
          final title = _textFromRenderer(renderer['title']).toLowerCase();
          if (_isPopularSongsTitle(title)) {
            fallback = <dynamic, dynamic>{...renderer, '_preferred': true};
            return;
          }
        }
        if (fallback?['_preferred'] == true) return;
        for (final nested in value.values) {
          visit(nested);
          if (fallback?['_preferred'] == true) return;
        }
      } else if (value is List) {
        for (final nested in value) {
          visit(nested);
          if (fallback?['_preferred'] == true) return;
        }
      }
    }

    visit(node);
    if (fallback?['_preferred'] == true) {
      return Map<dynamic, dynamic>.of(fallback!)..remove('_preferred');
    }
    return fallback;
  }

  Iterable<Map<dynamic, dynamic>> _carouselShelves(Object? node) sync* {
    if (node is Map) {
      final renderer = node['musicCarouselShelfRenderer'];
      if (renderer is Map) yield renderer;
      for (final value in node.values) {
        yield* _carouselShelves(value);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _carouselShelves(value);
      }
    }
  }

  Iterable<InnerTubeArtist> _artistsFromCarousel(
    Map<dynamic, dynamic> shelf,
  ) sync* {
    final contents = shelf['contents'];
    if (contents is! List) return;
    for (final item in contents) {
      if (item is! Map) continue;
      final renderer = item['musicTwoRowItemRenderer'];
      if (renderer is! Map) continue;
      final artist = _parseArtistCard(renderer);
      if (artist != null) yield artist;
    }
  }

  InnerTubeArtist? _parseArtistCard(Map<dynamic, dynamic> renderer) {
    final titleRuns = _songParser
        ._runs(renderer['title'])
        .toList(growable: false);
    final name = _songParser._firstText(titleRuns);
    if (name == null) return null;
    final browseId =
        _directArtistBrowseId(renderer['navigationEndpoint']) ??
        _artistBrowseIdFromRuns(titleRuns);
    if (browseId == null) return null;
    return InnerTubeArtist(
      browseId: browseId,
      name: name,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
    );
  }

  String? _artistBrowseIdFromRuns(Iterable<Map<dynamic, dynamic>> runs) {
    for (final run in runs) {
      final browseId = _directArtistBrowseId(run['navigationEndpoint']);
      if (browseId != null) return browseId;
    }
    return null;
  }

  String? _directArtistBrowseId(Object? endpoint) {
    if (endpoint is! Map) return null;
    final browse = endpoint['browseEndpoint'];
    if (browse is! Map) return null;
    final browseId = _songParser._text(browse['browseId']);
    if (browseId == null) return null;
    final configs = browse['browseEndpointContextSupportedConfigs'];
    final musicConfig = configs is Map
        ? configs['browseEndpointContextMusicConfig']
        : null;
    final pageType = musicConfig is Map
        ? _songParser._text(musicConfig['pageType'])
        : null;
    return pageType == 'MUSIC_PAGE_TYPE_ARTIST' ? browseId : null;
  }

  String _carouselShelfTitle(Map<dynamic, dynamic> shelf) {
    final header = shelf['header'];
    if (header is! Map) return '';
    final basic = header['musicCarouselShelfBasicHeaderRenderer'];
    if (basic is Map) {
      final title = _textFromRenderer(basic['title']);
      if (title.isNotEmpty) return title;
    }
    final responsive = header['musicCarouselShelfHeaderRenderer'];
    if (responsive is Map) {
      final title = _textFromRenderer(responsive['title']);
      if (title.isNotEmpty) return title;
    }
    return _textFromRenderer(header['title']);
  }

  bool _containsResponsiveSong(Object? contents) {
    return contents is List &&
        contents.any(
          (item) =>
              item is Map && item['musicResponsiveListItemRenderer'] is Map,
        );
  }

  bool _isPopularSongsTitle(String title) {
    return title.contains('popular') ||
        title.contains('canciones') ||
        title == 'songs';
  }

  bool _isSinglesSection(String title) {
    return title.contains('single') ||
        title.contains('sencillo') ||
        title.contains('ep');
  }

  bool _isSingleType(String? type) {
    final normalized = type?.trim().toLowerCase() ?? '';
    return normalized == 'single' ||
        normalized == 'sencillo' ||
        normalized == 'ep';
  }

  String? _findDescription(Object? node) {
    if (node is Map) {
      final renderer = node['musicDescriptionShelfRenderer'];
      if (renderer is Map) {
        final description = _textFromRenderer(renderer['description']);
        if (description.isNotEmpty) return description;
      }
      for (final value in node.values) {
        final description = _findDescription(value);
        if (description != null) return description;
      }
    } else if (node is List) {
      for (final value in node) {
        final description = _findDescription(value);
        if (description != null) return description;
      }
    }
    return null;
  }

  String? _findSubscriberCount(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'longSubscriberCountText',
        'subscriberCountText',
        'subscriptionCountText',
      ]) {
        final text = _textFromRenderer(node[key]);
        if (text.isNotEmpty) return text;
      }
      for (final value in node.values) {
        final result = _findSubscriberCount(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findSubscriberCount(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  String? _findMonthlyListenerCount(Object? node) {
    if (node is Map) {
      final text = _textFromRenderer(node['monthlyListenerCount']);
      if (text.isNotEmpty) return text;
      for (final value in node.values) {
        final result = _findMonthlyListenerCount(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findMonthlyListenerCount(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  _InnerTubeArtistSubscription? _findSubscription(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'subscribeButtonRenderer',
        'musicSubscribeButtonRenderer',
      ]) {
        final renderer = node[key];
        if (renderer is Map) {
          final channelId = _firstNonEmpty(<String?>[
            _songParser._text(renderer['channelId']),
            _findChannelId(renderer),
          ]);
          final subscribed = renderer['subscribed'];
          if (channelId != null || subscribed is bool) {
            return _InnerTubeArtistSubscription(
              channelId: channelId,
              isSubscribed: subscribed is bool ? subscribed : null,
            );
          }
        }
      }
      for (final value in node.values) {
        final result = _findSubscription(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findSubscription(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  String? _findChannelId(Object? node) {
    if (node is Map) {
      final browse = node['browseEndpoint'];
      if (browse is Map) {
        final browseId = _songParser._text(browse['browseId']);
        if (browseId != null && browseId.startsWith('UC')) return browseId;
      }
      for (final value in node.values) {
        final result = _findChannelId(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findChannelId(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  String? _findRadioPlaylistId(Object? node) {
    if (node is Map) {
      final label = _textFromRenderer(
        node['text'] ?? node['buttonText'] ?? node['accessibility'],
      ).toLowerCase();
      if (label.contains('radio')) {
        final playlistId = _findPlaylistId(node);
        if (playlistId != null) return playlistId;
      }
      for (final value in node.values) {
        final result = _findRadioPlaylistId(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findRadioPlaylistId(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  String? _findHeaderPlayPlaylistId(Map<dynamic, dynamic> header) {
    for (final actionKey in const <String>['playButton', 'shufflePlayButton']) {
      final action = header[actionKey];
      if (action is! Map) continue;
      for (final rendererKey in const <String>[
        'buttonRenderer',
        'musicPlayButtonRenderer',
      ]) {
        final renderer = action[rendererKey];
        if (renderer is! Map) continue;
        final playlistId = _findPlaylistId(renderer);
        if (playlistId != null) return playlistId;
      }
    }
    return null;
  }

  _InnerTubeArtistRadio? _findStartRadio(Object? node) {
    if (node is Map) {
      final startRadioButton = node['startRadioButton'];
      if (startRadioButton is Map) {
        final playlistId = _findPlaylistId(startRadioButton);
        final videoId = _songParser._findWatchVideoId(startRadioButton);
        if (playlistId != null && videoId != null) {
          return _InnerTubeArtistRadio(
            playlistId: playlistId,
            videoId: videoId,
          );
        }
      }
      for (final value in node.values) {
        final result = _findStartRadio(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findStartRadio(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  String? _findRadioVideoId(Object? node) {
    if (node is Map) {
      final label = _textFromRenderer(
        node['text'] ?? node['buttonText'] ?? node['accessibility'],
      ).toLowerCase();
      if (label.contains('radio')) {
        final videoId = _songParser._findWatchVideoId(node);
        if (videoId != null) return videoId;
      }
      for (final value in node.values) {
        final result = _findRadioVideoId(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findRadioVideoId(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  String? _findPlaylistId(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'watchEndpoint',
        'watchPlaylistEndpoint',
      ]) {
        final endpoint = node[key];
        if (endpoint is Map) {
          final playlistId = _songParser._text(endpoint['playlistId']);
          if (playlistId != null) return playlistId;
        }
      }
      for (final value in node.values) {
        final result = _findPlaylistId(value);
        if (result != null) return result;
      }
    } else if (node is List) {
      for (final value in node) {
        final result = _findPlaylistId(value);
        if (result != null) return result;
      }
    }
    return null;
  }

  String? _largestThumbnailUrl(Object? node) {
    String? selected;
    var selectedArea = -1;

    void visit(Object? value) {
      if (value is Map) {
        final thumbnails = value['thumbnails'];
        if (thumbnails is List) {
          for (final candidate in thumbnails) {
            if (candidate is! Map) continue;
            var url = _songParser._text(candidate['url']);
            if (url == null) continue;
            if (url.startsWith('//')) url = 'https:$url';
            final width = _songParser._integer(candidate['width']) ?? 0;
            final height = _songParser._integer(candidate['height']) ?? 0;
            final area = width * height;
            if (area >= selectedArea) {
              selected = url;
              selectedArea = area;
            }
          }
        }
        for (final nested in value.values) {
          visit(nested);
        }
      } else if (value is List) {
        for (final nested in value) {
          visit(nested);
        }
      }
    }

    visit(node);
    return selected;
  }

  String _textFromRenderer(Object? renderer) {
    return _songParser._text(renderer)?.trim() ?? '';
  }

  String? _firstNonEmpty(Iterable<String?> values) {
    for (final value in values) {
      final normalized = value?.trim();
      if (normalized != null && normalized.isNotEmpty) return normalized;
    }
    return null;
  }
}

class _InnerTubeArtistSubscription {
  const _InnerTubeArtistSubscription({
    required this.channelId,
    required this.isSubscribed,
  });

  final String? channelId;
  final bool? isSubscribed;
}

class _InnerTubeArtistRadio {
  const _InnerTubeArtistRadio({
    required this.playlistId,
    required this.videoId,
  });

  final String playlistId;
  final String videoId;
}

class InnerTubeHomeParser {
  const InnerTubeHomeParser({this._songParser = const InnerTubeSearchParser()});

  final InnerTubeSearchParser _songParser;

  List<InnerTubeHomeSection> parse(
    Object? payload, {
    int maxSections = 2,
    int maxItemsPerSection = 8,
  }) {
    return _parse(
      payload,
      maxSections: maxSections,
      maxItemsPerSection: maxItemsPerSection,
      seenVideoIds: <String>{},
      seenBrowseIds: <String>{},
      seenArtistBrowseIds: <String>{},
    );
  }

  List<InnerTubeHomeSection> _parse(
    Object? payload, {
    required int maxSections,
    required int maxItemsPerSection,
    required Set<String> seenVideoIds,
    required Set<String> seenBrowseIds,
    required Set<String> seenArtistBrowseIds,
  }) {
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
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music home response must be a JSON object.',
      );
    }

    final sections = <InnerTubeHomeSection>[];
    for (final shelf in _shelfRenderers(payload)) {
      final title = _shelfTitle(shelf);
      if (title == null) {
        continue;
      }

      final items = <InnerTubeHomeItem>[];
      for (final candidate in _maps(shelf['contents'])) {
        final responsive = candidate['musicResponsiveListItemRenderer'];
        final twoRow = candidate['musicTwoRowItemRenderer'];
        InnerTubeSong? song;
        if (responsive is Map) {
          song = _songParser._parseSong(responsive);
        } else if (twoRow is Map) {
          song = _songParser._parseTwoRowSong(twoRow);
        }
        if (song != null) {
          if (seenVideoIds.add(song.videoId)) {
            items.add(InnerTubeHomeSongItem(song));
          }
        } else if (twoRow is Map) {
          final artist = _parseArtist(twoRow);
          if (artist != null) {
            if (seenArtistBrowseIds.add(artist.browseId)) {
              items.add(InnerTubeHomeArtistItem(artist));
            }
          } else {
            final collection = _parseCollection(twoRow);
            if (collection != null && seenBrowseIds.add(collection.browseId)) {
              items.add(collection);
            }
          }
        }
        if (items.length == maxItemsPerSection) {
          break;
        }
      }
      if (items.isEmpty) {
        continue;
      }
      sections.add(InnerTubeHomeSection(title: title, items: items));
      if (sections.length == maxSections) {
        break;
      }
    }
    return List.unmodifiable(sections);
  }

  Iterable<Map<dynamic, dynamic>> _shelfRenderers(Object? node) sync* {
    if (node is Map) {
      for (final key in const <String>[
        'musicCarouselShelfRenderer',
        'musicShelfRenderer',
        'musicImmersiveCarouselShelfRenderer',
      ]) {
        final renderer = node[key];
        if (renderer is Map) {
          yield renderer;
        }
      }
      for (final value in node.values) {
        yield* _shelfRenderers(value);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _shelfRenderers(value);
      }
    }
  }

  String? _shelfTitle(Map<dynamic, dynamic> shelf) {
    final direct = _textFromRenderer(shelf['title']);
    if (direct != null) {
      return direct;
    }
    final header = shelf['header'];
    if (header is! Map) {
      return null;
    }
    for (final key in const <String>[
      'musicCarouselShelfBasicHeaderRenderer',
      'musicImmersiveCarouselShelfHeaderRenderer',
      'musicShelfBasicHeaderRenderer',
    ]) {
      final renderer = header[key];
      if (renderer is Map) {
        final title = _textFromRenderer(renderer['title']);
        if (title != null) {
          return title;
        }
      }
    }
    return null;
  }

  InnerTubeArtist? _parseArtist(Map<dynamic, dynamic> renderer) {
    final titleRuns = _songParser
        ._runs(renderer['title'])
        .toList(growable: false);
    final name = _songParser._firstText(titleRuns);
    if (name == null) {
      return null;
    }
    final browseId =
        _directArtistBrowseId(renderer['navigationEndpoint']) ??
        _artistBrowseIdFromRuns(titleRuns);
    if (browseId == null) {
      return null;
    }
    return InnerTubeArtist(
      browseId: browseId,
      name: name,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
    );
  }

  String? _artistBrowseIdFromRuns(Iterable<Map<dynamic, dynamic>> runs) {
    for (final run in runs) {
      final browseId = _directArtistBrowseId(run['navigationEndpoint']);
      if (browseId != null) {
        return browseId;
      }
    }
    return null;
  }

  String? _directArtistBrowseId(Object? endpoint) {
    if (endpoint is! Map) {
      return null;
    }
    final browse = endpoint['browseEndpoint'];
    if (browse is! Map) {
      return null;
    }
    final browseId = _songParser._text(browse['browseId']);
    if (browseId == null) {
      return null;
    }
    final configs = browse['browseEndpointContextSupportedConfigs'];
    final musicConfig = configs is Map
        ? configs['browseEndpointContextMusicConfig']
        : null;
    final pageType = musicConfig is Map
        ? _songParser._text(musicConfig['pageType'])
        : null;
    return pageType == 'MUSIC_PAGE_TYPE_ARTIST' ? browseId : null;
  }

  InnerTubeHomeCollection? _parseCollection(Map<dynamic, dynamic> renderer) {
    final title = _textFromRenderer(renderer['title']);
    if (title == null) {
      return null;
    }

    var browseId =
        _findCollectionBrowseId(renderer['navigationEndpoint']) ??
        _findCollectionBrowseId(renderer['title']);
    final playlistId =
        _findPlaylistId(renderer['thumbnailOverlay']) ??
        _findPlaylistId(renderer['overlay']) ??
        _findPlaylistId(renderer['navigationEndpoint']) ??
        _findPlaylistId(renderer['title']) ??
        _findPlaylistId(renderer['menu']);
    if (browseId == null && playlistId != null) {
      final derived = 'VL$playlistId';
      if (_collectionBrowseIdPattern.hasMatch(derived)) {
        browseId = derived;
      }
    }
    if (browseId == null) {
      return null;
    }

    final collectionIdentity = playlistId ?? browseId.substring(2);
    return InnerTubeHomeCollection(
      title: title,
      subtitle: _textFromRenderer(renderer['subtitle']),
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
      browseId: browseId,
      playlistId: playlistId,
      kind: collectionIdentity.startsWith('RD')
          ? InnerTubeHomeCollectionKind.mix
          : InnerTubeHomeCollectionKind.playlist,
    );
  }

  String? _findCollectionBrowseId(Object? node) {
    if (node is Map) {
      final browse = node['browseEndpoint'];
      if (browse is Map) {
        final browseId = _text(browse['browseId']);
        if (browseId != null && _collectionBrowseIdPattern.hasMatch(browseId)) {
          return browseId;
        }
      }
      for (final value in node.values) {
        final browseId = _findCollectionBrowseId(value);
        if (browseId != null) {
          return browseId;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final browseId = _findCollectionBrowseId(value);
        if (browseId != null) {
          return browseId;
        }
      }
    }
    return null;
  }

  String? _findPlaylistId(Object? node) {
    if (node is Map) {
      for (final endpointName in const <String>[
        'watchPlaylistEndpoint',
        'watchEndpoint',
      ]) {
        final endpoint = node[endpointName];
        if (endpoint is Map) {
          final playlistId = _text(endpoint['playlistId']);
          if (playlistId != null && _playlistIdPattern.hasMatch(playlistId)) {
            return playlistId;
          }
        }
      }
      for (final value in node.values) {
        final playlistId = _findPlaylistId(value);
        if (playlistId != null) {
          return playlistId;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final playlistId = _findPlaylistId(value);
        if (playlistId != null) {
          return playlistId;
        }
      }
    }
    return null;
  }

  Iterable<Map<dynamic, dynamic>> _maps(Object? value) sync* {
    if (value is! List) {
      return;
    }
    for (final item in value) {
      if (item is Map) {
        yield item;
      }
    }
  }

  String? _text(Object? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.toString().trim();
    return normalized.isEmpty ? null : normalized;
  }

  static final RegExp _collectionBrowseIdPattern = RegExp(
    r'^VL[A-Za-z0-9_-]{1,200}$',
  );
  static final RegExp _playlistIdPattern = RegExp(r'^[A-Za-z0-9_-]{10,200}$');

  String? _textFromRenderer(Object? value) {
    if (value is String) {
      final normalized = value.trim();
      return normalized.isEmpty ? null : normalized;
    }
    if (value is! Map) {
      return null;
    }
    final simpleText = value['simpleText']?.toString().trim();
    if (simpleText != null && simpleText.isNotEmpty) {
      return simpleText;
    }
    final runs = value['runs'];
    if (runs is! List) {
      return null;
    }
    final pieces = <String>[];
    for (final run in runs) {
      if (run is! Map) {
        continue;
      }
      final text = run['text']?.toString().trim();
      if (text != null && text.isNotEmpty) {
        pieces.add(text);
      }
    }
    final joined = pieces.join().trim();
    return joined.isEmpty ? null : joined;
  }
}

class InnerTubeNextParser {
  const InnerTubeNextParser({this._songParser = const InnerTubeSearchParser()});

  final InnerTubeSearchParser _songParser;

  InnerTubeNextPage parse(
    Object? payload, {
    int limit = innerTubeDetailResultLimit,
  }) {
    if (limit < 1 || limit > InnerTubeSearchService.maxDetailResults) {
      throw RangeError.range(
        limit,
        1,
        InnerTubeSearchService.maxDetailResults,
        'limit',
      );
    }
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music next response must be a JSON object.',
      );
    }

    final panel = _findPlaylistPanel(payload);
    final songs = <InnerTubeSong>[];
    final seenVideoIds = <String>{};
    if (panel != null) {
      for (final renderer in _playlistPanelVideoRenderers(panel)) {
        final song = _parsePlaylistPanelSong(renderer);
        if (song == null || !seenVideoIds.add(song.videoId)) {
          continue;
        }
        songs.add(song);
        if (songs.length == limit) {
          break;
        }
      }
    }

    return InnerTubeNextPage(
      songs: songs,
      continuation: _findContinuation(panel ?? payload),
      relatedBrowseId: _findRelatedBrowseId(payload),
      automixPlaylistId: _findAutomixPlaylistId(payload),
    );
  }

  Map<dynamic, dynamic>? _findPlaylistPanel(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'playlistPanelRenderer',
        'playlistPanelContinuation',
      ]) {
        final panel = node[key];
        if (panel is Map) {
          return panel;
        }
      }
      for (final value in node.values) {
        final panel = _findPlaylistPanel(value);
        if (panel != null) {
          return panel;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final panel = _findPlaylistPanel(value);
        if (panel != null) {
          return panel;
        }
      }
    }
    return null;
  }

  Iterable<Map<dynamic, dynamic>> _playlistPanelVideoRenderers(
    Object? node,
  ) sync* {
    if (node is Map) {
      final renderer = node['playlistPanelVideoRenderer'];
      if (renderer is Map) {
        yield renderer;
      }
      for (final value in node.values) {
        yield* _playlistPanelVideoRenderers(value);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _playlistPanelVideoRenderers(value);
      }
    }
  }

  InnerTubeSong? _parsePlaylistPanelSong(Map<dynamic, dynamic> renderer) {
    final titleRuns = _songParser
        ._runs(renderer['title'])
        .toList(growable: false);
    final title = _songParser._firstText(titleRuns);
    final videoId =
        _songParser._text(renderer['videoId']) ??
        _songParser._watchVideoId(titleRuns) ??
        _songParser._findWatchVideoId(renderer['navigationEndpoint']);
    if (title == null || videoId == null) {
      return null;
    }

    final metadataRuns = <Map<dynamic, dynamic>>[
      ..._songParser._runs(renderer['longBylineText']),
      ..._songParser._runs(renderer['shortBylineText']),
      ..._songParser._runs(renderer['subtitle']),
    ];
    final artists = <String>[];
    final artistBrowseIds = <String?>[];
    String? album;
    String? albumBrowseId;
    Duration? duration = _songParser._parseDuration(
      _songParser._text(renderer['lengthText']) ?? '',
    );
    for (final run in metadataRuns) {
      final text = _songParser._text(run['text']);
      if (text == null) {
        continue;
      }
      final pageType = _songParser._browsePageType(run);
      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
        final artist = _songParser._artistText(run['text']);
        if (artist != null) {
          final existingIndex = artists.indexOf(artist);
          final browseId = _songParser._browseId(run);
          if (existingIndex < 0) {
            artists.add(artist);
            artistBrowseIds.add(browseId);
          } else if (artistBrowseIds[existingIndex] == null) {
            artistBrowseIds[existingIndex] = browseId;
          }
        }
      } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' && album == null) {
        album = text;
        albumBrowseId = _songParser._validatedAlbumBrowseId(run);
      }
      duration ??= _songParser._parseDuration(text);
    }
    if (artists.isEmpty) {
      for (final run in metadataRuns) {
        final text = _songParser._artistText(run['text']);
        if (text == null ||
            _songParser._isSeparator(text) ||
            _songParser._parseDuration(text) != null ||
            _songParser._browsePageType(run) == 'MUSIC_PAGE_TYPE_ALBUM') {
          continue;
        }
        artists.add(text);
        artistBrowseIds.add(null);
        break;
      }
    }

    return InnerTubeSong(
      videoId: videoId,
      title: title,
      artists: artists,
      artistBrowseIds: artistBrowseIds,
      album: album,
      albumBrowseId: albumBrowseId,
      duration: duration,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
    );
  }

  String? _findContinuation(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'nextRadioContinuationData',
        'nextContinuationData',
        'reloadContinuationData',
        'continuationCommand',
      ]) {
        final data = node[key];
        if (data is! Map) {
          continue;
        }
        final continuation = _songParser._text(
          data['continuation'] ?? data['token'],
        );
        if (continuation != null) {
          return continuation;
        }
      }
      for (final value in node.values) {
        final continuation = _findContinuation(value);
        if (continuation != null) {
          return continuation;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final continuation = _findContinuation(value);
        if (continuation != null) {
          return continuation;
        }
      }
    }
    return null;
  }

  String? _findRelatedBrowseId(Object? node) {
    if (node is Map) {
      final browse = node['browseEndpoint'];
      if (browse is Map) {
        final browseId = _songParser._text(browse['browseId']);
        final configs = browse['browseEndpointContextSupportedConfigs'];
        final musicConfig = configs is Map
            ? configs['browseEndpointContextMusicConfig']
            : null;
        final pageType = musicConfig is Map
            ? _songParser._text(musicConfig['pageType'])
            : null;
        if (browseId != null &&
            (browseId.startsWith('MPTR') ||
                (pageType?.contains('RELATED') ?? false))) {
          return browseId;
        }
      }
      for (final value in node.values) {
        final browseId = _findRelatedBrowseId(value);
        if (browseId != null) {
          return browseId;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final browseId = _findRelatedBrowseId(value);
        if (browseId != null) {
          return browseId;
        }
      }
    }
    return null;
  }

  String? _findAutomixPlaylistId(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'automixPreviewVideoRenderer',
        'automixPlaylistVideoRenderer',
      ]) {
        final automix = node[key];
        final playlistId = _findPlaylistId(automix);
        if (playlistId != null) {
          return playlistId;
        }
      }
      for (final value in node.values) {
        final playlistId = _findAutomixPlaylistId(value);
        if (playlistId != null) {
          return playlistId;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final playlistId = _findAutomixPlaylistId(value);
        if (playlistId != null) {
          return playlistId;
        }
      }
    }
    return null;
  }

  String? _findPlaylistId(Object? node) {
    if (node is Map) {
      for (final endpointName in const <String>[
        'watchPlaylistEndpoint',
        'watchEndpoint',
      ]) {
        final endpoint = node[endpointName];
        if (endpoint is Map) {
          final playlistId = _songParser._text(endpoint['playlistId']);
          if (playlistId != null && playlistId.startsWith('RD')) {
            return playlistId;
          }
        }
      }
      for (final value in node.values) {
        final playlistId = _findPlaylistId(value);
        if (playlistId != null) {
          return playlistId;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final playlistId = _findPlaylistId(value);
        if (playlistId != null) {
          return playlistId;
        }
      }
    }
    return null;
  }
}

class InnerTubeRelatedParser {
  const InnerTubeRelatedParser({
    this._songParser = const InnerTubeSearchParser(),
    this._albumParser = const InnerTubeAlbumParser(),
    this._homeParser = const InnerTubeHomeParser(),
  });

  final InnerTubeSearchParser _songParser;
  final InnerTubeAlbumParser _albumParser;
  final InnerTubeHomeParser _homeParser;

  InnerTubeRelatedPage parse(Object? payload, {int limit = 20}) {
    if (limit < 1 || limit > InnerTubeSearchService.maxResults) {
      throw RangeError.range(
        limit,
        1,
        InnerTubeSearchService.maxResults,
        'limit',
      );
    }
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music related response must be a JSON object.',
      );
    }

    final songs = _songParser.parse(payload, limit: limit);
    final albums = _albumParser.parse(payload, limit: limit);
    final artists = <InnerTubeArtist>[];
    final seenArtistBrowseIds = <String>{};
    final collections = <InnerTubeHomeCollection>[];
    final seenCollectionBrowseIds = <String>{};
    for (final renderer in _twoRowRenderers(payload)) {
      final isSong = _songParser._parseTwoRowSong(renderer) != null;
      final isAlbum = _albumParser._parseTwoRowAlbum(renderer) != null;
      final artist = _parseArtist(renderer);
      if (artist != null && seenArtistBrowseIds.add(artist.browseId)) {
        artists.add(artist);
      }
      if (!isSong && !isAlbum && artist == null) {
        final collection = _homeParser._parseCollection(renderer);
        if (collection != null &&
            seenCollectionBrowseIds.add(collection.browseId)) {
          collections.add(collection);
        }
      }
    }

    return InnerTubeRelatedPage(
      songs: songs,
      albums: albums,
      artists: artists.take(limit).toList(growable: false),
      collections: collections.take(limit).toList(growable: false),
      continuation: _findContinuation(payload),
    );
  }

  Iterable<Map<dynamic, dynamic>> _twoRowRenderers(Object? node) sync* {
    if (node is Map) {
      final twoRow = node['musicTwoRowItemRenderer'];
      if (twoRow is Map) {
        yield twoRow;
      }
      for (final value in node.values) {
        yield* _twoRowRenderers(value);
      }
    } else if (node is List) {
      for (final value in node) {
        yield* _twoRowRenderers(value);
      }
    }
  }

  InnerTubeArtist? _parseArtist(Map<dynamic, dynamic> renderer) {
    final titleRuns = _songParser
        ._runs(renderer['title'])
        .toList(growable: false);
    final name = _songParser._firstText(titleRuns);
    if (name == null) {
      return null;
    }
    final browseId =
        _directArtistBrowseId(renderer['navigationEndpoint']) ??
        _artistBrowseIdFromRuns(titleRuns);
    if (browseId == null) {
      return null;
    }
    return InnerTubeArtist(
      browseId: browseId,
      name: name,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
    );
  }

  String? _artistBrowseIdFromRuns(Iterable<Map<dynamic, dynamic>> runs) {
    for (final run in runs) {
      final browseId = _directArtistBrowseId(run['navigationEndpoint']);
      if (browseId != null) {
        return browseId;
      }
    }
    return null;
  }

  String? _directArtistBrowseId(Object? endpoint) {
    if (endpoint is! Map) {
      return null;
    }
    final browse = endpoint['browseEndpoint'];
    if (browse is! Map) {
      return null;
    }
    final browseId = _songParser._text(browse['browseId']);
    if (browseId == null) {
      return null;
    }
    final configs = browse['browseEndpointContextSupportedConfigs'];
    final musicConfig = configs is Map
        ? configs['browseEndpointContextMusicConfig']
        : null;
    final pageType = musicConfig is Map
        ? _songParser._text(musicConfig['pageType'])
        : null;
    return pageType == 'MUSIC_PAGE_TYPE_ARTIST' ? browseId : null;
  }

  String? _findContinuation(Object? node) {
    if (node is Map) {
      for (final key in const <String>[
        'nextContinuationData',
        'reloadContinuationData',
        'continuationCommand',
      ]) {
        final data = node[key];
        if (data is! Map) {
          continue;
        }
        final continuation = _songParser._text(
          data['continuation'] ?? data['token'],
        );
        if (continuation != null) {
          return continuation;
        }
      }
      for (final value in node.values) {
        final continuation = _findContinuation(value);
        if (continuation != null) {
          return continuation;
        }
      }
    } else if (node is List) {
      for (final value in node) {
        final continuation = _findContinuation(value);
        if (continuation != null) {
          return continuation;
        }
      }
    }
    return null;
  }
}

class InnerTubePlayerParser {
  const InnerTubePlayerParser();

  /// Extracts trusted duration metadata for an exact requested video ID.
  ///
  /// YouTube Music can mark anonymous WEB_REMIX player responses unplayable
  /// while still returning canonical `videoDetails`. This method deliberately
  /// ignores playability because callers use only the duration, never a stream
  /// URL or a playable-song decision.
  Duration? parseDuration(Object? payload, {required String expectedVideoId}) {
    if (payload is! Map) {
      return null;
    }
    final details = payload['videoDetails'];
    if (details is! Map || _text(details['videoId']) != expectedVideoId) {
      return null;
    }
    final microformat = payload['microformat'];
    if (microformat is Map) {
      final renderer = microformat['microformatDataRenderer'];
      if (renderer is Map) {
        final canonicalDetails = renderer['videoDetails'];
        if (canonicalDetails is Map) {
          final canonicalDuration = _duration(
            canonicalDetails['durationSeconds'],
          );
          if (canonicalDuration != null) {
            return canonicalDuration;
          }
        }
      }
    }
    return _duration(details['lengthSeconds']);
  }

  InnerTubeSong? parse(Object? payload, {required String expectedVideoId}) {
    if (payload is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music player response must be a JSON object.',
      );
    }

    final playability = payload['playabilityStatus'];
    if (playability is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music player response has no playability status.',
      );
    }
    final status = _text(playability['status']);
    if (status == null) {
      throw const InnerTubeFormatException(
        'YouTube Music player response has an invalid playability status.',
      );
    }
    if (status != 'OK') {
      return null;
    }

    final details = payload['videoDetails'];
    if (details is! Map) {
      throw const InnerTubeFormatException(
        'YouTube Music player response has no video details.',
      );
    }
    final returnedVideoId = _text(details['videoId']);
    if (returnedVideoId == null || returnedVideoId != expectedVideoId) {
      throw const InnerTubeFormatException(
        'YouTube Music player response has an unexpected video ID.',
      );
    }
    final title = _text(details['title']);
    if (title == null) {
      throw const InnerTubeFormatException(
        'YouTube Music player response has no track title.',
      );
    }
    if (!_isMusic(payload, details)) {
      return null;
    }

    final author = _text(details['author']);
    return InnerTubeSong(
      videoId: returnedVideoId,
      title: title,
      artists: author == null ? const [] : <String>[author],
      album: null,
      duration: _duration(details['lengthSeconds']),
      thumbnailUrl: _thumbnailUrl(details['thumbnail']),
    );
  }

  Duration? _duration(Object? value) {
    if (value == null) {
      return null;
    }
    final seconds = value is int
        ? value
        : int.tryParse(value.toString().trim());
    if (seconds == null || seconds <= 0) {
      return null;
    }
    return Duration(seconds: seconds);
  }

  bool _isMusic(Map<dynamic, dynamic> payload, Map<dynamic, dynamic> details) {
    final musicVideoType = _text(details['musicVideoType']);
    if (musicVideoType != null && _musicVideoTypes.contains(musicVideoType)) {
      return true;
    }

    final microformat = payload['microformat'];
    if (microformat is! Map) {
      return false;
    }
    final renderer = microformat['playerMicroformatRenderer'];
    if (renderer is! Map) {
      return false;
    }
    return _text(renderer['category'])?.toLowerCase() == 'music';
  }

  String? _thumbnailUrl(Object? value) {
    if (value is! Map) {
      return null;
    }
    final thumbnails = value['thumbnails'];
    if (thumbnails is! List) {
      return null;
    }

    String? selectedUrl;
    var selectedArea = -1;
    for (final candidate in thumbnails) {
      if (candidate is! Map) {
        continue;
      }
      var url = _text(candidate['url']);
      if (url == null) {
        continue;
      }
      if (url.startsWith('//')) {
        url = 'https:$url';
      }
      final width = _integer(candidate['width']) ?? 0;
      final height = _integer(candidate['height']) ?? 0;
      final area = width * height;
      if (area >= selectedArea) {
        selectedArea = area;
        selectedUrl = url;
      }
    }
    return selectedUrl;
  }

  String? _text(Object? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.toString().trim();
    return normalized.isEmpty ? null : normalized;
  }

  int? _integer(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static const Set<String> _musicVideoTypes = <String>{
    'MUSIC_VIDEO_TYPE_ATV',
    'MUSIC_VIDEO_TYPE_OMV',
    'MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC',
  };
}
