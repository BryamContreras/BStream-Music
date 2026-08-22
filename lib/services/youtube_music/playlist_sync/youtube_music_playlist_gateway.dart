import 'playlist_sync_models.dart';

class RemotePlaylistSummary {
  const RemotePlaylistSummary({
    required this.remotePlaylistId,
    required this.title,
    this.remoteBrowseId,
    this.isEditable = true,
    this.privacy,
  });

  final String remotePlaylistId;
  final String? remoteBrowseId;
  final String title;
  final bool isEditable;
  final String? privacy;
}

abstract interface class YouTubeMusicPlaylistCatalogGateway {
  Future<List<RemotePlaylistSummary>> listRemotePlaylists({
    required String accountKey,
  });
}

class PlaylistGatewayUnavailableException implements Exception {
  const PlaylistGatewayUnavailableException([this.message]);

  final String? message;

  @override
  String toString() => message == null
      ? 'PlaylistGatewayUnavailableException'
      : 'PlaylistGatewayUnavailableException: $message';
}

/// Account/auth implementation boundary for the unofficial YouTube Music API.
///
/// Mutation methods are deliberately one-shot: implementations MUST NOT retry
/// a write after a timeout or unknown response. The engine performs a read-back
/// and only issues another mutation after it can prove the first one did not
/// take effect. [observed] includes `setVideoId` values needed for precise
/// duplicate deletion/reordering.
abstract interface class YouTubeMusicPlaylistGateway {
  Future<PlaylistSyncSnapshot?> fetchPlaylist({
    required String accountKey,
    required String remotePlaylistId,
  });

  Future<RemoteMutationReceipt> createPlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  });

  Future<RemoteMutationReceipt> applyDesiredState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  });

  Future<RemoteMutationReceipt> deletePlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required String mutationToken,
  });
}
