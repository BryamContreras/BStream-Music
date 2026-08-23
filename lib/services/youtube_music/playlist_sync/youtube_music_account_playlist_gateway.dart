import '../../../features/music/domain/entities/catalog_track.dart';
import '../account/youtube_music_account.dart' as account;
import 'playlist_sync_models.dart';
import 'youtube_music_playlist_gateway.dart';

/// Adapts the authenticated account boundary to the playlist sync engine.
///
/// The adapter is deliberately bound to one account identity. This prevents a
/// queued sync job from accidentally using a newly selected YouTube channel.
/// Account mutations remain one-shot: an uncertain result is returned to the
/// engine for reconciliation and is never repeated here.
final class YouTubeMusicAccountPlaylistGateway
    implements
        YouTubeMusicPlaylistGateway,
        YouTubeMusicPlaylistCatalogGateway,
        YouTubeMusicLikedMusicGateway {
  factory YouTubeMusicAccountPlaylistGateway({
    required account.YouTubeMusicAccountGateway accountGateway,
    required String accountKey,
    bool Function()? isSessionCurrent,
    void Function()? onAuthenticationExpired,
  }) => YouTubeMusicAccountPlaylistGateway._(
    accountGateway,
    _requiredAccountKey(accountKey),
    isSessionCurrent ?? _alwaysCurrentSession,
    onAuthenticationExpired ?? _ignoreAuthenticationExpiry,
  );

  YouTubeMusicAccountPlaylistGateway._(
    this._accountGateway,
    this._accountKey,
    this._isSessionCurrent,
    this._onAuthenticationExpired,
  );

  final account.YouTubeMusicAccountGateway _accountGateway;
  final String _accountKey;
  final bool Function() _isSessionCurrent;
  final void Function() _onAuthenticationExpired;

  @override
  Future<List<RemotePlaylistSummary>> listRemotePlaylists({
    required String accountKey,
  }) async {
    _verifyAccount(accountKey);
    _verifySession();
    final account.RemotePlaylistCollection collection;
    try {
      collection = await _accountGateway.getSavedPlaylists();
      _verifySession();
    } on account.YouTubeMusicAccountException catch (error) {
      _notifyAuthenticationExpired(error.statusCode);
      rethrow;
    }
    if (!collection.isComplete) {
      throw PlaylistGatewayUnavailableException(
        'YouTube Music devolvió una lista de playlists incompleta '
        '(${collection.termination.name}).',
      );
    }
    // Shelf renderers frequently omit edit markers even for playlists owned
    // by the active account. Treat that absence as unknown; the detail header
    // mapped by fetchPlaylist is authoritative before any write is attempted.
    // LM and VLLM are two browse forms of the same system collection. Keep one
    // canonical summary so the coordinator can bind it to BStream Favorites
    // instead of importing a duplicate ordinary playlist.
    final mapped = <String, RemotePlaylistSummary>{};
    for (final playlist in collection.playlists) {
      if (_isEpisodesForLaterPlaylist(playlist)) {
        continue;
      }
      final remoteId = _canonicalPlaylistId(playlist.playlistId);
      final liked = _isLikedMusicPlaylistId(remoteId);
      mapped.putIfAbsent(
        remoteId,
        () => RemotePlaylistSummary(
          remotePlaylistId: remoteId,
          remoteBrowseId: playlist.browseId,
          title: playlist.title,
          isEditable: true,
          privacy: _privacyName(playlist.visibility),
          isLikedMusic: liked,
        ),
      );
    }
    return mapped.values.toList(growable: false);
  }

  @override
  Future<PlaylistSyncSnapshot?> fetchPlaylist({
    required String accountKey,
    required String remotePlaylistId,
  }) async {
    _verifyAccount(accountKey);
    final normalizedPlaylistId = _requiredPlaylistId(remotePlaylistId);
    try {
      _verifySession();
      final remote = await _accountGateway.getPlaylist(normalizedPlaylistId);
      _verifySession();
      return _toSyncSnapshot(remote);
    } on account.YouTubeMusicAccountException catch (error) {
      _notifyAuthenticationExpired(error.statusCode);
      if (error.statusCode == 404 || error.statusCode == 410) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<RemoteMutationReceipt> createPlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    _verifyAccount(accountKey);
    final title = desired.title.trim();
    if (title.isEmpty) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La playlist necesita un título.',
      );
    }

    final videoIds = <String>[];
    for (final item in desired.remoteProjection.items) {
      final videoId = _normalized(item.videoId);
      if (videoId == null) {
        return const RemoteMutationReceipt(
          status: RemoteMutationStatus.rejected,
          message: 'La playlist contiene una referencia remota inválida.',
        );
      }
      // Do not use a Set: repeated videos are distinct playlist occurrences.
      videoIds.add(videoId);
    }

    try {
      _verifySession();
      final result = await _accountGateway.createPlaylist(
        title,
        visibility: _privacyForCreate(desired.privacy),
        initialVideoIds: videoIds,
      );
      _notifyAuthenticationExpired(_mutationStatusCode(result));
      try {
        _verifySession();
      } on PlaylistGatewayUnavailableException {
        return switch (result) {
          account.YouTubeMusicMutationSuccess<account.RemotePlaylistCreated>(
            :final value,
          ) =>
            RemoteMutationReceipt(
              status: RemoteMutationStatus.ambiguous,
              remotePlaylistId: value.playlistId,
              message:
                  'YouTube creó la playlist, pero la cuenta cambió antes de '
                  'confirmar el estado local.',
            ),
          account.YouTubeMusicMutationAmbiguous<account.RemotePlaylistCreated>(
            :final reason,
          ) =>
            RemoteMutationReceipt(
              status: RemoteMutationStatus.ambiguous,
              message: reason,
            ),
          account.YouTubeMusicMutationFailure<account.RemotePlaylistCreated>(
            :final reason,
          ) =>
            RemoteMutationReceipt(
              status: RemoteMutationStatus.rejected,
              message: reason,
            ),
        };
      }
      return switch (result) {
        account.YouTubeMusicMutationSuccess<account.RemotePlaylistCreated>(
          :final value,
        ) =>
          RemoteMutationReceipt(
            status: RemoteMutationStatus.acknowledged,
            remotePlaylistId: value.playlistId,
          ),
        account.YouTubeMusicMutationAmbiguous<account.RemotePlaylistCreated>(
          :final reason,
        ) =>
          RemoteMutationReceipt(
            status: RemoteMutationStatus.ambiguous,
            message: reason,
          ),
        account.YouTubeMusicMutationFailure<account.RemotePlaylistCreated>(
          :final reason,
        ) =>
          RemoteMutationReceipt(
            status: RemoteMutationStatus.rejected,
            message: reason,
          ),
      };
    } on ArgumentError catch (error) {
      return RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: error.message?.toString(),
      );
    } on Object {
      // A custom transport may throw after request bytes were written.
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.ambiguous,
        message: 'No fue posible confirmar la creación remota.',
      );
    }
  }

  @override
  Future<RemoteMutationReceipt> applyDesiredState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    _verifyAccount(accountKey);
    _verifySession();
    final remotePlaylistId = _normalized(observed.remotePlaylistId);
    if (remotePlaylistId == null) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La playlist remota no tiene un identificador válido.',
      );
    }
    final desiredPlaylistId = _normalized(desired.remotePlaylistId);
    if (desiredPlaylistId != null &&
        _canonicalPlaylistId(desiredPlaylistId) !=
            _canonicalPlaylistId(remotePlaylistId)) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La playlist observada no coincide con la deseada.',
      );
    }
    if (!observed.isEditable) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La playlist remota es de solo lectura.',
      );
    }

    final desiredTitle = desired.title.trim();
    if (desiredTitle.isEmpty) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La playlist necesita un título.',
      );
    }

    final desiredOccurrences = _desiredOccurrences(desired);
    if (desiredOccurrences == null) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La playlist deseada contiene ocurrencias inválidas.',
      );
    }
    if (_sameVideoOrder(desiredOccurrences, observed)) {
      if (desiredTitle == observed.title.trim()) {
        return RemoteMutationReceipt(
          status: RemoteMutationStatus.acknowledged,
          remotePlaylistId: _canonicalPlaylistId(remotePlaylistId),
        );
      }
      final result = await _guardMutation(() async {
        _verifySession();
        return _accountGateway.renamePlaylist(
          playlistId: remotePlaylistId,
          title: desiredTitle,
        );
      });
      _verifySession();
      final stopped = _stoppedReceipt(
        result,
        priorWrite: false,
        onStatusCode: _notifyAuthenticationExpired,
      );
      return stopped ??
          RemoteMutationReceipt(
            status: RemoteMutationStatus.acknowledged,
            remotePlaylistId: _canonicalPlaylistId(remotePlaylistId),
          );
    }
    final observedOccurrences = _observedOccurrences(observed);
    if (observedOccurrences == null) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message:
            'YouTube no proporcionó identificadores suficientes para '
            'editar duplicados de forma segura.',
      );
    }

    final initialMatch = _matchDesired(desiredOccurrences, observedOccurrences);
    final removals = <_RemoteOccurrence>[
      for (var index = 0; index < observedOccurrences.length; index++)
        if (!initialMatch.claimedRemoteIndexes.contains(index))
          observedOccurrences[index],
    ];
    final additions = <_DesiredOccurrence>[
      for (var index = 0; index < desiredOccurrences.length; index++)
        if (initialMatch.remoteIndexByDesired[index] == null)
          desiredOccurrences[index],
    ];

    var wrote = false;
    var working = List<_RemoteOccurrence>.of(observedOccurrences);
    var currentTitle = observed.title.trim();

    // Remove from the end so intermediary ordering stays predictable. Each
    // occurrence is addressed by both videoId and setVideoId; duplicates are
    // never collapsed.
    for (final removal in removals.reversed) {
      final result = await _guardMutation(() async {
        _verifySession();
        return _accountGateway.removePlaylistEntry(
          playlistId: remotePlaylistId,
          entry: removal.toAccountEntry(),
        );
      });
      _verifySession();
      final stopped = _stoppedReceipt(
        result,
        priorWrite: wrote,
        onStatusCode: _notifyAuthenticationExpired,
      );
      if (stopped != null) {
        return stopped;
      }
      wrote = true;
      working.removeWhere((entry) => entry.setVideoId == removal.setVideoId);
    }

    for (final addition in additions) {
      final result = await _guardMutation(() async {
        _verifySession();
        return _accountGateway.addPlaylistEntry(
          playlistId: remotePlaylistId,
          videoId: addition.videoId,
        );
      });
      _verifySession();
      final stopped = _stoppedReceipt(
        result,
        priorWrite: wrote,
        onStatusCode: _notifyAuthenticationExpired,
      );
      if (stopped != null) {
        return stopped;
      }
      wrote = true;
    }

    // Structural edits need a read-back before ordering. Apart from proving
    // acknowledged removals/additions became visible, this is the only safe
    // way to obtain the new per-occurrence setVideoIds.
    if (removals.isNotEmpty || additions.isNotEmpty) {
      final PlaylistSyncSnapshot readBackSnapshot;
      try {
        _verifySession();
        final readBack = await _accountGateway.getPlaylist(remotePlaylistId);
        _verifySession();
        if (!readBack.isComplete) {
          return const RemoteMutationReceipt(
            status: RemoteMutationStatus.ambiguous,
            message:
                'La lectura posterior a la escritura quedó incompleta; no '
                'se intentará ordenar a ciegas.',
          );
        }
        readBackSnapshot = _toSyncSnapshot(readBack);
      } on account.YouTubeMusicAccountException catch (error) {
        _notifyAuthenticationExpired(error.statusCode);
        return const RemoteMutationReceipt(
          status: RemoteMutationStatus.ambiguous,
          message:
              'YouTube confirmó cambios, pero la sesión no pudo '
              'verificarlos antes de ordenar.',
        );
      } on Object {
        return const RemoteMutationReceipt(
          status: RemoteMutationStatus.ambiguous,
          message:
              'YouTube confirmó cambios, pero no se pudo verificar su '
              'estado antes de ordenar.',
        );
      }
      currentTitle = readBackSnapshot.title.trim();
      working =
          _observedOccurrences(readBackSnapshot) ?? const <_RemoteOccurrence>[];
      final readBackMatch = _matchDesired(desiredOccurrences, working);
      if (!readBackMatch.isExact) {
        return const RemoteMutationReceipt(
          status: RemoteMutationStatus.ambiguous,
          message:
              'La lectura posterior no coincide todavía con las '
              'ocurrencias esperadas; no se repetirá ninguna escritura.',
        );
      }
    }

    final orderingMatch = _matchDesired(desiredOccurrences, working);
    if (!orderingMatch.isExact) {
      // No write happened when this branch is reached without structural
      // changes, so this is a definite, safe rejection rather than ambiguity.
      return RemoteMutationReceipt(
        status: wrote
            ? RemoteMutationStatus.ambiguous
            : RemoteMutationStatus.rejected,
        message:
            'No fue posible identificar todas las ocurrencias remotas de '
            'forma segura.',
      );
    }
    final targetOrder = <_RemoteOccurrence>[
      for (var index = 0; index < desiredOccurrences.length; index++)
        working[orderingMatch.remoteIndexByDesired[index]!],
    ];

    for (var targetIndex = 0; targetIndex < targetOrder.length; targetIndex++) {
      final target = targetOrder[targetIndex];
      if (working[targetIndex].setVideoId == target.setVideoId) {
        continue;
      }
      final currentIndex = working.indexWhere(
        (entry) => entry.setVideoId == target.setVideoId,
        targetIndex + 1,
      );
      if (currentIndex < 0) {
        return RemoteMutationReceipt(
          status: wrote
              ? RemoteMutationStatus.ambiguous
              : RemoteMutationStatus.rejected,
          message: 'La playlist cambió mientras se estaba ordenando.',
        );
      }
      final successor = working[targetIndex];
      final result = await _guardMutation(() async {
        _verifySession();
        return _accountGateway.movePlaylistEntry(
          playlistId: remotePlaylistId,
          setVideoId: target.setVideoId,
          successorSetVideoId: successor.setVideoId,
        );
      });
      _verifySession();
      final stopped = _stoppedReceipt(
        result,
        priorWrite: wrote,
        onStatusCode: _notifyAuthenticationExpired,
      );
      if (stopped != null) {
        return stopped;
      }
      wrote = true;
      working.removeAt(currentIndex);
      working.insert(targetIndex, target);
    }

    if (desiredTitle != currentTitle) {
      final result = await _guardMutation(() async {
        _verifySession();
        return _accountGateway.renamePlaylist(
          playlistId: remotePlaylistId,
          title: desiredTitle,
        );
      });
      _verifySession();
      final stopped = _stoppedReceipt(
        result,
        priorWrite: wrote,
        onStatusCode: _notifyAuthenticationExpired,
      );
      if (stopped != null) {
        return stopped;
      }
    }

    return RemoteMutationReceipt(
      status: RemoteMutationStatus.acknowledged,
      remotePlaylistId: _canonicalPlaylistId(remotePlaylistId),
    );
  }

  @override
  Future<RemoteMutationReceipt> applyLikedMusicState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    _verifyAccount(accountKey);
    _verifySession();
    final remotePlaylistId = _normalized(observed.remotePlaylistId);
    if (remotePlaylistId == null) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La colección de favoritos no tiene un identificador válido.',
      );
    }

    final observedIds = _likedVideoIds(observed);
    final desiredIds = _likedVideoIds(desired);
    final removals = observedIds.difference(desiredIds).toList(growable: false);
    final additions = desiredIds
        .difference(observedIds)
        .toList(growable: false);
    var wrote = false;

    // The like endpoints are one-shot. If an operation is ambiguous or a
    // later operation fails, stop immediately and let the engine fetch LM
    // again before deciding whether another mutation is safe.
    for (final videoId in removals) {
      final result = await _guardMutation(() async {
        _verifySession();
        return _accountGateway.removeLike(videoId);
      });
      _verifySession();
      final stopped = _stoppedReceipt(
        result,
        priorWrite: wrote,
        onStatusCode: _notifyAuthenticationExpired,
      );
      if (stopped != null) {
        return stopped;
      }
      wrote = true;
    }
    for (final videoId in additions) {
      final result = await _guardMutation(() async {
        _verifySession();
        return _accountGateway.likeVideo(videoId);
      });
      _verifySession();
      final stopped = _stoppedReceipt(
        result,
        priorWrite: wrote,
        onStatusCode: _notifyAuthenticationExpired,
      );
      if (stopped != null) {
        return stopped;
      }
      wrote = true;
    }
    return RemoteMutationReceipt(
      status: RemoteMutationStatus.acknowledged,
      remotePlaylistId: _canonicalPlaylistId(remotePlaylistId),
    );
  }

  @override
  Future<RemoteMutationReceipt> deletePlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required String mutationToken,
  }) async {
    _verifyAccount(accountKey);
    final remotePlaylistId = _normalized(observed.remotePlaylistId);
    if (remotePlaylistId == null) {
      return const RemoteMutationReceipt(
        status: RemoteMutationStatus.rejected,
        message: 'La playlist remota no tiene un identificador válido.',
      );
    }
    final result = await _guardMutation(() async {
      _verifySession();
      return _accountGateway.deletePlaylist(remotePlaylistId);
    });
    _verifySession();
    _notifyAuthenticationExpired(_mutationStatusCode(result));
    return switch (result) {
      account.YouTubeMusicMutationSuccess<
        account.RemotePlaylistMutationApplied
      >() =>
        RemoteMutationReceipt(
          status: RemoteMutationStatus.acknowledged,
          remotePlaylistId: _canonicalPlaylistId(remotePlaylistId),
        ),
      account.YouTubeMusicMutationAmbiguous<
        account.RemotePlaylistMutationApplied
      >(
        :final reason,
      ) =>
        RemoteMutationReceipt(
          status: RemoteMutationStatus.ambiguous,
          remotePlaylistId: _canonicalPlaylistId(remotePlaylistId),
          message: reason,
        ),
      account.YouTubeMusicMutationFailure<
        account.RemotePlaylistMutationApplied
      >(
        :final reason,
      ) =>
        RemoteMutationReceipt(
          status: RemoteMutationStatus.rejected,
          remotePlaylistId: _canonicalPlaylistId(remotePlaylistId),
          message: reason,
        ),
    };
  }

  PlaylistSyncSnapshot _toSyncSnapshot(account.RemotePlaylistSnapshot remote) {
    if (!remote.isComplete) {
      throw PlaylistGatewayUnavailableException(
        'YouTube Music devolvió una playlist incompleta '
        '(${remote.termination.name}).',
      );
    }
    final summary = remote.summary;
    if (summary == null || summary.title.trim().isEmpty) {
      throw const PlaylistGatewayUnavailableException(
        'YouTube Music no devolvió metadatos verificables de la playlist.',
      );
    }
    return PlaylistSyncSnapshot(
      remotePlaylistId: remote.playlistId,
      title: summary.title,
      items: remote.entries.map(
        (entry) => PlaylistSyncItem(
          videoId: _normalized(entry.videoId),
          setVideoId: _normalized(entry.setVideoId),
          track: _toCatalogTrack(remote.playlistId, entry),
        ),
      ),
      // The LM collection is mutated through like/removelike rather than the
      // ordinary playlist edit surface. Keep it writable in the sync model so
      // the dedicated gateway can apply local like changes.
      isEditable: _isLikedMusicPlaylistId(remote.playlistId)
          ? true
          : summary.isEditable,
      privacy: _privacyName(summary.visibility),
    );
  }

  void _verifyAccount(String suppliedAccountKey) {
    if (_requiredAccountKey(suppliedAccountKey) != _accountKey) {
      throw const PlaylistGatewayUnavailableException(
        'La sesión activa ya no pertenece a esta cola de sincronización.',
      );
    }
  }

  void _verifySession() {
    var isCurrent = false;
    try {
      isCurrent = _isSessionCurrent();
    } on Object {
      isCurrent = false;
    }
    if (!isCurrent) {
      throw const PlaylistGatewayUnavailableException(
        'La cuenta o el canal cambió durante la sincronización.',
      );
    }
  }

  void _notifyAuthenticationExpired(int? statusCode) {
    if (statusCode != 401 && statusCode != 403) {
      return;
    }
    try {
      _onAuthenticationExpired();
    } on Object {
      // Session invalidation is best effort and must never cause a write to be
      // repeated or reclassified as safely rejected.
    }
  }
}

