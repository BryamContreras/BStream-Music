class Playlist {
  static const favoritesId = 'bstream:favorites';

  const Playlist({
    required this.id,
    required this.name,
    required this.trackIds,
    required this.createdAt,
    required this.updatedAt,
    this.localRevision = 0,
    this.deletedAt,
  });

  final String id;
  final String name;
  final List<String> trackIds;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int localRevision;
  final DateTime? deletedAt;

  bool get isFavorites => id == favoritesId;

  Playlist copyWith({
    String? id,
    String? name,
    List<String>? trackIds,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? localRevision,
    Object? deletedAt = _playlistUnset,
  }) {
    return Playlist(
      id: id ?? this.id,
      name: name ?? this.name,
      trackIds: trackIds ?? this.trackIds,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      localRevision: localRevision ?? this.localRevision,
      deletedAt: identical(deletedAt, _playlistUnset)
          ? this.deletedAt
          : deletedAt as DateTime?,
    );
  }
}

const Object _playlistUnset = Object();
