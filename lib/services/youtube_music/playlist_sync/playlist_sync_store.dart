import 'playlist_sync_models.dart';

class PlaylistSyncRevisionChanged implements Exception {
  const PlaylistSyncRevisionChanged();
}

class PlaylistSyncFenceChanged implements Exception {
  const PlaylistSyncFenceChanged();
}

class PlaylistSyncImportResult {
  const PlaylistSyncImportResult({
    required this.binding,
    required this.created,
  });

  final PlaylistSyncBinding binding;
  final bool created;
}

/// UI-safe projection of one unresolved account conflict.
///
/// Snapshot payloads and mutation tokens deliberately stay inside the store.
class PlaylistSyncUnresolvedConflict {
  const PlaylistSyncUnresolvedConflict({
    required this.key,
    required this.playlistTitle,
    required this.localRevision,
    required this.kind,
    required this.detectedAt,
    this.message,
  });

  final PlaylistSyncKey key;
  final String playlistTitle;
  final int localRevision;
  final PlaylistSyncConflictKind kind;
  final String? message;
  final DateTime detectedAt;
}

enum PlaylistSyncConflictResolution { keepLocal, keepRemote, retryManually }

String playlistSyncConflictResolutionReason(
  PlaylistSyncConflictResolution resolution,
) => 'resolve_${resolution.name}';

PlaylistSyncConflictResolution? playlistSyncConflictResolutionFromReason(
  String? reason,
) {
  for (final resolution in PlaylistSyncConflictResolution.values) {
    if (reason == playlistSyncConflictResolutionReason(resolution)) {
      return resolution;
    }
  }
  return null;
}

abstract interface class PlaylistSyncStore {
  Future<PlaylistSyncWork?> loadWork(PlaylistSyncKey key);

  Future<List<PlaylistSyncBinding>> listBindings({String? accountKey});

  Future<List<PlaylistSyncUnresolvedConflict>> listUnresolvedConflicts({
    required String accountKey,
  });

  Future<void> upsertBinding(
    PlaylistSyncBinding binding, {
    bool Function()? canCommit,
  });

  /// Creates a local shell, its immutable remote binding and initial intent in
  /// one transaction. Repeating the call for the same account/remote ID is
  /// idempotent and returns the existing binding.
  Future<PlaylistSyncImportResult> importRemotePlaylistAtomically({
    required PlaylistSyncBinding binding,
    required String localPlaylistName,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    bool Function()? canCommit,
  });

  Future<void> enqueueIntent({
    required PlaylistSyncKey key,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    bool Function()? canCommit,
  });

  Future<void> commitSynchronized({
    required PlaylistSyncKey key,
    required PlaylistSyncSnapshot mergedLocal,
    required PlaylistSyncSnapshot verifiedRemote,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  });

  /// Resolves a verified ambiguous write without replacing newer local rows.
  ///
  /// The verified snapshot becomes the three-way-merge base, while the local
  /// playlist remains byte-for-byte unchanged and a fresh pending intent is
  /// queued for its current revision.
  Future<void> commitVerifiedBaseWithNewerLocal({
    required PlaylistSyncKey key,
    required PlaylistSyncSnapshot verifiedBase,
    required PlaylistSyncSnapshot verifiedRemote,
    required int verifiedLocalRevision,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  });

  Future<void> recordDeferred({
    required PlaylistSyncKey key,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    required DateTime nextAttemptAt,
    PlaylistSyncSnapshot? desired,
    String? mutationToken,
    String? error,
    bool ambiguous = false,
  });

  Future<void> recordConflict({
    required PlaylistSyncKey key,
    required PlaylistSyncConflict conflict,
    required PlaylistSyncSnapshot? base,
    required PlaylistSyncSnapshot local,
    required PlaylistSyncSnapshot? remote,
    required DateTime now,
  });

  /// Explicitly unfreezes an unresolved conflict for the selected policy.
  /// Local edits alone never call this method and therefore cannot retry a
  /// possibly partial remote write.
  Future<void> resolveConflict({
    required PlaylistSyncKey key,
    required PlaylistSyncConflictResolution resolution,
    required int expectedLocalRevision,
    required DateTime now,
  });

  Future<void> commitRemoteDeleted({
    required PlaylistSyncKey key,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  });
}
