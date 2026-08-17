import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'innertube_exceptions.dart';
import 'innertube_models.dart';
import 'innertube_transport.dart';

export 'innertube_exceptions.dart';
export 'innertube_models.dart';
export 'innertube_transport.dart';

/// Maximum number of songs resolved for an album, playlist, or generated mix.
///
/// Catalog searches deliberately keep their smaller 20-result limit; detail
/// pages opt into this separate bound so a large response is not truncated by
/// the discovery limit.
const int innerTubeDetailResultLimit = 100;

abstract interface class YouTubeMusicSearch {
  Future<List<InnerTubeSong>> searchSongs(String query, {int limit = 20});
}

abstract interface class YouTubeMusicCatalogSearch {
  Future<List<InnerTubeSong>> searchVideos(String query, {int limit = 20});

  Future<List<InnerTubeAlbum>> searchAlbums(String query, {int limit = 20});
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

abstract interface class YouTubeMusicAlbumLookup {
  Future<List<InnerTubeSong>> getAlbumSongs(
    String browseId, {
    int limit = innerTubeDetailResultLimit,
  });
}

class InnerTubeSearchService
    implements
        YouTubeMusicSearch,
        YouTubeMusicCatalogSearch,
        YouTubeMusicTrackLookup,
        YouTubeMusicHome,
        YouTubeMusicCollectionLookup,
        YouTubeMusicAlbumLookup {
  factory InnerTubeSearchService({
    InnerTubeTransport? transport,
    InnerTubeSearchParser parser = const InnerTubeSearchParser(),
    InnerTubeAlbumParser albumParser = const InnerTubeAlbumParser(),
    InnerTubeHomeParser homeParser = const InnerTubeHomeParser(),
    InnerTubePlayerParser playerParser = const InnerTubePlayerParser(),
    InnerTubeBootstrapParser bootstrapParser = const InnerTubeBootstrapParser(),
    Uri? endpoint,
    Uri? browseEndpoint,
    Uri? playerEndpoint,
    Uri? bootstrapUri,
    String language = 'es-419',
    String region = 'NI',
    String userAgent = defaultUserAgent,
    Duration requestTimeout = const Duration(seconds: 10),
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
      parser: parser,
      albumParser: albumParser,
      homeParser: homeParser,
      playerParser: playerParser,
      bootstrapParser: bootstrapParser,
      endpoint:
          endpoint ?? Uri.parse('https://music.youtube.com/youtubei/v1/search'),
      browseEndpoint:
          browseEndpoint ??
          Uri.parse('https://music.youtube.com/youtubei/v1/browse'),
      playerEndpoint:
          playerEndpoint ??
          Uri.parse('https://music.youtube.com/youtubei/v1/player'),
      bootstrapUri: bootstrapUri ?? Uri.parse('https://music.youtube.com/'),
      language: normalizedLanguage,
      region: normalizedRegion,
      userAgent: normalizedUserAgent,
      requestTimeout: requestTimeout,
    );
  }

  InnerTubeSearchService._({
    required InnerTubeTransport transport,
    required InnerTubeSearchParser parser,
    required InnerTubeAlbumParser albumParser,
    required InnerTubeHomeParser homeParser,
    required InnerTubePlayerParser playerParser,
    required InnerTubeBootstrapParser bootstrapParser,
    required Uri endpoint,
    required Uri browseEndpoint,
    required Uri playerEndpoint,
    required Uri bootstrapUri,
    required String language,
    required String region,
    required String userAgent,
    required Duration requestTimeout,
  }) : this._initialized(
         transport,
         parser,
         albumParser,
         homeParser,
         playerParser,
         bootstrapParser,
         endpoint,
         browseEndpoint,
         playerEndpoint,
         bootstrapUri,
         language,
         region,
         userAgent,
         requestTimeout,
       );

  InnerTubeSearchService._initialized(
    this._transport,
    this._parser,
    this._albumParser,
    this._homeParser,
    this._playerParser,
    this._bootstrapParser,
    this._endpoint,
    this._browseEndpoint,
    this._playerEndpoint,
    this._bootstrapUri,
    this._language,
    this._region,
    this._userAgent,
    this._requestTimeout,
  );

  static const int maxResults = 20;
  static const int maxDetailResults = innerTubeDetailResultLimit;
  static const int maxHomeSections = 6;
  static const int _maxHomeContinuationRequests = 1;
  static const int maxDetailContinuationRequests = 4;
  static const String songsFilter = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';
  static const String videosFilter = 'EgWKAQIQAWoMEA4QChADEAQQCRAF';
  static const String albumsFilter = 'EgWKAQIYAWoMEA4QChADEAQQCRAF';
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/140.0.0.0 Safari/537.36';

  final InnerTubeTransport _transport;
  final InnerTubeSearchParser _parser;
  final InnerTubeAlbumParser _albumParser;
  final InnerTubeHomeParser _homeParser;
  final InnerTubePlayerParser _playerParser;
  final InnerTubeBootstrapParser _bootstrapParser;
  final Uri _endpoint;
  final Uri _browseEndpoint;
  final Uri _playerEndpoint;
  final Uri _bootstrapUri;
  final String _language;
  final String _region;
  final String _userAgent;
  final Duration _requestTimeout;

  bool _disposed = false;
  Future<InnerTubeConfiguration>? _configurationFuture;

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

  Future<Object?> _searchCatalog(String query, {required String filter}) async {
    var configuration = await _configuration();
    var response = await _requestSearch(query, filter, configuration);
    if (_needsFreshConfiguration(response.statusCode)) {
      _configurationFuture = null;
      configuration = await _configuration();
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
      _configurationFuture = null;
      configuration = await _configuration();
      response = await _requestBrowse(configuration, browseId: 'FEmusic_home');
    }

    var decoded = _decodeHomeResponse(response);
    final sections = <InnerTubeHomeSection>[];
    final seenVideoIds = <String>{};
    final seenBrowseIds = <String>{};
    sections.addAll(
      _homeParser._parse(
        decoded,
        maxSections: maxSections,
        maxItemsPerSection: maxItemsPerSection,
        seenVideoIds: seenVideoIds,
        seenBrowseIds: seenBrowseIds,
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
          _configurationFuture = null;
          configuration = await _configuration();
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
    return _getDetailSongs(
      browseId: normalizedBrowseId,
      limit: limit,
      isAlbum: false,
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
    return _getDetailSongs(
      browseId: normalizedBrowseId,
      limit: limit,
      isAlbum: true,
    );
  }

  Future<List<InnerTubeSong>> _getDetailSongs({
    required String browseId,
    required int limit,
    required bool isAlbum,
  }) async {
    var configuration = await _configuration();
    var response = await _requestBrowse(configuration, browseId: browseId);
    if (_needsFreshConfiguration(response.statusCode)) {
      _configurationFuture = null;
      configuration = await _configuration();
      response = await _requestBrowse(configuration, browseId: browseId);
    }

    var decoded = _decodeDetailResponse(response);
    final songs = <InnerTubeSong>[];
    final seenVideoIds = <String>{};
    String? fallbackAlbumTitle;
    var fallbackAlbumArtists = const <String>[];

    void addPage(Object? payload) {
      final List<InnerTubeSong> pageSongs;
      if (isAlbum) {
        final page = _albumParser._parseSongPage(
          payload,
          limit: maxDetailResults,
          fallbackAlbumTitle: fallbackAlbumTitle,
          fallbackAlbumArtists: fallbackAlbumArtists,
        );
        fallbackAlbumTitle = page.albumTitle;
        fallbackAlbumArtists = page.albumArtists;
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
          _configurationFuture = null;
          configuration = await _configuration();
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
    return List.unmodifiable(songs);
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
    final normalizedVideoId = videoId.trim();
    if (!_videoIdPattern.hasMatch(normalizedVideoId)) {
      throw ArgumentError.value(
        videoId,
        'videoId',
        'Must be an 11-character YouTube video ID.',
      );
    }

    var configuration = await _configuration();
    var response = await _requestPlayer(normalizedVideoId, configuration);
    if (_needsFreshConfiguration(response.statusCode)) {
      _configurationFuture = null;
      configuration = await _configuration();
      response = await _requestPlayer(normalizedVideoId, configuration);
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
    return _playerParser.parse(decoded, expectedVideoId: normalizedVideoId);
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

    late final InnerTubeHttpResponse response;
    try {
      response = await _transport.postJson(
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
      );
    } on TimeoutException {
      throw const InnerTubeTimeoutException();
    } on SocketException catch (error) {
      throw InnerTubeTransportException(error);
    } on HttpException catch (error) {
      throw InnerTubeTransportException(error);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(error.message);
    }

    return response;
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

    late final InnerTubeHttpResponse response;
    try {
      response = await _transport.postJson(
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
      );
    } on TimeoutException {
      throw const InnerTubeTimeoutException();
    } on SocketException catch (error) {
      throw InnerTubeTransportException(error);
    } on HttpException catch (error) {
      throw InnerTubeTransportException(error);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(error.message);
    }

    return response;
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

    try {
      return await _transport.postJson(
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
      );
    } on TimeoutException {
      throw const InnerTubeTimeoutException();
    } on SocketException catch (error) {
      throw InnerTubeTransportException(error);
    } on HttpException catch (error) {
      throw InnerTubeTransportException(error);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(error.message);
    }
  }

  bool _needsFreshConfiguration(int statusCode) {
    return statusCode == HttpStatus.badRequest ||
        statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden;
  }

  Future<InnerTubeConfiguration> _configuration() {
    return _configurationFuture ??= _loadConfiguration().catchError((
      Object error,
    ) {
      _configurationFuture = null;
      throw error;
    });
  }

  Future<InnerTubeConfiguration> _loadConfiguration() async {
    late final InnerTubeHttpResponse response;
    try {
      final uri = _bootstrapUri.replace(
        queryParameters: <String, String>{
          ..._bootstrapUri.queryParameters,
          'hl': _language,
          'gl': _region,
        },
      );
      response = await _transport.get(
        uri,
        headers: <String, String>{
          HttpHeaders.acceptHeader: 'text/html,application/xhtml+xml',
          HttpHeaders.userAgentHeader: _userAgent,
        },
        timeout: _requestTimeout,
      );
    } on TimeoutException {
      throw const InnerTubeTimeoutException();
    } on SocketException catch (error) {
      throw InnerTubeTransportException(error);
    } on HttpException catch (error) {
      throw InnerTubeTransportException(error);
    } on FormatException catch (error) {
      throw InnerTubeFormatException(error.message);
    }
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      throw InnerTubeHttpException(response.statusCode, response.body);
    }
    return _bootstrapParser.parse(response.body);
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
    String? album;
    Duration? duration;
    for (final run in metadataRuns) {
      final text = _text(run['text']);
      if (text == null) {
        continue;
      }
      final pageType = _browsePageType(run);
      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
        final artistText = _artistText(run['text']);
        if (artistText != null && !artists.contains(artistText)) {
          artists.add(artistText);
        }
      } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' && album == null) {
        album = text;
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
        break;
      }
    }

    return InnerTubeSong(
      videoId: videoId,
      title: title,
      artists: artists,
      album: album,
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
    String? album;
    Duration? duration;
    for (final run in metadataRuns) {
      final text = _text(run['text']);
      if (text == null) {
        continue;
      }
      final pageType = _browsePageType(run);
      if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
        final artistText = _artistText(run['text']);
        if (artistText != null && !artists.contains(artistText)) {
          artists.add(artistText);
        }
      } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' && album == null) {
        album = text;
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
        break;
      }
    }

    return InnerTubeSong(
      videoId: videoId,
      title: title,
      artists: artists,
      album: album,
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

  String? _thumbnailUrl(Map<dynamic, dynamic> renderer) {
    final thumbnail = renderer['thumbnail'] ?? renderer['thumbnailRenderer'];
    if (thumbnail is! Map) {
      return null;
    }
    final musicThumbnail = thumbnail['musicThumbnailRenderer'];
    if (musicThumbnail is! Map) {
      return null;
    }
    final thumbnailData = musicThumbnail['thumbnail'];
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
    final headerAlbumArtists = header == null
        ? const <String>[]
        : _headerArtists(header);
    final albumTitle = headerAlbumTitle ?? fallbackAlbumTitle;
    final albumArtists = headerAlbumArtists.isEmpty
        ? fallbackAlbumArtists
        : headerAlbumArtists;
    final trackShelf = _findAlbumTrackShelf(payload);
    final songs = _songParser.parseDetailSongs(
      trackShelf ?? payload,
      limit: limit,
    );
    return _InnerTubeAlbumSongPage(
      albumTitle: albumTitle,
      albumArtists: List.unmodifiable(albumArtists),
      songs: List.unmodifiable(
        songs.map((song) {
          final artists = song.artists
              .map(_songParser._artistText)
              .whereType<String>()
              .toList(growable: false);
          final resolvedArtists = artists.isEmpty ? albumArtists : artists;
          final songAlbum = song.album ?? albumTitle;
          return InnerTubeSong(
            videoId: song.videoId,
            title: song.title,
            artists: resolvedArtists,
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
    final browseId = _findAlbumBrowseId(renderer);
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
      year: metadata.year,
      type: metadata.type,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
      playlistId: _findPlaylistId(renderer),
    );
  }

  InnerTubeAlbum? _parseTwoRowAlbum(Map<dynamic, dynamic> renderer) {
    final title = _textFromRenderer(renderer['title']);
    final browseId = _findAlbumBrowseId(renderer);
    if (title == null || browseId == null) {
      return null;
    }
    final metadata = _parseMetadata(_songParser._runs(renderer['subtitle']));
    return InnerTubeAlbum(
      browseId: browseId,
      title: title,
      artists: metadata.artists,
      year: metadata.year,
      type: metadata.type,
      thumbnailUrl: _songParser._thumbnailUrl(renderer),
      playlistId: _findPlaylistId(renderer),
    );
  }

  _InnerTubeAlbumMetadata _parseMetadata(Iterable<Map<dynamic, dynamic>> runs) {
    final artists = <String>[];
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
        if (artistText != null && !artists.contains(artistText)) {
          artists.add(artistText);
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
        }
      }
    }
    return _InnerTubeAlbumMetadata(
      artists: List.unmodifiable(artists),
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

  List<String> _headerArtists(Map<dynamic, dynamic> header) {
    final artists = <String>[];

    void visit(Object? node) {
      if (node is Map) {
        final text = _songParser._artistText(node['text']);
        if (text != null &&
            _songParser._browsePageType(node) == 'MUSIC_PAGE_TYPE_ARTIST' &&
            !artists.contains(text)) {
          artists.add(text);
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
      return List.unmodifiable(artists);
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
        return List.unmodifiable(artists);
      }
    }
    return const [];
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
    required this.year,
    required this.type,
  });

  final List<String> artists;
  final String? year;
  final String? type;
}

class _InnerTubeAlbumSongPage {
  const _InnerTubeAlbumSongPage({
    required this.songs,
    required this.albumTitle,
    required this.albumArtists,
  });

  final List<InnerTubeSong> songs;
  final String? albumTitle;
  final List<String> albumArtists;
}

class _InnerTubeSongRenderer {
  const _InnerTubeSongRenderer(this.renderer, {required this.isTwoRow});

  final Map<dynamic, dynamic> renderer;
  final bool isTwoRow;
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
    );
  }

  List<InnerTubeHomeSection> _parse(
    Object? payload, {
    required int maxSections,
    required int maxItemsPerSection,
    required Set<String> seenVideoIds,
    required Set<String> seenBrowseIds,
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
          final collection = _parseCollection(twoRow);
          if (collection != null && seenBrowseIds.add(collection.browseId)) {
            items.add(collection);
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

class InnerTubePlayerParser {
  const InnerTubePlayerParser();

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
