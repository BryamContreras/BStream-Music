class InnerTubeSong {
  InnerTubeSong({
    required this.videoId,
    required this.title,
    required List<String> artists,
    this.album,
    this.duration,
    this.thumbnailUrl,
  }) : artists = List.unmodifiable(artists);

  final String videoId;
  final String title;
  final List<String> artists;
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
            album == other.album &&
            duration == other.duration &&
            thumbnailUrl == other.thumbnailUrl;
  }

  @override
  int get hashCode => Object.hash(
    videoId,
    title,
    Object.hashAll(artists),
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
    this.year,
    this.type,
    this.thumbnailUrl,
    this.playlistId,
  }) : artists = List.unmodifiable(artists);

  final String browseId;
  final String title;
  final List<String> artists;
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
    year,
    type,
    thumbnailUrl,
    playlistId,
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