CatalogTrack _toCatalogTrack(
  String playlistId,
  account.RemotePlaylistEntry entry,
) {
  final videoId = _normalized(entry.videoId);
  if (videoId != null) {
    return CatalogTrack.youtube(
      videoId: videoId,
      title: entry.title,
      artists: entry.artists,
      artistBrowseIds: entry.artistBrowseIds,
      album: entry.album,
      duration: entry.duration,
      thumbnailUrl: entry.thumbnailUrl,
      sourceUrl: Uri.https('music.youtube.com', '/watch', <String, String>{
        'v': videoId,
      }).toString(),
    );
  }
  final occurrenceKey = entry.occurrenceKey;
  return CatalogTrack(
    key: 'youtube-unavailable:$playlistId:$occurrenceKey',
    provider: CatalogProvider.legacy,
    providerId: '$playlistId:$occurrenceKey',
    title: entry.title,
    artists: entry.artists,
    artistBrowseIds: entry.artistBrowseIds,
    album: entry.album,
    duration: entry.duration,
    thumbnailUrl: entry.thumbnailUrl,
  );
}

List<_DesiredOccurrence>? _desiredOccurrences(PlaylistSyncSnapshot desired) {
  final occurrences = <_DesiredOccurrence>[];
  final explicitSetIds = <String>{};
  for (final item in desired.remoteProjection.items) {
    final videoId = _normalized(item.videoId);
    if (videoId == null) {
      return null;
    }
    final setVideoId = _normalized(item.setVideoId);
    if (setVideoId != null && !explicitSetIds.add(setVideoId)) {
      return null;
    }
    occurrences.add(
      _DesiredOccurrence(videoId: videoId, setVideoId: setVideoId),
    );
  }
  return occurrences;
}

