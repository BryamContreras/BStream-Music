import 'track_info.dart';

enum SearchCategory { songs, videos, albums }

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

class SearchPage {
  SearchPage({
    required this.category,
    required this.backend,
    List<TrackInfo> tracks = const [],
    List<SearchAlbum> albums = const [],
    this.primaryError,
  }) : assert(
         category == SearchCategory.albums ? tracks.isEmpty : albums.isEmpty,
         'Albums and playable tracks must not share a search page.',
       ),
       assert(
         backend != SearchBackend.ytDlp || category == SearchCategory.videos,
         'yt-dlp search results are always YouTube videos.',
       ),
       tracks = List.unmodifiable(tracks),
       albums = List.unmodifiable(albums);

  final SearchCategory category;
  final SearchBackend backend;
  final List<TrackInfo> tracks;
  final List<SearchAlbum> albums;

  /// The InnerTube failure that caused this page to use yt-dlp.
  ///
  /// Direct YouTube references intentionally use yt-dlp without a primary
  /// failure, so this remains `null` for those searches.
  final Object? primaryError;

  bool get isFallback => backend == SearchBackend.ytDlp;
  bool get isEmpty => tracks.isEmpty && albums.isEmpty;
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
