import 'dart:async';

import 'package:bstream_music/features/music/data/datasources/remote_music_datasource.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/search_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('submit loads Songs without resolving playback URLs', () async {
    final catalog = _FakeCatalog(
      songResults: [
        InnerTubeSong(
          videoId: 'H9NJenpBV2I',
          title: 'Easy On Me',
          artists: const ['Adele'],
          album: 'Easy On Me',
          duration: const Duration(minutes: 3, seconds: 45),
        ),
      ],
    );
    final downloader = _FakeDownloaderService();
    final container = _container(catalog, downloader);
    addTearDown(container.dispose);

    await container.read(searchControllerProvider.future);
    await container
        .read(searchControllerProvider.notifier)
        .submit('  easy on me  ');

    final search = container.read(searchControllerProvider).value!;
    expect(catalog.songQueries, ['easy on me']);
    expect(catalog.videoQueries, isEmpty);
    expect(catalog.albumQueries, isEmpty);
    expect(catalog.artistQueries, isEmpty);
    expect(downloader.searchQueries, isEmpty);
    expect(downloader.getInfoCalls, 0);
    expect(downloader.getPlaybackInfoCalls, 0);
    expect(search.query, 'easy on me');
    expect(search.selectedCategory, SearchCategory.songs);
    expect(search.pages.keys, [SearchCategory.songs]);
    expect(search.backend, SearchBackend.innerTube);
    expect(search.selectedTracks.single.id, 'H9NJenpBV2I');
    expect(search.isLoading, isFalse);
  });

  test('tabs load lazily once and reuse their cached pages', () async {
    final catalog = _FakeCatalog(
      songResults: [
        InnerTubeSong(
          videoId: 'songs000001',
          title: 'Song',
          artists: const ['Artist'],
        ),
      ],
      videoResults: [
        InnerTubeSong(
          videoId: 'videos00001',
          title: 'Video',
          artists: const ['Artist'],
        ),
      ],
      albumResults: [
        InnerTubeAlbum(
          browseId: 'MPREalbum001',
          title: 'Album',
          artists: const ['Artist'],
        ),
      ],
      artistResults: const [
        InnerTubeArtist(browseId: 'UCartist001', name: 'Artist'),
      ],
    );
    final container = _container(catalog, _FakeDownloaderService());
    addTearDown(container.dispose);
    await container.read(searchControllerProvider.future);
    final controller = container.read(searchControllerProvider.notifier);

    await controller.submit('Artist');
    await controller.selectCategory(SearchCategory.videos);
    await controller.selectCategory(SearchCategory.songs);
    await controller.selectCategory(SearchCategory.albums);
    await controller.selectCategory(SearchCategory.artists);
    await controller.selectCategory(SearchCategory.videos);

    final search = container.read(searchControllerProvider).value!;
    expect(catalog.songQueries, ['Artist']);
    expect(catalog.videoQueries, ['Artist']);
    expect(catalog.albumQueries, ['Artist']);
    expect(catalog.artistQueries, ['Artist']);
    expect(search.pages.keys.toSet(), SearchCategory.values.toSet());
    expect(search.selectedCategory, SearchCategory.videos);
    expect(search.selectedTracks.single.title, 'Video');
    expect(search.fallbackOnly, isFalse);
  });

  test('a pending tab cannot replace a reselected cached page', () async {
    final pendingVideo = Completer<List<InnerTubeSong>>();
    final catalog = _FakeCatalog(
      songResults: [
        InnerTubeSong(
          videoId: 'songs000001',
          title: 'Song',
          artists: const ['Artist'],
        ),
      ],
      videoLoader: (_) => pendingVideo.future,
    );
    final container = _container(catalog, _FakeDownloaderService());
    addTearDown(container.dispose);
    await container.read(searchControllerProvider.future);
    final controller = container.read(searchControllerProvider.notifier);

    await controller.submit('Artist');
    final videoSearch = controller.selectCategory(SearchCategory.videos);
    await controller.selectCategory(SearchCategory.songs);
    pendingVideo.complete([
      InnerTubeSong(
        videoId: 'videos00001',
        title: 'Late video',
        artists: const ['Artist'],
      ),
    ]);
    await videoSearch;

    final search = container.read(searchControllerProvider).value!;
    expect(catalog.videoQueries, ['Artist']);
    expect(search.selectedCategory, SearchCategory.songs);
    expect(search.selectedTracks.single.title, 'Song');
    expect(search.pages.keys, const [SearchCategory.songs]);
    expect(search.loadingCategory, isNull);
  });

  test('fallback drops cached tabs and exposes only yt-dlp Videos', () async {
    const failure = InnerTubeFormatException('albums endpoint changed');
    final catalog = _FakeCatalog(
      songResults: [
        InnerTubeSong(
          videoId: 'songs000001',
          title: 'Song',
          artists: const ['Artist'],
        ),
      ],
      albumError: failure,
    );
    const fallback = TrackInfo(
      id: 'fallback001',
      title: 'YouTube fallback',
      artist: 'Uploader',
      url: 'https://www.youtube.com/watch?v=fallback001',
    );
    final downloader = _FakeDownloaderService(searchResults: const [fallback]);
    final container = _container(catalog, downloader);
    addTearDown(container.dispose);
    await container.read(searchControllerProvider.future);
    final controller = container.read(searchControllerProvider.notifier);

    await controller.submit('Artist');
    await controller.selectCategory(SearchCategory.albums);

    final search = container.read(searchControllerProvider).value!;
    expect(downloader.searchQueries, ['Artist']);
    expect(search.fallbackOnly, isTrue);
    expect(search.selectedCategory, SearchCategory.videos);
    expect(search.availableCategories, const [SearchCategory.videos]);
    expect(search.pages.keys, const [SearchCategory.videos]);
    expect(search.backend, SearchBackend.ytDlp);
    expect(search.primaryError, same(failure));
    expect(search.selectedTracks, const [fallback]);

    await controller.selectCategory(SearchCategory.songs);
    expect(catalog.songQueries, ['Artist']);
    expect(downloader.searchQueries, ['Artist']);
    expect(
      container.read(searchControllerProvider).value!.selectedCategory,
      SearchCategory.videos,
    );
  });

  test('yt-dlp failure keeps the error restricted to Videos', () async {
    final catalog = _FakeCatalog(
      songResults: [
        InnerTubeSong(
          videoId: 'songs000001',
          title: 'Song',
          artists: const ['Artist'],
        ),
      ],
      albumError: const InnerTubeFormatException('albums endpoint changed'),
    );
    final fallbackFailure = StateError('yt-dlp search failed');
    final downloader = _FakeDownloaderService(searchError: fallbackFailure);
    final container = _container(catalog, downloader);
    addTearDown(container.dispose);
    await container.read(searchControllerProvider.future);
    final controller = container.read(searchControllerProvider.notifier);

    await controller.submit('Artist');
    await controller.selectCategory(SearchCategory.albums);

    final result = container.read(searchControllerProvider);
    expect(result.hasError, isTrue);
    expect(result.error, same(fallbackFailure));
    expect(result.hasValue, isTrue);
    expect(result.value!.query, 'Artist');
    expect(result.value!.fallbackOnly, isTrue);
    expect(result.value!.selectedCategory, SearchCategory.videos);
    expect(result.value!.availableCategories, const [SearchCategory.videos]);
    expect(result.value!.pages, isEmpty);
    expect(downloader.searchQueries, ['Artist']);
  });

  test('a stale slower query cannot replace a newer submission', () async {
    final pending = <String, Completer<List<InnerTubeSong>>>{};
    final catalog = _FakeCatalog(
      songLoader: (query) {
        final completer = Completer<List<InnerTubeSong>>();
        pending[query] = completer;
        return completer.future;
      },
    );
    final container = _container(catalog, _FakeDownloaderService());
    addTearDown(container.dispose);
    await container.read(searchControllerProvider.future);
    final controller = container.read(searchControllerProvider.notifier);

    final first = controller.submit('first');
    final second = controller.submit('second');
    pending['second']!.complete([
      InnerTubeSong(
        videoId: 'second00001',
        title: 'Second result',
        artists: const ['Artist'],
      ),
    ]);
    await second;
    pending['first']!.complete([
      InnerTubeSong(
        videoId: 'first000001',
        title: 'First result',
        artists: const ['Artist'],
      ),
    ]);
    await first;

    final search = container.read(searchControllerProvider).value!;
    expect(catalog.songQueries, ['first', 'second']);
    expect(search.query, 'second');
    expect(search.selectedTracks.single.title, 'Second result');
  });

  test('clear invalidates an in-flight search', () async {
    final pending = Completer<List<InnerTubeSong>>();
    final catalog = _FakeCatalog(songLoader: (_) => pending.future);
    final container = _container(catalog, _FakeDownloaderService());
    addTearDown(container.dispose);
    await container.read(searchControllerProvider.future);
    final controller = container.read(searchControllerProvider.notifier);

    final searchFuture = controller.submit('pending');
    controller.clear();
    pending.complete([
      InnerTubeSong(
        videoId: 'pending0001',
        title: 'Too late',
        artists: const ['Artist'],
      ),
    ]);
    await searchFuture;

    final search = container.read(searchControllerProvider).value!;
    expect(search.hasQuery, isFalse);
    expect(search.pages, isEmpty);
    expect(search.selectedCategory, SearchCategory.songs);
  });

  test('album track provider caches a browse lookup', () async {
    final catalog = _FakeCatalog(
      albumSongs: [
        InnerTubeSong(
          videoId: 'albumtrack1',
          title: 'Album track',
          artists: const ['Artist'],
        ),
      ],
    );
    final container = _container(catalog, _FakeDownloaderService());
    addTearDown(container.dispose);

    final first = await container.read(
      searchAlbumTracksProvider('MPREalbum001').future,
    );
    final second = await container.read(
      searchAlbumTracksProvider('MPREalbum001').future,
    );

    expect(first.single.id, 'albumtrack1');
    expect(second, same(first));
    expect(catalog.albumBrowseIds, ['MPREalbum001']);
    expect(catalog.lastAlbumLimit, innerTubeDetailResultLimit);
  });
}

