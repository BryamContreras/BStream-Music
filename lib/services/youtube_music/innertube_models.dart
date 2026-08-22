class InnerTubeSong {
  InnerTubeSong({
    required this.videoId,
    required this.title,
    required List<String> artists,
    List<String?>? artistBrowseIds,
    this.album,
    this.duration,
    this.thumbnailUrl,
  }) : artists = List.unmodifiable(artists),
       artistBrowseIds = _normalizeArtistBrowseIds(artists, artistBrowseIds);

  final String videoId;
  final String title;
  final List<String> artists;

  /// YouTube Music browse IDs aligned by index with [artists].
  ///
  /// An entry is `null` when a response contains an artist name without a
  /// navigable artist endpoint. Existing callers that only provide [artists]
  /// therefore remain source-compatible.
  final List<String?> artistBrowseIds;
  final String? album;
  final Duration? duration;
  final String? thumbnailUrl;

  String get artist => artists.join(', ');

  Uri get watchUri =>
      Uri.https('www.youtube.com', '/watch', <String, String>{'v': videoId});

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InnerTubeSong &&
            videoId == other.videoId &&
            title == other.title &&
            _listsEqual(artists, other.artists) &&
            _listsEqual(artistBrowseIds, other.artistBrowseIds) &&
            album == other.album &&
            duration == other.duration &&
            thumbnailUrl == other.thumbnailUrl;
  }

  @override
  int get hashCode => Object.hash(
    videoId,
    title,
    Object.hashAll(artists),
    Object.hashAll(artistBrowseIds),
    album,
    duration,
    thumbnailUrl,
  );

  static bool _listsEqual<T>(List<T> left, List<T> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}

class InnerTubeAlbum {
  InnerTubeAlbum({
    required this.browseId,
    required this.title,
    required List<String> artists,
    List<String?>? artistBrowseIds,
    this.year,
    this.type,
    this.thumbnailUrl,
    this.playlistId,
  }) : artists = List.unmodifiable(artists),
       artistBrowseIds = _normalizeArtistBrowseIds(artists, artistBrowseIds);

  final String browseId;
  final String title;
  final List<String> artists;

  /// YouTube Music browse IDs aligned by index with [artists].
  final List<String?> artistBrowseIds;
  final String? year;
  final String? type;
  final String? thumbnailUrl;
  final String? playlistId;

  String get artist => artists.join(', ');

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InnerTubeAlbum &&
            browseId == other.browseId &&
            title == other.title &&
            InnerTubeSong._listsEqual(artists, other.artists) &&
            InnerTubeSong._listsEqual(artistBrowseIds, other.artistBrowseIds) &&
            year == other.year &&
            type == other.type &&
            thumbnailUrl == other.thumbnailUrl &&
            playlistId == other.playlistId;
  }

  @override
  int get hashCode => Object.hash(
    browseId,
    title,
    Object.hashAll(artists),
    Object.hashAll(artistBrowseIds),
    year,
    type,
    thumbnailUrl,
    playlistId,
  );
}

class InnerTubeArtist {
  const InnerTubeArtist({
    required this.browseId,
    required this.name,
    this.thumbnailUrl,
  });

  final String browseId;
  final String name;
  final String? thumbnailUrl;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InnerTubeArtist &&
            browseId == other.browseId &&
            name == other.name &&
            thumbnailUrl == other.thumbnailUrl;
  }

  @override
  int get hashCode => Object.hash(browseId, name, thumbnailUrl);
}

class InnerTubeNextPage {
  InnerTubeNextPage({
    required List<InnerTubeSong> songs,
    this.continuation,
    this.relatedBrowseId,
    this.automixPlaylistId,
  }) : songs = List.unmodifiable(songs);

  /// Queue order returned by YouTube. Its index is the implicit source rank.
  final List<InnerTubeSong> songs;
  final String? continuation;
  final String? relatedBrowseId;
  final String? automixPlaylistId;
}

