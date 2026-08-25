import 'dart:async';
import 'dart:developer' as developer;

import 'youtube_music_account_models.dart';
import 'youtube_music_account_parser.dart';
import 'youtube_music_account_transport.dart';

abstract final class YouTubeMusicAccountEndpoints {
  static const String accountMenu = 'account/account_menu';
  static const String accountsList = 'account/accounts_list';
  static const String browse = 'browse';
  static const String createPlaylist = 'playlist/create';
  static const String editPlaylist = 'browse/edit_playlist';
  static const String deletePlaylist = 'playlist/delete';
  static const String like = 'like/like';
  static const String removeLike = 'like/removelike';
  static const String subscribe = 'subscription/subscribe';
  static const String unsubscribe = 'subscription/unsubscribe';
}

abstract interface class YouTubeMusicArtistAccount {
  Future<RemoteArtistSubscriptionState?> getArtistSubscriptionState(
    String artistBrowseId,
  );

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  subscribeArtist(String channelId);

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  unsubscribeArtist(String channelId);
}

abstract interface class YouTubeMusicSubscribedArtistsAccount {
  Future<RemoteSubscribedArtistCollection> getSubscribedArtists();
}

/// Narrow authenticated read port for the YouTube Music Home feed.
///
/// The initial browse id is intentionally fixed to `FEmusic_home`; callers
/// cannot use this boundary to dispatch arbitrary authenticated browse reads.
abstract interface class YouTubeMusicAccountHome {
  Future<Object?> readMusicHomePage({String? continuation});
}

