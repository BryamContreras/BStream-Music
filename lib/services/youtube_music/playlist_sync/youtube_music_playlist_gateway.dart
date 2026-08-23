import 'playlist_sync_models.dart';

class RemotePlaylistSummary {
  const RemotePlaylistSummary({
    required this.remotePlaylistId,
    required this.title,
    this.remoteBrowseId,
    this.isEditable = true,
    this.privacy,
    this.isLikedMusic = false,
  });

  final String remotePlaylistId;
  final String? remoteBrowseId;
  final String title;
  final bool isEditable;
  final String? privacy;

  /// True for YouTube Music's system "Liked Music" collection (LM/VLLM).
  /// It is represented locally by BStream's reserved Favorites playlist,
  /// rather than imported as a second ordinary playlist.
  final bool isLikedMusic;
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

/// Mutation boundary for YouTube Music's special "Liked Music" collection.
///
/// Liked Music is not an ordinary editable playlist.  Its membership is the
/// account's like state and must be changed through the like/removelike
/// endpoints; calling browse/edit_playlist is rejected by YouTube and would
/// incorrectly turn every local like into a sync conflict.
abstract interface class YouTubeMusicLikedMusicGateway {
  Future<RemoteMutationReceipt> applyLikedMusicState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  });
}