class InnerTubeRelatedPage {
  InnerTubeRelatedPage({
    required List<InnerTubeSong> songs,
    required List<InnerTubeAlbum> albums,
    required List<InnerTubeArtist> artists,
    required List<InnerTubeHomeCollection> collections,
    this.continuation,
  }) : songs = List.unmodifiable(songs),
       albums = List.unmodifiable(albums),
       artists = List.unmodifiable(artists),
       collections = List.unmodifiable(collections);

  final List<InnerTubeSong> songs;
  final List<InnerTubeAlbum> albums;
  final List<InnerTubeArtist> artists;
  final List<InnerTubeHomeCollection> collections;
  final String? continuation;
}

List<String?> _normalizeArtistBrowseIds(
  List<String> artists,
  List<String?>? artistBrowseIds,
) {
  if (artistBrowseIds == null) {
    return List<String?>.unmodifiable(
      List<String?>.filled(artists.length, null),
    );
  }
  if (artistBrowseIds.length != artists.length) {
    throw ArgumentError.value(
      artistBrowseIds,
      'artistBrowseIds',
      'Must contain one entry for each artist.',
    );
  }
  return List<String?>.unmodifiable(
    artistBrowseIds.map((browseId) {
      final normalized = browseId?.trim();
      return normalized == null || normalized.isEmpty ? null : normalized;
    }),
  );
}

sealed class InnerTubeHomeItem {
  const InnerTubeHomeItem();
}

final class InnerTubeHomeSongItem extends InnerTubeHomeItem {
  const InnerTubeHomeSongItem(this.song);

  final InnerTubeSong song;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InnerTubeHomeSongItem && song == other.song;
  }

  @override
  int get hashCode => song.hashCode;
}

enum InnerTubeHomeCollectionKind { mix, playlist }

final class InnerTubeHomeCollection extends InnerTubeHomeItem {
  const InnerTubeHomeCollection({
    required this.title,
    required this.browseId,
    required this.kind,
    this.subtitle,
    this.thumbnailUrl,
    this.playlistId,
  });

  final String title;
  final String? subtitle;
  final String? thumbnailUrl;
  final String browseId;
  final String? playlistId;
  final InnerTubeHomeCollectionKind kind;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InnerTubeHomeCollection &&
            title == other.title &&
            subtitle == other.subtitle &&
            thumbnailUrl == other.thumbnailUrl &&
            browseId == other.browseId &&
            playlistId == other.playlistId &&
            kind == other.kind;
  }

  @override
  int get hashCode =>
      Object.hash(title, subtitle, thumbnailUrl, browseId, playlistId, kind);
}

class InnerTubeHomeSection {
  factory InnerTubeHomeSection({
    required String title,
    List<InnerTubeHomeItem>? items,
    List<InnerTubeSong>? songs,
  }) {
    if ((items == null) == (songs == null)) {
      throw ArgumentError('Provide exactly one of items or songs.');
    }
    return InnerTubeHomeSection._(
      title: title,
      items:
          items ??
          songs!
              .map<InnerTubeHomeItem>(InnerTubeHomeSongItem.new)
              .toList(growable: false),
    );
  }

  InnerTubeHomeSection._({
    required this.title,
    required List<InnerTubeHomeItem> items,
  }) : items = List.unmodifiable(items);

  final String title;
  final List<InnerTubeHomeItem> items;

  List<InnerTubeSong> get songs => List.unmodifiable(
    items.whereType<InnerTubeHomeSongItem>().map((item) => item.song),
  );

  List<InnerTubeHomeCollection> get collections =>
      List.unmodifiable(items.whereType<InnerTubeHomeCollection>());

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is InnerTubeHomeSection &&
            title == other.title &&
            InnerTubeSong._listsEqual(items, other.items);
  }

  @override
  int get hashCode => Object.hash(title, Object.hashAll(items));
}