Set<String> _likedVideoIds(PlaylistSyncSnapshot snapshot) => snapshot.items
    .map((item) => _normalized(item.videoId))
    .whereType<String>()
    .toSet();

List<_RemoteOccurrence>? _observedOccurrences(PlaylistSyncSnapshot observed) {
  final occurrences = <_RemoteOccurrence>[];
  final seenSetIds = <String>{};
  for (var position = 0; position < observed.items.length; position++) {
    final item = observed.items[position];
    final videoId = _normalized(item.videoId);
    if (videoId == null) {
      // Deleted/region-blocked rows cannot participate in the remote
      // projection. They are preserved by leaving them untouched.
      continue;
    }
    final setVideoId = _normalized(item.setVideoId);
    if (setVideoId == null || !seenSetIds.add(setVideoId)) {
      return null;
    }
    occurrences.add(
      _RemoteOccurrence(
        position: position,
        videoId: videoId,
        setVideoId: setVideoId,
        item: item,
      ),
    );
  }
  return occurrences;
}

_OccurrenceMatch _matchDesired(
  List<_DesiredOccurrence> desired,
  List<_RemoteOccurrence> remote,
) {
  final claimed = <int>{};
  final remoteByDesired = List<int?>.filled(desired.length, null);

  // Reserve explicit setVideoIds before video-only matching. Otherwise a new
  // duplicate placed earlier could steal an existing occurrence that a later
  // desired row explicitly references.
  for (var desiredIndex = 0; desiredIndex < desired.length; desiredIndex++) {
    final wanted = desired[desiredIndex];
    final setVideoId = wanted.setVideoId;
    if (setVideoId == null) {
      continue;
    }
    final remoteIndex = remote.indexWhere(
      (candidate) =>
          candidate.setVideoId == setVideoId &&
          candidate.videoId == wanted.videoId,
    );
    if (remoteIndex >= 0 && claimed.add(remoteIndex)) {
      remoteByDesired[desiredIndex] = remoteIndex;
    }
  }

  for (var desiredIndex = 0; desiredIndex < desired.length; desiredIndex++) {
    if (remoteByDesired[desiredIndex] != null) {
      continue;
    }
    final wanted = desired[desiredIndex];
    var remoteIndex = -1;
    for (
      var candidateIndex = 0;
      candidateIndex < remote.length;
      candidateIndex++
    ) {
      if (!claimed.contains(candidateIndex) &&
          remote[candidateIndex].videoId == wanted.videoId) {
        remoteIndex = candidateIndex;
        break;
      }
    }
    if (remoteIndex >= 0) {
      claimed.add(remoteIndex);
      remoteByDesired[desiredIndex] = remoteIndex;
    }
  }
  return _OccurrenceMatch(
    remoteIndexByDesired: remoteByDesired,
    claimedRemoteIndexes: claimed,
    remoteCount: remote.length,
  );
}

