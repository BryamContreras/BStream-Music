import 'catalog_track.dart';

enum PlaylistEntryOrigin { local, remote, merged, legacy }

/// One occurrence in a playlist.
///
/// [id] identifies the occurrence rather than the song, so duplicates are
/// preserved and can be moved/deleted independently. [localTrackId] is only a
/// cached playable representation; a null value never makes the entry invalid.
class PlaylistEntry {
  const PlaylistEntry({
    required this.id,
    required this.playlistId,
    required this.track,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
    this.localTrackId,
    this.remoteVideoId,
    this.setVideoId,
    this.origin = PlaylistEntryOrigin.local,
    this.deletedAt,
  });

  final String id;
  final String playlistId;
  final CatalogTrack track;
  final String? localTrackId;
  final String? remoteVideoId;
  final String? setVideoId;
  final int position;
  final PlaylistEntryOrigin origin;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  String? get videoId => remoteVideoId ?? track.youtubeVideoId;

  PlaylistEntry copyWith({
    String? id,
    String? playlistId,
    CatalogTrack? track,
    Object? localTrackId = _unset,
    Object? remoteVideoId = _unset,
    Object? setVideoId = _unset,
    int? position,
    PlaylistEntryOrigin? origin,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? deletedAt = _unset,
  }) {
    return PlaylistEntry(
      id: id ?? this.id,
      playlistId: playlistId ?? this.playlistId,
      track: track ?? this.track,
      localTrackId: identical(localTrackId, _unset)
          ? this.localTrackId
          : localTrackId as String?,
      remoteVideoId: identical(remoteVideoId, _unset)
          ? this.remoteVideoId
          : remoteVideoId as String?,
      setVideoId: identical(setVideoId, _unset)
          ? this.setVideoId
          : setVideoId as String?,
      position: position ?? this.position,
      origin: origin ?? this.origin,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: identical(deletedAt, _unset)
          ? this.deletedAt
          : deletedAt as DateTime?,
    );
  }
}

const Object _unset = Object();
