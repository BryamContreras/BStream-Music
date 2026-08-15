import 'dart:async';

import 'package:bstream_music/features/music/data/datasources/remote_music_datasource.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/search_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteMusicDataSource search', () {
    test(
      'loads song, video, and album tabs lazily through InnerTube',
      () async {
        final catalog = _FakeYouTubeMusicSearch(
          results: [
            InnerTubeSong(
              videoId: 'songs000001',
              title: 'Song result',
              artists: const ['Song artist'],
            ),
          ],
          videoResults: [
            InnerTubeSong(
              videoId: 'videos00001',
              title: 'Video result',
              artists: const ['Video artist'],
            ),
          ],
          albumResults: [
            InnerTubeAlbum(
              browseId: 'MPREalbum001',
              title: 'Album result',
              artists: const ['Album artist'],
              year: '2026',
              type: 'Album',
              thumbnailUrl: 'https://img.test/album.jpg',
              playlistId: 'OLAKalbum001',
            ),
          ],
        );
        final downloader = _FakeDownloaderService(searchResults: const []);
        final dataSource = RemoteMusicDataSource(
          downloader,
          youtubeMusicSearch: catalog,
        );

        final songs = await dataSource.searchCategory(
          'Adele',
          SearchCategory.songs,
        );

        expect(catalog.queries, ['Adele']);
        expect(catalog.videoQueries, isEmpty);
        expect(catalog.albumQueries, isEmpty);
        expect(songs.category, SearchCategory.songs);
        expect(songs.backend, SearchBackend.innerTube);
        expect(songs.tracks.single.id, 'songs000001');

        final videos = await dataSource.searchCategory(
          'Adele',
          SearchCategory.videos,
        );

        expect(catalog.videoQueries, ['Adele']);
        expect(catalog.albumQueries, isEmpty);
        expect(videos.category, SearchCategory.videos);
        expect(videos.backend, SearchBackend.innerTube);
        expect(videos.tracks.single.id, 'videos00001');

        final albums = await dataSource.searchCategory(
          'Adele',
          SearchCategory.albums,
        );

        expect(catalog.albumQueries, ['Adele']);
        expect(albums.category, SearchCategory.albums);
        expect(albums.backend, SearchBackend.innerTube);
        expect(albums.tracks, isEmpty);
        expect(
          albums.albums.single,
          SearchAlbum(
            browseId: 'MPREalbum001',
            title: 'Album result',
            artists: const ['Album artist'],
            year: '2026',
            type: 'Album',
            thumbnailUrl: 'https://img.test/album.jpg',
            playlistId: 'OLAKalbum001',
          ),
        );
        expect(downloader.searchQueries, isEmpty);
      },
    );

    test('keeps successful empty InnerTube pages without fallback', () async {
      final catalog = _FakeYouTubeMusicSearch();
      final downloader = _FakeDownloaderService(
        searchResults: const [
          TrackInfo(
            id: 'fallback',
            title: 'Fallback',
            artist: 'YouTube',
            url: 'https://www.youtube.com/watch?v=fallback001',
          ),
        ],
      );
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      for (final category in SearchCategory.values) {
        final page = await dataSource.searchCategory('No result', category);
        expect(page.category, category);
        expect(page.backend, SearchBackend.innerTube);
        expect(page.isEmpty, isTrue);
      }

      expect(downloader.searchQueries, isEmpty);
    });

    test('an InnerTube category failure falls back once to Videos', () async {
      const fallback = TrackInfo(
        id: 'fallback',
        title: 'YouTube result',
        artist: 'Uploader',
        url: 'https://www.youtube.com/watch?v=fallback001',
      );
      for (final category in SearchCategory.values) {
        final failure = StateError('${category.name} unavailable');
        final catalog = _FakeYouTubeMusicSearch(
          error: category == SearchCategory.songs ? failure : null,
          videoError: category == SearchCategory.videos ? failure : null,
          albumError: category == SearchCategory.albums ? failure : null,
        );
        final downloader = _FakeDownloaderService(
          searchResults: const [fallback],
        );
        final dataSource = RemoteMusicDataSource(
          downloader,
          youtubeMusicSearch: catalog,
        );

        final page = await dataSource.searchCategory('Query', category);

        expect(downloader.searchQueries, ['Query']);
        expect(page.category, SearchCategory.videos);
        expect(page.backend, SearchBackend.ytDlp);
        expect(page.tracks, const [fallback]);
        expect(page.albums, isEmpty);
        expect(page.primaryError, same(failure));
      }
    });

    test(
      'direct YouTube references bypass InnerTube and expose Videos',
      () async {
        final catalog = _FakeYouTubeMusicSearch(
          albumError: StateError('must not be called'),
        );
        const fallback = TrackInfo(
          id: 'H9NJenpBV2I',
          title: 'Direct result',
          artist: 'Uploader',
          url: 'https://www.youtube.com/watch?v=H9NJenpBV2I',
        );
        final downloader = _FakeDownloaderService(
          searchResults: const [fallback],
        );
        final dataSource = RemoteMusicDataSource(
          downloader,
          youtubeMusicSearch: catalog,
        );

        for (final reference in const <String>[
          'https://www.youtube.com/watch?v=H9NJenpBV2I',
          'H9NJenpBV2I',
        ]) {
          final page = await dataSource.searchCategory(
            reference,
            SearchCategory.albums,
          );
          expect(page.category, SearchCategory.videos);
          expect(page.backend, SearchBackend.ytDlp);
          expect(page.primaryError, isNull);
        }

        expect(catalog.albumQueries, isEmpty);
        expect(downloader.searchQueries, [
          'https://www.youtube.com/watch?v=H9NJenpBV2I',
          'H9NJenpBV2I',
        ]);
      },
    );

    test('resolves an album browse ID to playable tracks', () async {
      final catalog = _FakeYouTubeMusicSearch(
        albumSongs: [
          InnerTubeSong(
            videoId: 'albumtrack1',
            title: 'Album track',
            artists: const ['Album artist'],
          ),
        ],
      );
      final dataSource = RemoteMusicDataSource(
        _FakeDownloaderService(searchResults: const []),
        youtubeMusicSearch: catalog,
      );

      final tracks = await dataSource.getAlbumTracks(' MPREalbum001 ');

      expect(catalog.albumBrowseIds, ['MPREalbum001']);
      expect(tracks.single.id, 'albumtrack1');
      expect(tracks.single.metadataSource, TrackMetadataSource.youtubeMusic);
      await expectLater(dataSource.getAlbumTracks('  '), throwsArgumentError);

      final failure = StateError('album browse failed');
      final failingDataSource = RemoteMusicDataSource(
        _FakeDownloaderService(searchResults: const []),
        youtubeMusicSearch: _FakeYouTubeMusicSearch(albumLookupError: failure),
      );
      await expectLater(
        failingDataSource.getAlbumTracks('MPREalbum001'),
        throwsA(same(failure)),
      );
    });

    test('maps YouTube Music songs without invoking yt-dlp search', () async {
      final catalog = _FakeYouTubeMusicSearch(
        results: [
          InnerTubeSong(
            videoId: 'H9NJenpBV2I',
            title: 'Easy On Me',
            artists: const ['Adele', 'Second Artist'],
            album: 'Easy On Me',
            duration: const Duration(minutes: 3, seconds: 45),
            thumbnailUrl: 'https://lh3.googleusercontent.com/artwork',
          ),
        ],
      );
      final downloader = _FakeDownloaderService(
        searchResults: const [
          TrackInfo(
            id: 'fallback',
            title: 'Fallback',
            artist: 'YouTube',
            url: 'https://www.youtube.com/watch?v=fallback',
          ),
        ],
      );
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final results = await dataSource.search('easy on me');

      expect(catalog.queries, ['easy on me']);
      expect(downloader.searchQueries, isEmpty);
      expect(results, hasLength(1));
      final track = results.single;
      expect(track.id, 'H9NJenpBV2I');
      expect(track.title, 'Easy On Me');
      expect(track.artist, 'Adele, Second Artist');
      expect(track.artists, ['Adele', 'Second Artist']);
      expect(track.album, 'Easy On Me');
      expect(track.duration, const Duration(minutes: 3, seconds: 45));
      expect(
        track.thumbnailUrl,
        'https://i.ytimg.com/vi/H9NJenpBV2I/hq720.jpg',
      );
      expect(
        track.catalogThumbnailUrl,
        'https://lh3.googleusercontent.com/artwork',
      );
      expect(track.url, 'https://www.youtube.com/watch?v=H9NJenpBV2I');
      expect(track.metadataSource, TrackMetadataSource.youtubeMusic);
      expect(track.streamUrl, isNull);
    });

    test('falls back to normal YouTube search when catalog is empty', () async {
      final catalog = _FakeYouTubeMusicSearch(results: const []);
      const fallback = TrackInfo(
        id: 'fallback',
        title: 'YouTube result',
        artist: 'Uploader',
        url: 'https://www.youtube.com/watch?v=fallback',
      );
      final downloader = _FakeDownloaderService(
        searchResults: const [fallback],
      );
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final results = await dataSource.search('not in music catalog');

      expect(catalog.queries, ['not in music catalog']);
      expect(downloader.searchQueries, ['not in music catalog']);
      expect(results, const [fallback]);
    });

    test('falls back to normal YouTube search when catalog fails', () async {
      final catalog = _FakeYouTubeMusicSearch(error: StateError('offline'));
      const fallback = TrackInfo(
        id: 'fallback',
        title: 'YouTube result',
        artist: 'Uploader',
        url: 'https://www.youtube.com/watch?v=fallback',
      );
      final downloader = _FakeDownloaderService(
        searchResults: const [fallback],
      );
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final results = await dataSource.search('catalog request fails');

      expect(catalog.queries, ['catalog request fails']);
      expect(downloader.searchQueries, ['catalog request fails']);
      expect(results, const [fallback]);
    });

    test(
      'falls back when InnerTube only returns unrelated suggestions',
      () async {
        final catalog = _FakeYouTubeMusicSearch(
          results: [
            InnerTubeSong(
              videoId: 'unrelated01',
              title: 'Popular Recommendation',
              artists: const ['Different Artist'],
            ),
          ],
        );
        const fallback = TrackInfo(
          id: 'obscure001',
          title: 'Obscure Demo',
          artist: 'Small Band',
          url: 'https://www.youtube.com/watch?v=obscure001',
        );
        final downloader = _FakeDownloaderService(
          searchResults: const [fallback],
        );
        final dataSource = RemoteMusicDataSource(
          downloader,
          youtubeMusicSearch: catalog,
        );

        final results = await dataSource.search('Small Band Obscure Demo');

        expect(catalog.queries, ['Small Band Obscure Demo']);
        expect(downloader.searchQueries, ['Small Band Obscure Demo']);
        expect(results, const [fallback]);
      },
    );

    test('preserves legitimate Karaoke and Lyrics song titles', () async {
      final catalog = _FakeYouTubeMusicSearch(
        results: [
          InnerTubeSong(
            videoId: 'H4y6kScThjo',
            title: 'Karaoke',
            artists: const ['Drake'],
            album: "Thank Me Later (Int'l Version)",
          ),
          InnerTubeSong(
            videoId: 'lyrics00001',
            title: 'Lyrics',
            artists: const ['Test Artist'],
          ),
        ],
      );
      final downloader = _FakeDownloaderService(searchResults: const []);
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final karaoke = await dataSource.search('Drake Karaoke');
      final lyrics = await dataSource.search('Test Artist Lyrics');

      expect(karaoke.first.title, 'Karaoke');
      expect(lyrics.last.title, 'Lyrics');
      expect(downloader.searchQueries, isEmpty);
    });

    test('keeps normalized results for non-Latin searches', () async {
      final catalog = _FakeYouTubeMusicSearch(
        results: [
          InnerTubeSong(
            videoId: 'japanese001',
            title: 'First Love',
            artists: const ['宇多田ヒカル'],
          ),
        ],
      );
      final downloader = _FakeDownloaderService(searchResults: const []);
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final results = await dataSource.search('宇多田ヒカル First Love');

      expect(results.single.artist, '宇多田ヒカル');
      expect(downloader.searchQueries, isEmpty);
    });

    test('accepts a close spelling correction from YouTube Music', () async {
      final catalog = _FakeYouTubeMusicSearch(
        results: [
          InnerTubeSong(
            videoId: 'H9NJenpBV2I',
            title: 'Hello',
            artists: const ['Adele'],
          ),
        ],
      );
      final downloader = _FakeDownloaderService(searchResults: const []);
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final results = await dataSource.search('Adel Helo');

      expect(results.single.title, 'Hello');
      expect(downloader.searchQueries, isEmpty);
    });

    test('sends a direct YouTube URL straight to yt-dlp search', () async {
      final catalog = _FakeYouTubeMusicSearch(
        results: [
          InnerTubeSong(
            videoId: 'unrelated',
            title: 'Unrelated song',
            artists: const ['Artist'],
          ),
        ],
      );
      const fallback = TrackInfo(
        id: 'H9NJenpBV2I',
        title: 'Direct result',
        artist: 'Uploader',
        url: 'https://youtu.be/H9NJenpBV2I',
      );
      final downloader = _FakeDownloaderService(
        searchResults: const [fallback],
      );
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final results = await dataSource.search(
        'https://www.youtube.com/watch?v=H9NJenpBV2I',
      );

      expect(catalog.queries, isEmpty);
      expect(downloader.searchQueries, [
        'https://www.youtube.com/watch?v=H9NJenpBV2I',
      ]);
      expect(results, const [fallback]);
    });

    test('sends a bare YouTube video ID straight to yt-dlp search', () async {
      final catalog = _FakeYouTubeMusicSearch(results: const []);
      const fallback = TrackInfo(
        id: 'H9NJenpBV2I',
        title: 'Direct result',
        artist: 'Uploader',
        url: 'https://www.youtube.com/watch?v=H9NJenpBV2I',
      );
      final downloader = _FakeDownloaderService(
        searchResults: const [fallback],
      );
      final dataSource = RemoteMusicDataSource(
        downloader,
        youtubeMusicSearch: catalog,
      );

      final results = await dataSource.search('H9NJenpBV2I');

      expect(catalog.queries, isEmpty);
      expect(downloader.searchQueries, ['H9NJenpBV2I']);
      expect(results, const [fallback]);
    });
  });
}