/// Authenticated, storage-independent YouTube Music account gateway.
///
/// Reads have bounded transient retries. Mutations are sent exactly once:
/// uncertain delivery is surfaced as [YouTubeMusicMutationAmbiguous], allowing
/// the caller to reconcile with a read before deciding whether to retry.
class YouTubeMusicAccountGateway
    implements
        YouTubeMusicArtistAccount,
        YouTubeMusicSubscribedArtistsAccount,
        YouTubeMusicAccountHome {
  factory YouTubeMusicAccountGateway({
    required YouTubeMusicAccountTransport transport,
    required YouTubeMusicSessionHeadersProvider sessionHeaders,
    required Map<String, Object?> clientContext,
    YouTubeMusicAccountParser parser = const YouTubeMusicAccountParser(),
    YouTubeMusicAccountReadRetryPolicy readRetryPolicy =
        const YouTubeMusicAccountReadRetryPolicy(),
    YouTubeMusicAccountRetryDelay retryDelay =
        defaultYouTubeMusicAccountRetryDelay,
    Duration requestTimeout = const Duration(seconds: 12),
    int maxReadPages = 40,
  }) {
    if (clientContext.isEmpty) {
      throw ArgumentError.value(
        clientContext,
        'clientContext',
        'Must contain the current InnerTube client context.',
      );
    }
    if (requestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        requestTimeout,
        'requestTimeout',
        'Must be positive.',
      );
    }
    if (maxReadPages < 1) {
      throw RangeError.range(maxReadPages, 1, null, 'maxReadPages');
    }
    return YouTubeMusicAccountGateway._(
      transport,
      sessionHeaders,
      clientContext,
      parser,
      readRetryPolicy,
      retryDelay,
      requestTimeout,
      maxReadPages,
    );
  }

  YouTubeMusicAccountGateway._(
    this._transport,
    this._sessionHeaders,
    Map<String, Object?> clientContext,
    this._parser,
    this._readRetryPolicy,
    this._retryDelay,
    this._requestTimeout,
    this._maxReadPages,
  ) : _clientContext = Map<String, Object?>.unmodifiable(clientContext);

  final YouTubeMusicAccountTransport _transport;
  final YouTubeMusicSessionHeadersProvider _sessionHeaders;
  final Map<String, Object?> _clientContext;
  final YouTubeMusicAccountParser _parser;
  final YouTubeMusicAccountReadRetryPolicy _readRetryPolicy;
  final YouTubeMusicAccountRetryDelay _retryDelay;
  final Duration _requestTimeout;
  final int _maxReadPages;

  Future<RemoteAccountProfile?> getProfile() async {
    final response = await _read(
      YouTubeMusicAccountEndpoints.accountMenu,
      _body(),
    );
    return _parser.parseProfile(response.body);
  }

  Future<RemoteAccountDirectory> getAccounts() async {
    final response = await _read(
      YouTubeMusicAccountEndpoints.accountsList,
      _body(<String, Object?>{
        'requestType': 'ACCOUNTS_LIST_REQUEST_TYPE_CHANNEL_SWITCHER',
        'callCircumstance': 'SWITCHING_USERS_FULL',
      }),
    );
    return _parser.parseAccountDirectory(response.body);
  }

  @override
  Future<Object?> readMusicHomePage({String? continuation}) async {
    final normalizedContinuation = _optionalContinuation(continuation);
    final response = await _read(
      YouTubeMusicAccountEndpoints.browse,
      _body(<String, Object?>{
        if (normalizedContinuation == null)
          'browseId': 'FEmusic_home'
        else
          'continuation': normalizedContinuation,
      }),
    );
    return response.body;
  }

  Future<RemotePlaylistCollection> getSavedPlaylists() async {
    final playlists = <String, RemotePlaylistSummary>{};
    final requestedContinuations = <String>{};
    var pagesFetched = 0;
    var response = await _read(
      YouTubeMusicAccountEndpoints.browse,
      _body(const <String, Object?>{'browseId': 'FEmusic_liked_playlists'}),
    );

    while (true) {
      pagesFetched += 1;
      for (final playlist in _parser.parsePlaylistSummaries(response.body)) {
        playlists.putIfAbsent(playlist.playlistId, () => playlist);
      }

      final continuationTokens = _parser.parseSavedPlaylistContinuationTokens(
        response.body,
      );
      final continuation = _nextContinuation(
        continuationTokens,
        requestedContinuations,
      );
      if (continuation == null) {
        return RemotePlaylistCollection(
          playlists: playlists.values.toList(growable: false),
          termination: continuationTokens.isNotEmpty
              ? RemotePaginationTermination.repeatedContinuation
              : RemotePaginationTermination.exhausted,
          pagesFetched: pagesFetched,
        );
      }
      if (pagesFetched >= _maxReadPages) {
        return RemotePlaylistCollection(
          playlists: playlists.values.toList(growable: false),
          termination: RemotePaginationTermination.pageLimit,
          pagesFetched: pagesFetched,
        );
      }

      requestedContinuations.add(continuation);
      response = await _read(
        YouTubeMusicAccountEndpoints.browse,
        _body(<String, Object?>{'continuation': continuation}),
      );
    }
  }

  /// Reads artists explicitly followed by the active YouTube Music account.
  ///
  /// This is deliberately different from the library's "track artists"
  /// projection: `FEmusic_library_corpus_artists` is the subscriptions shelf,
  /// so an artist appears here only after a subscribe mutation succeeds.
  @override
  Future<RemoteSubscribedArtistCollection> getSubscribedArtists() async {
    final artists = <String, RemoteSubscribedArtist>{};
    final requestedContinuations = <String>{};
    var pagesFetched = 0;
    var response = await _read(
      YouTubeMusicAccountEndpoints.browse,
      _body(const <String, Object?>{
        'browseId': 'FEmusic_library_corpus_artists',
      }),
    );

    while (true) {
      pagesFetched += 1;
      for (final artist in _parser.parseSubscribedArtists(response.body)) {
        artists.putIfAbsent(artist.identity, () => artist);
      }

      final continuationTokens = _parser
          .parseSubscribedArtistContinuationTokens(response.body);
      final continuation = _nextContinuation(
        continuationTokens,
        requestedContinuations,
      );
      if (continuation == null) {
        return RemoteSubscribedArtistCollection(
          artists: artists.values.toList(growable: false),
          termination: continuationTokens.isNotEmpty
              ? RemotePaginationTermination.repeatedContinuation
              : RemotePaginationTermination.exhausted,
          pagesFetched: pagesFetched,
        );
      }
      if (pagesFetched >= _maxReadPages) {
        return RemoteSubscribedArtistCollection(
          artists: artists.values.toList(growable: false),
          termination: RemotePaginationTermination.pageLimit,
          pagesFetched: pagesFetched,
        );
      }

      requestedContinuations.add(continuation);
      response = await _read(
        YouTubeMusicAccountEndpoints.browse,
        _body(<String, Object?>{'continuation': continuation}),
      );
    }
  }

  Future<RemotePlaylistSnapshot> getPlaylist(String playlistId) async {
    final normalizedPlaylistId = _requiredPlaylistId(playlistId);
    final entries = <RemotePlaylistEntry>[];
    final requestedContinuations = <String>{};
    RemotePlaylistSummary? summary;
    var pagesFetched = 0;
    var response = await _read(
      YouTubeMusicAccountEndpoints.browse,
      _body(<String, Object?>{'browseId': 'VL$normalizedPlaylistId'}),
    );

    while (true) {
      pagesFetched += 1;
      summary ??= _parser.parsePlaylistHeader(
        response.body,
        playlistId: normalizedPlaylistId,
      );
      entries.addAll(
        _parser.parsePlaylistEntries(
          response.body,
          startingPosition: entries.length,
        ),
      );

      final continuationTokens = _parser.parsePlaylistEntryContinuationTokens(
        response.body,
      );
      final continuation = _nextContinuation(
        continuationTokens,
        requestedContinuations,
      );
      if (continuation == null) {
        return RemotePlaylistSnapshot(
          playlistId: normalizedPlaylistId,
          summary: summary,
          entries: entries,
          termination: continuationTokens.isNotEmpty
              ? RemotePaginationTermination.repeatedContinuation
              : RemotePaginationTermination.exhausted,
          pagesFetched: pagesFetched,
        );
      }
      if (pagesFetched >= _maxReadPages) {
        return RemotePlaylistSnapshot(
          playlistId: normalizedPlaylistId,
          summary: summary,
          entries: entries,
          termination: RemotePaginationTermination.pageLimit,
          pagesFetched: pagesFetched,
        );
      }

      requestedContinuations.add(continuation);
      response = await _read(
        YouTubeMusicAccountEndpoints.browse,
        _body(<String, Object?>{'continuation': continuation}),
      );
    }
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistCreated>> createPlaylist(
    String title, {
    RemotePlaylistVisibility visibility = RemotePlaylistVisibility.private,
    List<String> initialVideoIds = const <String>[],
  }) async {
    final normalizedTitle = _requiredValue(title, 'title');
    final normalizedVideoIds = initialVideoIds
        .map((videoId) => _requiredValue(videoId, 'initialVideoIds'))
        .toList(growable: false);
    return _mutate<RemotePlaylistCreated>(
      endpoint: YouTubeMusicAccountEndpoints.createPlaylist,
      operation: 'createPlaylist',
      body: _body(<String, Object?>{
        'title': normalizedTitle,
        'privacyStatus': _privacyStatus(visibility),
        if (normalizedVideoIds.isNotEmpty) 'videoIds': normalizedVideoIds,
      }),
      parseSuccess: (response) {
        final playlistId = _parser.parseCreatedPlaylistId(response.body);
        return playlistId == null || playlistId.isEmpty
            ? null
            : RemotePlaylistCreated(playlistId: playlistId);
      },
    );
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  addPlaylistEntry({required String playlistId, required String videoId}) {
    return _editPlaylist(
      operation: 'addPlaylistEntry',
      playlistId: playlistId,
      action: <String, Object?>{
        'action': 'ACTION_ADD_VIDEO',
        'addedVideoId': _requiredValue(videoId, 'videoId'),
      },
    );
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  removePlaylistEntry({
    required String playlistId,
    required RemotePlaylistEntry entry,
  }) {
    final videoId = entry.videoId;
    final setVideoId = entry.setVideoId;
    if (videoId == null || videoId.trim().isEmpty) {
      throw ArgumentError.value(
        videoId,
        'entry.videoId',
        'A remote video id is required to remove this occurrence.',
      );
    }
    if (setVideoId == null || setVideoId.trim().isEmpty) {
      throw ArgumentError.value(
        setVideoId,
        'entry.setVideoId',
        'A setVideoId is required to remove a specific occurrence.',
      );
    }
    return _editPlaylist(
      operation: 'removePlaylistEntry',
      playlistId: playlistId,
      action: <String, Object?>{
        'action': 'ACTION_REMOVE_VIDEO',
        'setVideoId': setVideoId.trim(),
        'removedVideoId': videoId.trim(),
      },
    );
  }

  /// Sets the authenticated account's like state for one video.
  ///
  /// This is intentionally separate from playlist edits: YouTube Music's
  /// `LM`/`VLLM` collection is a projection of these likes and rejects
  /// `browse/edit_playlist` mutations for many accounts/channels.
  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>> likeVideo(
    String videoId,
  ) {
    return _mutate<RemotePlaylistMutationApplied>(
      endpoint: YouTubeMusicAccountEndpoints.like,
      operation: 'likeVideo',
      body: _body(<String, Object?>{
        'target': <String, Object?>{
          'videoId': _requiredValue(videoId, 'videoId'),
        },
      }),
      parseSuccess: (_) => const RemotePlaylistMutationApplied(),
    );
  }

  /// Removes the authenticated account's like for one video.
  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>> removeLike(
    String videoId,
  ) {
    return _mutate<RemotePlaylistMutationApplied>(
      endpoint: YouTubeMusicAccountEndpoints.removeLike,
      operation: 'removeLike',
      body: _body(<String, Object?>{
        'target': <String, Object?>{
          'videoId': _requiredValue(videoId, 'videoId'),
        },
      }),
      parseSuccess: (_) => const RemotePlaylistMutationApplied(),
    );
  }

  @override
  Future<RemoteArtistSubscriptionState?> getArtistSubscriptionState(
    String artistBrowseId,
  ) async {
    final normalizedBrowseId = _requiredArtistBrowseId(artistBrowseId);
    final response = await _read(
      YouTubeMusicAccountEndpoints.browse,
      _body(<String, Object?>{'browseId': normalizedBrowseId}),
    );
    return _parseArtistSubscriptionState(
      response.body,
      fallbackChannelId: normalizedBrowseId.startsWith('UC')
          ? normalizedBrowseId
          : null,
    );
  }

  @override
  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  subscribeArtist(String channelId) {
    final normalizedChannelId = _requiredChannelId(channelId);
    return _mutate<RemotePlaylistMutationApplied>(
      endpoint: YouTubeMusicAccountEndpoints.subscribe,
      operation: 'subscribeArtist',
      body: _body(<String, Object?>{
        'channelIds': <String>[normalizedChannelId],
      }),
      parseSuccess: (_) => const RemotePlaylistMutationApplied(),
    );
  }

  @override
  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  unsubscribeArtist(String channelId) {
    final normalizedChannelId = _requiredChannelId(channelId);
    return _mutate<RemotePlaylistMutationApplied>(
      endpoint: YouTubeMusicAccountEndpoints.unsubscribe,
      operation: 'unsubscribeArtist',
      body: _body(<String, Object?>{
        'channelIds': <String>[normalizedChannelId],
      }),
      parseSuccess: (_) => const RemotePlaylistMutationApplied(),
    );
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  movePlaylistEntry({
    required String playlistId,
    required String setVideoId,
    String? successorSetVideoId,
  }) {
    return _editPlaylist(
      operation: 'movePlaylistEntry',
      playlistId: playlistId,
      action: <String, Object?>{
        'action': 'ACTION_MOVE_VIDEO_BEFORE',
        'setVideoId': _requiredValue(setVideoId, 'setVideoId'),
        'movedSetVideoIdSuccessor': successorSetVideoId == null
            ? null
            : _requiredValue(successorSetVideoId, 'successorSetVideoId'),
      },
    );
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  renamePlaylist({required String playlistId, required String title}) {
    return _editPlaylist(
      operation: 'renamePlaylist',
      playlistId: playlistId,
      action: <String, Object?>{
        'action': 'ACTION_SET_PLAYLIST_NAME',
        'playlistName': _requiredValue(title, 'title'),
      },
    );
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  setPlaylistDescription({
    required String playlistId,
    required String description,
  }) {
    return _editPlaylist(
      operation: 'setPlaylistDescription',
      playlistId: playlistId,
      action: <String, Object?>{
        'action': 'ACTION_SET_PLAYLIST_DESCRIPTION',
        // Empty is valid and clears the existing description.
        'playlistDescription': description.trim(),
      },
    );
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  deletePlaylist(String playlistId) {
    return _mutate<RemotePlaylistMutationApplied>(
      endpoint: YouTubeMusicAccountEndpoints.deletePlaylist,
      operation: 'deletePlaylist',
      body: _body(<String, Object?>{
        'playlistId': _requiredPlaylistId(playlistId),
      }),
      parseSuccess: (_) => const RemotePlaylistMutationApplied(),
    );
  }

  Future<YouTubeMusicMutationResult<RemotePlaylistMutationApplied>>
  _editPlaylist({
    required String operation,
    required String playlistId,
    required Map<String, Object?> action,
  }) {
    return _mutate<RemotePlaylistMutationApplied>(
      endpoint: YouTubeMusicAccountEndpoints.editPlaylist,
      operation: operation,
      body: _body(<String, Object?>{
        'playlistId': _requiredPlaylistId(playlistId),
        'actions': <Object>[action],
      }),
      parseSuccess: (_) => const RemotePlaylistMutationApplied(),
    );
  }

  Map<String, Object?> _body([
    Map<String, Object?> values = const <String, Object?>{},
  ]) {
    return <String, Object?>{'context': _clientContext, ...values};
  }

  Future<YouTubeMusicAccountResponse> _read(
    String endpoint,
    Map<String, Object?> body,
  ) async {
    for (var attempt = 1; attempt <= _readRetryPolicy.maxAttempts; attempt++) {
      try {
        final headers = await _sessionHeaders.headersFor(
          YouTubeMusicSessionHeaderRequest(
            endpoint: endpoint,
            kind: YouTubeMusicAccountRequestKind.read,
          ),
        );
        final response = await _transport.send(
          YouTubeMusicAccountRequest(
            endpoint: endpoint,
            kind: YouTubeMusicAccountRequestKind.read,
            headers: headers.toTransportMap(),
            body: body,
            timeout: _requestTimeout,
            apiKey: headers.apiKey,
          ),
        );
        if (_isSuccess(response.statusCode)) {
          return response;
        }
        developer.log(
          'YouTube Music account read rejected: endpoint=$endpoint '
          'status=${response.statusCode} attempt=$attempt',
          name: 'bstream.youtube_music.auth',
        );
        if (attempt < _readRetryPolicy.maxAttempts &&
            _readRetryPolicy.shouldRetryStatus(response.statusCode)) {
          await _retryDelay(_readRetryPolicy.delayForRetry(attempt));
          continue;
        }
        throw YouTubeMusicAccountException(
          'Authenticated YouTube Music read failed.',
          statusCode: response.statusCode,
        );
      } on YouTubeMusicAccountTransportException catch (error) {
        developer.log(
          'YouTube Music account transport failed: endpoint=$endpoint '
          'delivery=${error.delivery} retryable=${error.retryableForRead}',
          name: 'bstream.youtube_music.auth',
        );
        if (attempt < _readRetryPolicy.maxAttempts && error.retryableForRead) {
          await _retryDelay(_readRetryPolicy.delayForRetry(attempt));
          continue;
        }
        throw const YouTubeMusicAccountException(
          'Authenticated YouTube Music transport failed.',
        );
      } on TimeoutException {
        if (attempt < _readRetryPolicy.maxAttempts) {
          await _retryDelay(_readRetryPolicy.delayForRetry(attempt));
          continue;
        }
        throw const YouTubeMusicAccountException(
          'Authenticated YouTube Music read timed out.',
        );
      }
    }
    throw StateError('Unreachable read retry state.');
  }

  Future<YouTubeMusicMutationResult<T>> _mutate<T>({
    required String endpoint,
    required String operation,
    required Map<String, Object?> body,
    required T? Function(YouTubeMusicAccountResponse response) parseSuccess,
  }) async {
    late final YouTubeMusicSessionHeaders headers;
    try {
      headers = await _sessionHeaders.headersFor(
        YouTubeMusicSessionHeaderRequest(
          endpoint: endpoint,
          kind: YouTubeMusicAccountRequestKind.mutation,
        ),
      );
    } on Object {
      return YouTubeMusicMutationFailure<T>(
        operation: operation,
        reason: 'No se pudieron preparar los encabezados de sesión.',
      );
    }

    try {
      final response = await _transport.send(
        YouTubeMusicAccountRequest(
          endpoint: endpoint,
          kind: YouTubeMusicAccountRequestKind.mutation,
          headers: headers.toTransportMap(),
          body: body,
          timeout: _requestTimeout,
          apiKey: headers.apiKey,
        ),
      );
      if (!_isSuccess(response.statusCode)) {
        if (_isAmbiguousMutationStatus(response.statusCode)) {
          return YouTubeMusicMutationAmbiguous<T>(
            operation: operation,
            reason: 'YouTube no confirmó si aplicó la operación.',
            statusCode: response.statusCode,
          );
        }
        return YouTubeMusicMutationFailure<T>(
          operation: operation,
          reason: 'YouTube rechazó la operación.',
          statusCode: response.statusCode,
        );
      }
      final value = parseSuccess(response);
      if (value == null) {
        return YouTubeMusicMutationAmbiguous<T>(
          operation: operation,
          reason: 'La respuesta no permitió confirmar el resultado.',
          statusCode: response.statusCode,
        );
      }
      return YouTubeMusicMutationSuccess<T>(value);
    } on YouTubeMusicAccountTransportException catch (error) {
      if (error.delivery == YouTubeMusicRequestDelivery.notSent) {
        return YouTubeMusicMutationFailure<T>(
          operation: operation,
          reason: 'La operación no llegó a enviarse.',
        );
      }
      return YouTubeMusicMutationAmbiguous<T>(
        operation: operation,
        reason: 'La conexión se perdió sin confirmar la operación.',
      );
    } on Object {
      // Unknown transport implementations may throw after writing request
      // bytes. Be conservative and require reconciliation instead of retrying.
      return YouTubeMusicMutationAmbiguous<T>(
        operation: operation,
        reason: 'No fue posible confirmar la operación.',
      );
    }
  }

  String? _nextContinuation(
    Iterable<String> tokens,
    Set<String> alreadyRequested,
  ) {
    for (final token in tokens) {
      if (!alreadyRequested.contains(token)) {
        return token;
      }
    }
    return null;
  }
}

bool _isSuccess(int statusCode) => statusCode >= 200 && statusCode < 300;

bool _isAmbiguousMutationStatus(int statusCode) {
  return statusCode == 408 ||
      statusCode == 425 ||
      statusCode == 429 ||
      statusCode >= 500;
}

String _requiredPlaylistId(String playlistId) {
  final normalized = canonicalPlaylistId(
    _requiredValue(playlistId, 'playlistId'),
  );
  if (normalized.isEmpty || normalized.startsWith('FE')) {
    throw ArgumentError.value(
      playlistId,
      'playlistId',
      'Must be a concrete playlist id.',
    );
  }
  return normalized;
}

String? _optionalContinuation(String? continuation) {
  final normalized = continuation?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized.length > 8192 ||
      normalized.contains(RegExp(r'[\x00-\x1F\x7F]'))) {
    throw ArgumentError.value(
      continuation,
      'continuation',
      'Must be a bounded continuation token.',
    );
  }
  return normalized;
}

String _requiredArtistBrowseId(String artistBrowseId) {
  final normalized = _requiredValue(artistBrowseId, 'artistBrowseId');
  if (normalized.length > 256 ||
      !RegExp(r'^(?:UC|MPLA)[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(
      artistBrowseId,
      'artistBrowseId',
      'Must be a concrete YouTube Music artist browse id.',
    );
  }
  return normalized;
}

String _requiredChannelId(String channelId) {
  final normalized = _requiredValue(channelId, 'channelId');
  if (normalized.length > 256 ||
      !RegExp(r'^UC[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(
      channelId,
      'channelId',
      'Must be a concrete YouTube channel id.',
    );
  }
  return normalized;
}

RemoteArtistSubscriptionState? _parseArtistSubscriptionState(
  Object? node, {
  String? fallbackChannelId,
}) {
  if (node is Map) {
    for (final rendererName in const <String>[
      'subscribeButtonRenderer',
      'musicSubscribeButtonRenderer',
    ]) {
      final renderer = node[rendererName];
      if (renderer is! Map) continue;
      final channelId = _subscriptionChannelId(renderer) ?? fallbackChannelId;
      final subscribed = renderer['subscribed'];
      if (channelId != null && subscribed is bool) {
        return RemoteArtistSubscriptionState(
          channelId: channelId,
          isSubscribed: subscribed,
        );
      }
    }
    for (final value in node.values) {
      final result = _parseArtistSubscriptionState(
        value,
        fallbackChannelId: fallbackChannelId,
      );
      if (result != null) return result;
    }
  } else if (node is List) {
    for (final value in node) {
      final result = _parseArtistSubscriptionState(
        value,
        fallbackChannelId: fallbackChannelId,
      );
      if (result != null) return result;
    }
  }
  return null;
}

String? _subscriptionChannelId(Object? node) {
  if (node is Map) {
    final direct = node['channelId']?.toString().trim();
    if (direct != null && RegExp(r'^UC[A-Za-z0-9_-]+$').hasMatch(direct)) {
      return direct;
    }
    final browse = node['browseEndpoint'];
    if (browse is Map) {
      final browseId = browse['browseId']?.toString().trim();
      if (browseId != null &&
          RegExp(r'^UC[A-Za-z0-9_-]+$').hasMatch(browseId)) {
        return browseId;
      }
    }
    for (final value in node.values) {
      final channelId = _subscriptionChannelId(value);
      if (channelId != null) return channelId;
    }
  } else if (node is List) {
    for (final value in node) {
      final channelId = _subscriptionChannelId(value);
      if (channelId != null) return channelId;
    }
  }
  return null;
}

String _requiredValue(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'Must not be empty.');
  }
  return normalized;
}

String _privacyStatus(RemotePlaylistVisibility visibility) {
  return switch (visibility) {
    RemotePlaylistVisibility.private => 'PRIVATE',
    RemotePlaylistVisibility.unlisted => 'UNLISTED',
    RemotePlaylistVisibility.public => 'PUBLIC',
    RemotePlaylistVisibility.unknown => throw ArgumentError.value(
      visibility,
      'visibility',
      'A concrete visibility is required when creating a playlist.',
    ),
  };
}
