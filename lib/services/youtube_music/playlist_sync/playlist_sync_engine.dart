// ignore_for_file: prefer_initializing_formals

import 'playlist_sync_models.dart';
import 'playlist_sync_store.dart';
import 'playlist_three_way_merger.dart';
import 'youtube_music_playlist_gateway.dart';

typedef PlaylistMutationTokenFactory = String Function();

class PlaylistSyncEngine {
  const PlaylistSyncEngine({
    required PlaylistSyncStore store,
    required YouTubeMusicPlaylistGateway gateway,
    required PlaylistThreeWayMerger merger,
    required PlaylistMutationTokenFactory mutationTokenFactory,
    required DateTime Function() clock,
    bool Function()? canPersist,
  }) : _store = store,
       _gateway = gateway,
       _merger = merger,
       _mutationTokenFactory = mutationTokenFactory,
       _clock = clock,
       _canPersist = canPersist;

  final PlaylistSyncStore _store;
  final YouTubeMusicPlaylistGateway _gateway;
  final PlaylistThreeWayMerger _merger;
  final PlaylistMutationTokenFactory _mutationTokenFactory;
  final DateTime Function() _clock;
  final bool Function()? _canPersist;

  Future<PlaylistSyncResult> sync(
    PlaylistSyncKey key, {
    PlaylistSyncTrigger trigger = PlaylistSyncTrigger.manual,
  }) async {
    final work = await _store.loadWork(key);
    if (work == null) {
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.noChanges,
        message: 'No existe un vínculo sincronizable.',
      );
    }
    if (!_isPersistenceAllowed()) {
      return _sessionChangedResult();
    }
    // The old implementation treated YouTube's LM projection like an
    // editable playlist and could leave a permanent conflict after the
    // server rejected that write. Favorites now use the like/removelike API,
    // so let the set-based reconciliation repair that legacy state instead
    // of requiring the user to choose a side again. Ordinary playlists keep
    // the explicit conflict freeze.
    if (work.intent?.status == PlaylistSyncIntentStatus.conflict &&
        !_isFavoritesKey(key)) {
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        message:
            'La sincronizaci\u00f3n est\u00e1 congelada hasta resolver el conflicto.',
      );
    }
    if (work.localDeleted && work.binding.remoteDeleteRequestedAt == null) {
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.localDeleted,
        message:
            'La playlist se elimin\u00f3 s\u00f3lo de este dispositivo; la copia '
            'remota y su v\u00ednculo se conservaron.',
      );
    }
    final notBefore = work.intent?.nextAttemptAt;
    if (trigger != PlaylistSyncTrigger.manual &&
        notBefore != null &&
        notBefore.isAfter(_clock())) {
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.deferred,
        message: 'La sincronización está esperando su backoff controlado.',
      );
    }
    final remotePlaylistId = work.binding.remotePlaylistId;
    if (remotePlaylistId == null) {
      return _createRemote(work, trigger: trigger);
    }

    final PlaylistSyncSnapshot? remote;
    try {
      remote = await _gateway.fetchPlaylist(
        accountKey: key.accountKey,
        remotePlaylistId: remotePlaylistId,
      );
    } catch (error) {
      if (!_isPersistenceAllowed()) {
        return _sessionChangedResult();
      }
      return _deferRead(work, error);
    }
    if (!_isPersistenceAllowed()) {
      return _sessionChangedResult();
    }

    final explicitResolution =
        work.intent?.status == PlaylistSyncIntentStatus.pending
        ? playlistSyncConflictResolutionFromReason(work.intent?.reason)
        : null;
    if (explicitResolution == PlaylistSyncConflictResolution.keepRemote) {
      if (remote == null) {
        final conflict = const PlaylistSyncConflict(
          kind: PlaylistSyncConflictKind.remoteDeleted,
          message:
              'No existe una copia remota que pueda conservarse como '
              'resoluci\u00f3n.',
        );
        await _store.recordConflict(
          key: key,
          conflict: conflict,
          base: work.base,
          local: work.local,
          remote: null,
          now: _clock(),
        );
        return PlaylistSyncResult(
          disposition: PlaylistSyncDisposition.remoteDeleted,
          conflicts: <PlaylistSyncConflict>[conflict],
        );
      }
      final adoptedRemote = _merger
          .merge(
            base: null,
            local: PlaylistSyncSnapshot(title: '', items: const []),
            remote: remote,
            ignoreTitleConflicts: _isFavoritesKey(key),
            ignoreOrderConflicts: _isFavoritesKey(key),
          )
          .snapshot!;
      return _commit(work, adoptedRemote, remote);
    }

    if (explicitResolution == PlaylistSyncConflictResolution.keepLocal &&
        remote == null &&
        !work.localDeleted) {
      // The user explicitly chose the surviving BStream copy after YouTube
      // deleted its counterpart. Clear the stale remote identity before the
      // one-shot create so a crash or an ambiguous response cannot make the
      // old deleted ID look reusable on the next pass.
      final unbound = work.binding.copyWith(
        remotePlaylistId: null,
        remoteBrowseId: null,
        remoteRevision: null,
        lastRemoteSeenAt: null,
        updatedAt: _clock(),
      );
      try {
        await _store.upsertBinding(unbound, canCommit: _isPersistenceAllowed);
      } on PlaylistSyncFenceChanged catch (_) {
        return _sessionChangedResult();
      }
      return _createRemote(
        PlaylistSyncWork(
          binding: unbound,
          base: null,
          local: work.local,
          localRevision: work.localRevision,
          localDeleted: false,
          intent: work.intent,
        ),
        trigger: trigger,
      );
    }

    if (work.localDeleted &&
        work.intent?.status == PlaylistSyncIntentStatus.ambiguous) {
      // A delete has no desired snapshot to compare. The read above is the
      // only safe verification: never issue the destructive request again.
      if (remote == null) {
        try {
          await _store.commitRemoteDeleted(
            key: work.binding.key,
            expectedLocalRevision: work.localRevision,
            now: _clock(),
            canCommit: _isPersistenceAllowed,
          );
        } on PlaylistSyncRevisionChanged catch (_) {
          return const PlaylistSyncResult(
            disposition: PlaylistSyncDisposition.deferred,
            message: 'La playlist cambió durante la verificación del borrado.',
          );
        } on PlaylistSyncFenceChanged catch (_) {
          return _sessionChangedResult();
        }
        return const PlaylistSyncResult(
          disposition: PlaylistSyncDisposition.localDeleted,
        );
      }
      final conflict = const PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.ambiguousMutation,
        message:
            'No se pudo confirmar el borrado anterior; BStream no lo '
            'repetirá automáticamente.',
      );
      await _store.recordConflict(
        key: work.binding.key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: remote,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }

    if (work.localDeleted) {
      return _deleteRemote(work, remote);
    }
    if (remote == null) {
      final conflict = PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.remoteDeleted,
        message:
            'La playlist remota desapareció; no se recreó automáticamente.',
      );
      await _store.recordConflict(
        key: key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: null,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.remoteDeleted,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }

    final pendingDesired = work.intent?.desiredSnapshot;
    if (work.intent?.status == PlaylistSyncIntentStatus.ambiguous &&
        pendingDesired != null) {
      final pendingMatchesRemote = _isFavoritesKey(key)
          ? _sameFavoriteSet(remote, pendingDesired)
          : remote.semanticallyEquals(pendingDesired);
      if (pendingMatchesRemote) {
        // A download can become available, or the user can otherwise edit the
        // local playlist, while the previous write is awaiting read-back.
        // Preserve local-only metadata when its remote projection is still the
        // verified desired state. If its content diverged, establish only the
        // verified remote base and atomically queue the newer local revision;
        // never overwrite the local rows or reuse the ambiguous token.
        final verifiedBase = _isFavoritesKey(key)
            ? _alignFavoritesItems(pendingDesired, remote)
            : _alignVerifiedItems(pendingDesired, remote);
        if (verifiedBase == null) {
          return _recordAlignmentConflict(
            work: work,
            remote: remote,
            kind: PlaylistSyncConflictKind.ambiguousMutation,
            message:
                'La escritura anterior coincide en contenido, pero sus '
                'ocurrencias no pudieron verificarse de forma segura.',
          );
        }
        final localStillMatchesPending = _isFavoritesKey(key)
            ? _sameFavoriteSet(work.local, pendingDesired)
            : work.local.semanticallyEquals(pendingDesired);
        if (!localStillMatchesPending) {
          try {
            await _store.commitVerifiedBaseWithNewerLocal(
              key: work.binding.key,
              verifiedBase: verifiedBase,
              verifiedRemote: remote,
              verifiedLocalRevision: work.intent!.requestedLocalRevision,
              expectedLocalRevision: work.localRevision,
              now: _clock(),
              canCommit: _isPersistenceAllowed,
            );
          } on PlaylistSyncRevisionChanged catch (_) {
            return const PlaylistSyncResult(
              disposition: PlaylistSyncDisposition.deferred,
              message:
                  'La playlist volvi\u00f3 a cambiar durante la verificaci\u00f3n.',
            );
          } on PlaylistSyncFenceChanged catch (_) {
            return _sessionChangedResult();
          }
          return const PlaylistSyncResult(
            disposition: PlaylistSyncDisposition.deferred,
            message:
                'La escritura anterior fue confirmada; los cambios locales '
                'm\u00e1s recientes siguen pendientes.',
          );
        }
        final aligned = _isFavoritesKey(key)
            ? _alignFavoritesItems(work.local, remote)
            : _alignVerifiedItems(work.local, remote);
        if (aligned == null) {
          return _recordAlignmentConflict(
            work: work,
            remote: remote,
            kind: PlaylistSyncConflictKind.ambiguousMutation,
            message:
                'La escritura anterior coincide en contenido, pero sus '
                'ocurrencias no pudieron verificarse de forma segura.',
          );
        }
        return _commit(
          work,
          aligned,
          remote,
          remoteMutation: true,
          ambiguityDesired: pendingDesired,
          mutationToken: work.intent?.mutationToken,
        );
      }
      final conflict = const PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.ambiguousMutation,
        message:
            'No se pudo confirmar la escritura anterior; se detuvo para '
            'evitar duplicarla.',
      );
      await _store.recordConflict(
        key: key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: remote,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }

    final merge = _merger.merge(
      base: explicitResolution == PlaylistSyncConflictResolution.keepLocal
          ? remote
          : work.base,
      local: work.local,
      remote: remote,
      // YouTube's Liked Music collection is server-ordered and can reorder
      // itself after every like. Treating that churn as a playlist conflict
      // would make each subsequent local like require manual resolution.
      ignoreTitleConflicts: _isFavoritesKey(key),
      ignoreOrderConflicts: _isFavoritesKey(key),
    );
    if (merge.hasConflicts) {
      for (final conflict in merge.conflicts) {
        await _store.recordConflict(
          key: key,
          conflict: conflict,
          base: work.base,
          local: work.local,
          remote: remote,
          now: _clock(),
        );
      }
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: merge.conflicts,
      );
    }
    final merged = merge.snapshot!;
    final desiredRemote = merged.remoteProjection;
    final isFavorites = _isFavoritesKey(key);
    final remoteMatchesDesired = isFavorites
        ? _sameFavoriteSet(remote, desiredRemote)
        : remote.semanticallyEquals(desiredRemote);
    if (remoteMatchesDesired) {
      final aligned = isFavorites
          ? _alignFavoritesItems(merged, remote)
          : _alignVerifiedItems(merged, remote);
      if (aligned == null) {
        return _recordAlignmentConflict(
          work: work,
          remote: remote,
          kind: PlaylistSyncConflictKind.order,
          message:
              'YouTube devolvi\u00f3 ocurrencias que no coinciden con el orden '
              'verificado; no se modific\u00f3 la playlist local.',
        );
      }
      return _commit(work, aligned, remote);
    }
    final likedGateway = _gateway is YouTubeMusicLikedMusicGateway
        ? _gateway as YouTubeMusicLikedMusicGateway
        : null;
    if (isFavorites && likedGateway != null) {
      return _applyLikedMusicMutation(
        work: work,
        merged: merged,
        desiredRemote: desiredRemote,
        remote: remote,
        remotePlaylistId: remotePlaylistId,
        mutationToken: work.intent?.mutationToken ?? _mutationTokenFactory(),
        gateway: likedGateway,
      );
    }
    if (!remote.isEditable || !work.binding.isEditable) {
      final conflict = const PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.remoteNotEditable,
        message: 'La playlist remota no permite aplicar cambios.',
      );
      await _store.recordConflict(
        key: key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: remote,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }

    final token = work.intent?.mutationToken ?? _mutationTokenFactory();
    if (!_isPersistenceAllowed()) {
      return _sessionChangedResult();
    }
    RemoteMutationReceipt receipt;
    try {
      receipt = await _gateway.applyDesiredState(
        accountKey: key.accountKey,
        observed: remote,
        desired: desiredRemote,
        mutationToken: token,
      );
    } catch (error) {
      return _verifyAfterMutation(
        work: work,
        merged: merged,
        desiredRemote: desiredRemote,
        remotePlaylistId: remotePlaylistId,
        mutationToken: token,
        mutationError: error,
      );
    }
    if (receipt.status == RemoteMutationStatus.rejected) {
      if (!_isPersistenceAllowed()) {
        return _sessionChangedResult();
      }
      final conflict = PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.remoteNotEditable,
        message: receipt.message ?? 'YouTube Music rechazó la modificación.',
      );
      await _store.recordConflict(
        key: key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: remote,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }
    return _verifyAfterMutation(
      work: work,
      merged: merged,
      desiredRemote: desiredRemote,
      remotePlaylistId: receipt.remotePlaylistId ?? remotePlaylistId,
      mutationToken: token,
      mutationError: receipt.status == RemoteMutationStatus.ambiguous
          ? receipt.message ?? 'Respuesta remota ambigua.'
          : null,
    );
  }

  Future<PlaylistSyncResult> _createRemote(
    PlaylistSyncWork work, {
    required PlaylistSyncTrigger trigger,
  }) async {
    if (work.localDeleted) {
      try {
        await _store.commitRemoteDeleted(
          key: work.binding.key,
          expectedLocalRevision: work.localRevision,
          now: _clock(),
          canCommit: _isPersistenceAllowed,
        );
      } on PlaylistSyncRevisionChanged catch (_) {
        return const PlaylistSyncResult(
          disposition: PlaylistSyncDisposition.deferred,
          message: 'La playlist cambi\u00f3 durante la sincronizaci\u00f3n.',
        );
      } on PlaylistSyncFenceChanged catch (_) {
        return _sessionChangedResult();
      }
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.localDeleted,
      );
    }
    final pending = work.intent;
    if (pending?.status == PlaylistSyncIntentStatus.ambiguous) {
      final conflict = const PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.ambiguousMutation,
        message:
            'La creación anterior quedó sin ID remoto; no se repetirá '
            'automáticamente.',
      );
      await _store.recordConflict(
        key: work.binding.key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: null,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }
    final desired = work.local.remoteProjection;
    final token = pending?.mutationToken ?? _mutationTokenFactory();
    if (!_isPersistenceAllowed()) {
      return _sessionChangedResult();
    }
    final RemoteMutationReceipt receipt;
    try {
      receipt = await _gateway.createPlaylist(
        accountKey: work.binding.key.accountKey,
        desired: desired,
        mutationToken: token,
      );
    } catch (error) {
      await _recordAmbiguous(
        work: work,
        desired: desired,
        mutationToken: token,
        error: error,
      );
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.deferred,
        message: 'La creación quedó pendiente de verificación.',
      );
    }
    final remoteId = receipt.remotePlaylistId;
    if (receipt.status == RemoteMutationStatus.rejected) {
      if (!_isPersistenceAllowed()) {
        return _sessionChangedResult();
      }
      final conflict = PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.remoteNotEditable,
        message: receipt.message ?? 'YouTube Music rechazó la creación.',
      );
      await _store.recordConflict(
        key: work.binding.key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: null,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }
    if (remoteId == null) {
      await _recordAmbiguous(
        work: work,
        desired: desired,
        mutationToken: token,
        error: receipt.message,
      );
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.deferred,
        message: 'YouTube no devolvió un ID verificable.',
      );
    }
    await _store.upsertBinding(
      work.binding.copyWith(remotePlaylistId: remoteId, updatedAt: _clock()),
    );
    if (!_isPersistenceAllowed()) {
      await _recordAmbiguous(
        work: work,
        desired: desired,
        mutationToken: token,
        error:
            receipt.message ??
            'La sesi\u00f3n cambi\u00f3 tras crear la playlist.',
      );
      return _sessionChangedResult();
    }
    return _verifyAfterMutation(
      work: work,
      merged: work.local,
      desiredRemote: desired,
      remotePlaylistId: remoteId,
      mutationToken: token,
      mutationError: receipt.status == RemoteMutationStatus.ambiguous
          ? receipt.message
          : null,
    );
  }

  Future<PlaylistSyncResult> _deleteRemote(
    PlaylistSyncWork work,
    PlaylistSyncSnapshot? remote,
  ) async {
    if (remote == null) {
      try {
        await _store.commitRemoteDeleted(
          key: work.binding.key,
          expectedLocalRevision: work.localRevision,
          now: _clock(),
          canCommit: _isPersistenceAllowed,
        );
      } on PlaylistSyncRevisionChanged catch (_) {
        return const PlaylistSyncResult(
          disposition: PlaylistSyncDisposition.deferred,
          message: 'La playlist cambi\u00f3 durante la sincronizaci\u00f3n.',
        );
      } on PlaylistSyncFenceChanged catch (_) {
        return _sessionChangedResult();
      }
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.localDeleted,
      );
    }
    if (!remote.isEditable || !work.binding.isEditable) {
      final conflict = const PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.remoteNotEditable,
        message:
            'La playlist remota no permite confirmar una eliminaci\u00f3n.',
      );
      await _store.recordConflict(
        key: work.binding.key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: remote,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }
    final token = work.intent?.mutationToken ?? _mutationTokenFactory();
    if (!_isPersistenceAllowed()) {
      return _sessionChangedResult();
    }
    RemoteMutationReceipt? receipt;
    try {
      receipt = await _gateway.deletePlaylist(
        accountKey: work.binding.key.accountKey,
        observed: remote,
        mutationToken: token,
      );
    } catch (_) {
      // A thrown write is ambiguous. The read-back below decides whether it
      // took effect; it is never immediately repeated.
    }
    if (receipt?.status == RemoteMutationStatus.rejected) {
      if (!_isPersistenceAllowed()) {
        return _sessionChangedResult();
      }
      final conflict = PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.remoteNotEditable,
        message:
            receipt?.message ??
            'YouTube Music rechaz\u00f3 la eliminaci\u00f3n.',
      );
      await _store.recordConflict(
        key: work.binding.key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: remote,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }
    if (!_isPersistenceAllowed()) {
      await _recordAmbiguousDelete(
        work: work,
        mutationToken: token,
        error: receipt?.message ?? 'La sesi\u00f3n cambi\u00f3 tras eliminar.',
      );
      return _sessionChangedResult();
    }
    PlaylistSyncSnapshot? verified;
    try {
      verified = await _gateway.fetchPlaylist(
        accountKey: work.binding.key.accountKey,
        remotePlaylistId: remote.remotePlaylistId!,
      );
    } catch (error) {
      await _store.recordDeferred(
        key: work.binding.key,
        requestedLocalRevision: work.localRevision,
        reason: 'ambiguous_delete',
        now: _clock(),
        nextAttemptAt: _nextAttempt(work),
        mutationToken: token,
        error: '$error',
        ambiguous: true,
      );
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.deferred,
      );
    }
    if (!_isPersistenceAllowed()) {
      await _recordAmbiguousDelete(
        work: work,
        mutationToken: token,
        error:
            'La sesi\u00f3n cambi\u00f3 antes de confirmar la eliminaci\u00f3n.',
      );
      return _sessionChangedResult();
    }
    if (verified == null) {
      try {
        await _store.commitRemoteDeleted(
          key: work.binding.key,
          expectedLocalRevision: work.localRevision,
          now: _clock(),
          canCommit: _isPersistenceAllowed,
        );
      } on PlaylistSyncRevisionChanged catch (_) {
        await _recordAmbiguousDelete(
          work: work,
          mutationToken: token,
          error: 'La playlist local cambi\u00f3 tras eliminar la copia remota.',
        );
        return const PlaylistSyncResult(
          disposition: PlaylistSyncDisposition.deferred,
        );
      } on PlaylistSyncFenceChanged catch (_) {
        await _recordAmbiguousDelete(
          work: work,
          mutationToken: token,
          error: 'La sesi\u00f3n cambi\u00f3 tras eliminar la copia remota.',
        );
        return _sessionChangedResult();
      }
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.localDeleted,
      );
    }
    await _store.recordDeferred(
      key: work.binding.key,
      requestedLocalRevision: work.localRevision,
      reason: 'delete_not_visible',
      now: _clock(),
      nextAttemptAt: _nextAttempt(work),
      mutationToken: token,
      error: 'La playlist aún existe después de la eliminación.',
      ambiguous: true,
    );
    return const PlaylistSyncResult(
      disposition: PlaylistSyncDisposition.deferred,
    );
  }

  Future<PlaylistSyncResult> _applyLikedMusicMutation({
    required PlaylistSyncWork work,
    required PlaylistSyncSnapshot merged,
    required PlaylistSyncSnapshot desiredRemote,
    required PlaylistSyncSnapshot remote,
    required String remotePlaylistId,
    required String mutationToken,
    required YouTubeMusicLikedMusicGateway gateway,
  }) async {
    if (!_isPersistenceAllowed()) {
      return _sessionChangedResult();
    }
    RemoteMutationReceipt receipt;
    try {
      receipt = await gateway.applyLikedMusicState(
        accountKey: work.binding.key.accountKey,
        observed: remote,
        desired: desiredRemote,
        mutationToken: mutationToken,
      );
    } catch (error) {
      return _verifyAfterMutation(
        work: work,
        merged: merged,
        desiredRemote: desiredRemote,
        remotePlaylistId: remotePlaylistId,
        mutationToken: mutationToken,
        mutationError: error,
        favorites: true,
      );
    }
    if (receipt.status == RemoteMutationStatus.rejected) {
      if (!_isPersistenceAllowed()) {
        return _sessionChangedResult();
      }
      final conflict = PlaylistSyncConflict(
        kind: PlaylistSyncConflictKind.remoteNotEditable,
        message:
            receipt.message ?? 'YouTube Music rechazó el cambio de favoritos.',
      );
      await _store.recordConflict(
        key: work.binding.key,
        conflict: conflict,
        base: work.base,
        local: work.local,
        remote: remote,
        now: _clock(),
      );
      return PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.conflict,
        conflicts: <PlaylistSyncConflict>[conflict],
      );
    }
    return _verifyAfterMutation(
      work: work,
      merged: merged,
      desiredRemote: desiredRemote,
      remotePlaylistId: receipt.remotePlaylistId ?? remotePlaylistId,
      mutationToken: mutationToken,
      mutationError: receipt.status == RemoteMutationStatus.ambiguous
          ? receipt.message
          : null,
      favorites: true,
    );
  }

  Future<PlaylistSyncResult> _verifyAfterMutation({
    required PlaylistSyncWork work,
    required PlaylistSyncSnapshot merged,
    required PlaylistSyncSnapshot desiredRemote,
    required String remotePlaylistId,
    required String mutationToken,
    required Object? mutationError,
    bool favorites = false,
  }) async {
    if (!_isPersistenceAllowed()) {
      await _recordAmbiguous(
        work: work,
        desired: desiredRemote,
        mutationToken: mutationToken,
        error: mutationError ?? 'La sesi\u00f3n cambi\u00f3 tras la escritura.',
      );
      return _sessionChangedResult();
    }
    final PlaylistSyncSnapshot? verified;
    try {
      verified = await _gateway.fetchPlaylist(
        accountKey: work.binding.key.accountKey,
        remotePlaylistId: remotePlaylistId,
      );
    } catch (error) {
      await _recordAmbiguous(
        work: work,
        desired: desiredRemote,
        mutationToken: mutationToken,
        error: mutationError ?? error,
      );
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.deferred,
        message: 'La escritura quedó pendiente de verificación.',
      );
    }
    if (!_isPersistenceAllowed()) {
      await _recordAmbiguous(
        work: work,
        desired: desiredRemote,
        mutationToken: mutationToken,
        error:
            mutationError ??
            'La sesi\u00f3n cambi\u00f3 antes de confirmar la escritura.',
      );
      return _sessionChangedResult();
    }
    final verifiedSnapshot = verified;
    if (verifiedSnapshot != null) {
      final verifiedMatches = favorites
          ? _sameFavoriteSet(verifiedSnapshot, desiredRemote)
          : verifiedSnapshot.semanticallyEquals(desiredRemote);
      if (verifiedMatches) {
        final aligned = favorites
            ? _alignFavoritesItems(merged, verifiedSnapshot)
            : _alignVerifiedItems(merged, verifiedSnapshot);
        if (aligned == null) {
          await _recordAmbiguous(
            work: work,
            desired: desiredRemote,
            mutationToken: mutationToken,
            error:
                mutationError ??
                'El contenido remoto coincide, pero no sus ocurrencias.',
          );
          return const PlaylistSyncResult(
            disposition: PlaylistSyncDisposition.deferred,
            message:
                'La escritura qued\u00f3 pendiente de verificaci\u00f3n segura.',
          );
        }
        return _commit(
          work,
          aligned,
          verifiedSnapshot,
          remoteMutation: true,
          ambiguityDesired: desiredRemote,
          mutationToken: mutationToken,
        );
      }
    }
    await _recordAmbiguous(
      work: work,
      desired: desiredRemote,
      mutationToken: mutationToken,
      error: mutationError ?? 'El resultado remoto no coincide todavía.',
    );
    return const PlaylistSyncResult(
      disposition: PlaylistSyncDisposition.deferred,
      message: 'La escritura no se repetirá hasta resolver su estado.',
    );
  }

  Future<PlaylistSyncResult> _commit(
    PlaylistSyncWork work,
    PlaylistSyncSnapshot aligned,
    PlaylistSyncSnapshot verified, {
    bool remoteMutation = false,
    PlaylistSyncSnapshot? ambiguityDesired,
    String? mutationToken,
  }) async {
    try {
      await _store.commitSynchronized(
        key: work.binding.key,
        mergedLocal: aligned,
        verifiedRemote: verified,
        expectedLocalRevision: work.localRevision,
        now: _clock(),
        canCommit: _isPersistenceAllowed,
      );
    } on PlaylistSyncRevisionChanged catch (_) {
      if (ambiguityDesired != null && mutationToken != null) {
        await _recordAmbiguous(
          work: work,
          desired: ambiguityDesired,
          mutationToken: mutationToken,
          error: 'La playlist local cambi\u00f3 tras la escritura remota.',
        );
      } else {
        try {
          await _store.enqueueIntent(
            key: work.binding.key,
            requestedLocalRevision: work.localRevision + 1,
            reason: 'local_changed_during_sync',
            now: _clock(),
            canCommit: _isPersistenceAllowed,
          );
        } on PlaylistSyncFenceChanged catch (_) {
          return _sessionChangedResult();
        }
      }
      return const PlaylistSyncResult(
        disposition: PlaylistSyncDisposition.deferred,
        message: 'La playlist cambió durante la sincronización.',
      );
    } on PlaylistSyncFenceChanged catch (_) {
      if (ambiguityDesired != null && mutationToken != null) {
        await _recordAmbiguous(
          work: work,
          desired: ambiguityDesired,
          mutationToken: mutationToken,
          error: 'La sesi\u00f3n cambi\u00f3 tras la escritura remota.',
        );
      }
      return _sessionChangedResult();
    }
    return PlaylistSyncResult(
      disposition:
          remoteMutation ||
              work.base == null ||
              !work.local.semanticallyEquals(aligned) ||
              work.intent != null
          ? PlaylistSyncDisposition.synchronized
          : PlaylistSyncDisposition.noChanges,
    );
  }

  Future<PlaylistSyncResult> _deferRead(
    PlaylistSyncWork work,
    Object error,
  ) async {
    final previousIntent = work.intent;
    final preserveAmbiguity =
        previousIntent?.status == PlaylistSyncIntentStatus.ambiguous;
    await _store.recordDeferred(
      key: work.binding.key,
      requestedLocalRevision: work.localRevision,
      reason: preserveAmbiguity ? previousIntent!.reason : 'remote_unavailable',
      now: _clock(),
      nextAttemptAt: _nextAttempt(work),
      desired: preserveAmbiguity ? previousIntent!.desiredSnapshot : null,
      mutationToken: preserveAmbiguity ? previousIntent!.mutationToken : null,
      error: '$error',
      ambiguous: preserveAmbiguity,
    );
    return const PlaylistSyncResult(
      disposition: PlaylistSyncDisposition.deferred,
      message: 'Sin conexión; los cambios quedaron pendientes.',
    );
  }

  Future<void> _recordAmbiguous({
    required PlaylistSyncWork work,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
    required Object? error,
  }) {
    return _store.recordDeferred(
      key: work.binding.key,
      requestedLocalRevision: work.localRevision,
      reason: 'ambiguous_mutation',
      now: _clock(),
      nextAttemptAt: _nextAttempt(work),
      desired: desired,
      mutationToken: mutationToken,
      error: '$error',
      ambiguous: true,
    );
  }

  Future<void> _recordAmbiguousDelete({
    required PlaylistSyncWork work,
    required String mutationToken,
    required Object error,
  }) {
    return _store.recordDeferred(
      key: work.binding.key,
      requestedLocalRevision: work.localRevision,
      reason: 'ambiguous_delete',
      now: _clock(),
      nextAttemptAt: _nextAttempt(work),
      mutationToken: mutationToken,
      error: '$error',
      ambiguous: true,
    );
  }

  bool _isPersistenceAllowed() {
    final canPersist = _canPersist;
    if (canPersist == null) {
      return true;
    }
    try {
      return canPersist();
    } on Object {
      return false;
    }
  }

  bool _isFavoritesKey(PlaylistSyncKey key) =>
      key.playlistId == 'bstream:favorites';

  bool _sameFavoriteSet(PlaylistSyncSnapshot left, PlaylistSyncSnapshot right) {
    final leftCounts = _favoriteCounts(left);
    final rightCounts = _favoriteCounts(right);
    if (leftCounts.length != rightCounts.length) {
      return false;
    }
    for (final entry in leftCounts.entries) {
      if (rightCounts[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  Map<String, int> _favoriteCounts(PlaylistSyncSnapshot snapshot) {
    final counts = <String, int>{};
    for (final item in snapshot.items) {
      final videoId = item.videoId?.trim();
      if (videoId == null || videoId.isEmpty) {
        continue;
      }
      counts[videoId] = (counts[videoId] ?? 0) + 1;
    }
    return counts;
  }

  PlaylistSyncSnapshot? _alignFavoritesItems(
    PlaylistSyncSnapshot merged,
    PlaylistSyncSnapshot verified,
  ) {
    if (!_sameFavoriteSet(merged, verified)) {
      return null;
    }
    final verifiedByVideo = <String, List<PlaylistSyncItem>>{};
    for (final item in verified.items) {
      final videoId = item.videoId?.trim();
      if (videoId == null || videoId.isEmpty) {
        continue;
      }
      verifiedByVideo
          .putIfAbsent(videoId, () => <PlaylistSyncItem>[])
          .add(item);
    }
    final aligned = <PlaylistSyncItem>[];
    for (final item in merged.items) {
      final videoId = item.videoId?.trim();
      if (videoId == null || videoId.isEmpty) {
        aligned.add(item);
        continue;
      }
      final candidates = verifiedByVideo[videoId];
      if (candidates == null || candidates.isEmpty) {
        return null;
      }
      final remoteItem = candidates.removeAt(0);
      aligned.add(item.copyWith(setVideoId: remoteItem.setVideoId));
    }
    return PlaylistSyncSnapshot(
      remotePlaylistId: verified.remotePlaylistId,
      title: merged.title,
      items: aligned,
      remoteRevision: verified.remoteRevision,
      isEditable: verified.isEditable,
      privacy: verified.privacy,
    );
  }

  PlaylistSyncResult _sessionChangedResult() => const PlaylistSyncResult(
    disposition: PlaylistSyncDisposition.deferred,
    message: 'La cuenta o el canal cambi\u00f3 durante la sincronizaci\u00f3n.',
  );

  Future<PlaylistSyncResult> _recordAlignmentConflict({
    required PlaylistSyncWork work,
    required PlaylistSyncSnapshot remote,
    required PlaylistSyncConflictKind kind,
    required String message,
  }) async {
    final conflict = PlaylistSyncConflict(kind: kind, message: message);
    await _store.recordConflict(
      key: work.binding.key,
      conflict: conflict,
      base: work.base,
      local: work.local,
      remote: remote,
      now: _clock(),
    );
    return PlaylistSyncResult(
      disposition: PlaylistSyncDisposition.conflict,
      conflicts: <PlaylistSyncConflict>[conflict],
    );
  }

  DateTime _nextAttempt(PlaylistSyncWork work) {
    final attempts = work.intent?.attemptCount ?? 0;
    final seconds = 5 * (1 << attempts.clamp(0, 6));
    return _clock().add(Duration(seconds: seconds));
  }

  PlaylistSyncSnapshot? _alignVerifiedItems(
    PlaylistSyncSnapshot merged,
    PlaylistSyncSnapshot verified,
  ) {
    final expectedRemoteItems = merged.items
        .where((item) => item.videoId != null)
        .toList(growable: false);
    final verifiedRemoteItems = verified.items
        // Unavailable/region-blocked rows can legitimately contain only a
        // setVideoId. They remain in the merged snapshot, but must not consume
        // the playable occurrence used to align local UUIDs.
        .where((item) => item.videoId != null)
        .toList(growable: false);
    if (expectedRemoteItems.length != verifiedRemoteItems.length) {
      return null;
    }
    for (var index = 0; index < expectedRemoteItems.length; index++) {
      if (expectedRemoteItems[index].videoId !=
          verifiedRemoteItems[index].videoId) {
        return null;
      }
    }

    var remoteIndex = 0;
    final aligned = <PlaylistSyncItem>[];
    for (final item in merged.items) {
      if (item.videoId == null) {
        aligned.add(item);
        continue;
      }
      final remoteItem = verifiedRemoteItems[remoteIndex++];
      aligned.add(
        item.copyWith(
          videoId: remoteItem.videoId,
          setVideoId: remoteItem.setVideoId,
          track: remoteItem.track.title.trim().isEmpty
              ? item.track
              : remoteItem.track,
        ),
      );
    }
    return PlaylistSyncSnapshot(
      remotePlaylistId: verified.remotePlaylistId,
      title: merged.title,
      items: aligned,
      remoteRevision: verified.remoteRevision,
      isEditable: verified.isEditable,
      privacy: verified.privacy,
    );
  }
}
