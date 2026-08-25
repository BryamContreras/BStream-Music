import 'track_info.dart';

enum SearchCategory { songs, videos, albums, artists }

enum SearchBackend { innerTube, ytDlp }

class SearchAlbum {
  SearchAlbum({
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
        other is SearchAlbum &&
            browseId == other.browseId &&
            title == other.title &&
            _listsEqual(artists, other.artists) &&
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

class SearchArtist {
  const SearchArtist({
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
        other is SearchArtist &&
            browseId == other.browseId &&
            name == other.name &&
            thumbnailUrl == other.thumbnailUrl;
  }

  @override
  int get hashCode => Object.hash(browseId, name, thumbnailUrl);
}

class SearchPage {
  SearchPage({
    required this.category,
    required this.backend,
    List<TrackInfo> tracks = const [],
    List<SearchAlbum> albums = const [],
    List<SearchArtist> artists = const [],
    this.primaryError,
  }) : assert(switch (category) {
         SearchCategory.songs ||
         SearchCategory.videos => albums.isEmpty && artists.isEmpty,
         SearchCategory.albums => tracks.isEmpty && artists.isEmpty,
         SearchCategory.artists => tracks.isEmpty && albums.isEmpty,
       }, 'A search page can contain results only for its category.'),
       assert(
         backend != SearchBackend.ytDlp || category == SearchCategory.videos,
         'yt-dlp search results are always YouTube videos.',
       ),
       tracks = List.unmodifiable(tracks),
       albums = List.unmodifiable(albums),
       artists = List.unmodifiable(artists);

  final SearchCategory category;
  final SearchBackend backend;
  final List<TrackInfo> tracks;
  final List<SearchAlbum> albums;
  final List<SearchArtist> artists;

  /// The InnerTube failure that caused this page to use yt-dlp.
  ///
  /// Direct YouTube references intentionally use yt-dlp without a primary
  /// failure, so this remains `null` for those searches.
  final Object? primaryError;

  bool get isFallback => backend == SearchBackend.ytDlp;
  bool get isEmpty => tracks.isEmpty && albums.isEmpty && artists.isEmpty;
}

bool _listsEqual<T>(List<T> left, List<T> right) {
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