class _FakeYouTubeMusicSearch
    implements
        YouTubeMusicSearch,
        YouTubeMusicCatalogSearch,
        YouTubeMusicAlbumLookup {
  _FakeYouTubeMusicSearch({
    this.results = const [],
    this.videoResults = const [],
    this.albumResults = const [],
    this.albumSongs = const [],
    this.error,
    this.videoError,
    this.albumError,
    this.albumLookupError,
  });

  final List<InnerTubeSong> results;
  final List<InnerTubeSong> videoResults;
  final List<InnerTubeAlbum> albumResults;
  final List<InnerTubeSong> albumSongs;
  final Object? error;
  final Object? videoError;
  final Object? albumError;
  final Object? albumLookupError;
  final List<String> queries = [];
  final List<String> videoQueries = [];
  final List<String> albumQueries = [];
  final List<String> albumBrowseIds = [];

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    queries.add(query);
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return results;
  }

  @override
  Future<List<InnerTubeSong>> searchVideos(
    String query, {
    int limit = 20,
  }) async {
    videoQueries.add(query);
    final failure = videoError;
    if (failure != null) {
      throw failure;
    }
    return videoResults;
  }

  @override
  Future<List<InnerTubeAlbum>> searchAlbums(
    String query, {
    int limit = 20,
  }) async {
    albumQueries.add(query);
    final failure = albumError;
    if (failure != null) {
      throw failure;
    }
    return albumResults;
  }

  @override
  Future<List<InnerTubeSong>> getAlbumSongs(
    String browseId, {
    int limit = 20,
  }) async {
    albumBrowseIds.add(browseId);
    final failure = albumLookupError;
    if (failure != null) {
      throw failure;
    }
    return albumSongs;
  }
}

class _FakeDownloaderService implements DownloaderService {
  _FakeDownloaderService({required this.searchResults});

  final List<TrackInfo> searchResults;
  final List<String> searchQueries = [];

  @override
  Stream<DownloadProgress> get progressStream => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TrackInfo>> search(String query) async {
    searchQueries.add(query);
    return searchResults;
  }

  @override
  Future<TrackInfo> getInfo(String url) => throw UnimplementedError();

  @override
  Future<TrackInfo> getPlaybackInfo(String url) => throw UnimplementedError();

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    throw UnimplementedError();
  }
}