ProviderContainer _container(
  _FakeCatalog catalog,
  _FakeDownloaderService downloader,
) {
  final dataSource = RemoteMusicDataSource(
    downloader,
    youtubeMusicSearch: catalog,
  );
  return ProviderContainer(
    overrides: [remoteMusicDataSourceProvider.overrideWithValue(dataSource)],
  );
}

class _FakeCatalog
    implements
        YouTubeMusicSearch,
        YouTubeMusicCatalogSearch,
        YouTubeMusicArtistSearch,
        YouTubeMusicAlbumLookup {
  _FakeCatalog({
    this.songResults = const [],
    this.videoResults = const [],
    this.albumResults = const [],
    this.artistResults = const [],
    this.albumSongs = const [],
    this.songLoader,
    this.videoLoader,
    this.albumError,
  });

  final List<InnerTubeSong> songResults;
  final List<InnerTubeSong> videoResults;
  final List<InnerTubeAlbum> albumResults;
  final List<InnerTubeArtist> artistResults;
  final List<InnerTubeSong> albumSongs;
  final Future<List<InnerTubeSong>> Function(String query)? songLoader;
  final Future<List<InnerTubeSong>> Function(String query)? videoLoader;
  final Object? albumError;
  final List<String> songQueries = [];
  final List<String> videoQueries = [];
  final List<String> albumQueries = [];
  final List<String> artistQueries = [];
  final List<String> albumBrowseIds = [];
  int? lastAlbumLimit;

  @override
  Future<List<InnerTubeSong>> searchSongs(
    String query, {
    int limit = 20,
  }) async {
    songQueries.add(query);
    final loader = songLoader;
    return loader == null ? songResults : loader(query);
  }

  @override
  Future<List<InnerTubeSong>> searchVideos(
    String query, {
    int limit = 20,
  }) async {
    videoQueries.add(query);
    final loader = videoLoader;
    return loader == null ? videoResults : loader(query);
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
  Future<List<InnerTubeArtist>> searchArtists(
    String query, {
    int limit = 20,
  }) async {
    artistQueries.add(query);
    return artistResults;
  }

  @override
  Future<List<InnerTubeSong>> getAlbumSongs(
    String browseId, {
    int limit = 20,
  }) async {
    albumBrowseIds.add(browseId);
    lastAlbumLimit = limit;
    return albumSongs;
  }
}

class _FakeDownloaderService implements DownloaderService {
  _FakeDownloaderService({this.searchResults = const [], this.searchError});

  final List<TrackInfo> searchResults;
  final Object? searchError;
  final List<String> searchQueries = [];
  int getInfoCalls = 0;
  int getPlaybackInfoCalls = 0;

  @override
  Stream<DownloadProgress> get progressStream => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TrackInfo>> search(String query) async {
    searchQueries.add(query);
    final failure = searchError;
    if (failure != null) {
      throw failure;
    }
    return searchResults;
  }

  @override
  Future<TrackInfo> getInfo(String url) {
    getInfoCalls++;
    throw StateError('Search must not resolve track information.');
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) {
    getPlaybackInfoCalls++;
    throw StateError('Search must not resolve playback information.');
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    throw UnimplementedError();
  }
}