Future<
  account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
>
_guardMutation(
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  Function()
  mutation,
) async {
  try {
    return await mutation();
  } on PlaylistGatewayUnavailableException {
    rethrow;
  } on Object {
    return const account.YouTubeMusicMutationAmbiguous<
      account.RemotePlaylistMutationApplied
    >(
      operation: 'playlistSyncMutation',
      reason: 'No fue posible confirmar la operación remota.',
    );
  }
}

bool _sameVideoOrder(
  List<_DesiredOccurrence> desired,
  PlaylistSyncSnapshot observed,
) {
  final observedVideoIds = observed.items
      .map((item) => _normalized(item.videoId))
      .whereType<String>()
      .toList(growable: false);
  if (desired.length != observedVideoIds.length) {
    return false;
  }
  for (var index = 0; index < desired.length; index++) {
    if (desired[index].videoId != observedVideoIds[index]) {
      return false;
    }
  }
  return true;
}

RemoteMutationReceipt? _stoppedReceipt(
  account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  result, {
  required bool priorWrite,
  required void Function(int? statusCode) onStatusCode,
}) {
  onStatusCode(_mutationStatusCode(result));
  return switch (result) {
    account.YouTubeMusicMutationSuccess<
      account.RemotePlaylistMutationApplied
    >() =>
      null,
    account.YouTubeMusicMutationAmbiguous<
      account.RemotePlaylistMutationApplied
    >(
      :final reason,
    ) =>
      RemoteMutationReceipt(
        status: RemoteMutationStatus.ambiguous,
        message: reason,
      ),
    account.YouTubeMusicMutationFailure<account.RemotePlaylistMutationApplied>(
      :final reason,
    ) =>
      RemoteMutationReceipt(
        status: priorWrite
            ? RemoteMutationStatus.ambiguous
            : RemoteMutationStatus.rejected,
        message: priorWrite
            ? 'La playlist quedó parcialmente modificada: $reason'
            : reason,
      ),
  };
}

int? _mutationStatusCode<T>(account.YouTubeMusicMutationResult<T> result) {
  if (result is account.YouTubeMusicMutationFailure<T>) {
    return result.statusCode;
  }
  if (result is account.YouTubeMusicMutationAmbiguous<T>) {
    return result.statusCode;
  }
  return null;
}

account.RemotePlaylistVisibility _privacyForCreate(String? value) {
  return switch (value?.trim().toUpperCase()) {
    'PUBLIC' => account.RemotePlaylistVisibility.public,
    'UNLISTED' => account.RemotePlaylistVisibility.unlisted,
    // New playlists are private unless the user selected a concrete broader
    // visibility. Unknown API labels must never make a playlist public.
    _ => account.RemotePlaylistVisibility.private,
  };
}

String? _privacyName(account.RemotePlaylistVisibility visibility) {
  return switch (visibility) {
    account.RemotePlaylistVisibility.private => 'PRIVATE',
    account.RemotePlaylistVisibility.unlisted => 'UNLISTED',
    account.RemotePlaylistVisibility.public => 'PUBLIC',
    account.RemotePlaylistVisibility.unknown => null,
  };
}

String _requiredAccountKey(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'accountKey', 'Must not be empty.');
  }
  return normalized;
}

String _requiredPlaylistId(String value) {
  final normalized = _normalized(value);
  if (normalized == null) {
    throw ArgumentError.value(value, 'remotePlaylistId', 'Must not be empty.');
  }
  return _canonicalPlaylistId(normalized);
}

String _canonicalPlaylistId(String value) =>
    value.startsWith('VL') ? value.substring(2) : value;

bool _isLikedMusicPlaylistId(String value) =>
    _canonicalPlaylistId(value.trim()).toUpperCase() == 'LM';

bool _isEpisodesForLaterPlaylist(account.RemotePlaylistSummary playlist) {
  final title = playlist.title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9áéíóúüñ]+', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (title == 'episodes for later' ||
      title == 'episodios para despues' ||
      title == 'episodios para después') {
    return true;
  }
  final hasEpisode = title.contains('episode') || title.contains('episodio');
  final hasLater =
      title.contains('later') ||
      title.contains('despues') ||
      title.contains('después') ||
      title.contains('after');
  return hasEpisode && hasLater;
}

String? _normalized(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

bool _alwaysCurrentSession() => true;

void _ignoreAuthenticationExpiry() {}

final class _DesiredOccurrence {
  const _DesiredOccurrence({required this.videoId, this.setVideoId});

  final String videoId;
  final String? setVideoId;
}

final class _RemoteOccurrence {
  const _RemoteOccurrence({
    required this.position,
    required this.videoId,
    required this.setVideoId,
    required this.item,
  });

  final int position;
  final String videoId;
  final String setVideoId;
  final PlaylistSyncItem item;

  account.RemotePlaylistEntry toAccountEntry() => account.RemotePlaylistEntry(
    position: position,
    videoId: videoId,
    setVideoId: setVideoId,
    title: item.track.title,
    artists: item.track.artists,
    artistBrowseIds:
        item.track.artistBrowseIds.length == item.track.artists.length
        ? item.track.artistBrowseIds
        : null,
    album: item.track.album,
    duration: item.track.duration,
    thumbnailUrl: item.track.thumbnailUrl,
  );
}

final class _OccurrenceMatch {
  const _OccurrenceMatch({
    required this.remoteIndexByDesired,
    required this.claimedRemoteIndexes,
    required this.remoteCount,
  });

  final List<int?> remoteIndexByDesired;
  final Set<int> claimedRemoteIndexes;
  final int remoteCount;

  bool get isExact =>
      remoteIndexByDesired.every((index) => index != null) &&
      claimedRemoteIndexes.length == remoteCount;
}
