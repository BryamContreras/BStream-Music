import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/domain/repositories/music_repository.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'preserves the extractor error when no playable stream exists',
    () async {
      const error = DownloaderException(
        'YouTube extraction failed.',
        code: 'ytdl_error',
      );
      final repository = _FakeMusicRepository(error: error);
      final container = ProviderContainer(
        overrides: [musicRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      const track = TrackInfo(
        id: 'video-id',
        title: 'Track',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=video-id',
      );

      await expectLater(
        container.read(remoteTrackResolverProvider).resolve(track),
        throwsA(same(error)),
      );

      // A failed future must not poison the resolver cache.
      await expectLater(
        container.read(remoteTrackResolverProvider).resolve(track),
        throwsA(same(error)),
      );
      expect(repository.infoCalls, 2);
    },
  );

  test('falls back to the original track only when it is playable', () async {
    const error = DownloaderException(
      'Could not refresh the stream.',
      code: 'ytdl_error',
    );
    final repository = _FakeMusicRepository(error: error);
    final container = ProviderContainer(
      overrides: [musicRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    const track = TrackInfo(
      id: 'video-id',
      title: 'Track',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=video-id',
      streamUrl: 'https://media.example/audio.m4a',
    );

    final resolved = await container
        .read(remoteTrackResolverProvider)
        .resolve(track, forceRefresh: true);

    expect(resolved, same(track));
    expect(repository.infoCalls, 1);
  });

  test('does not reuse a stream already rejected by the player', () async {
    const error = DownloaderException(
      'Could not refresh the stream.',
      code: 'ytdl_error',
    );
    final repository = _FakeMusicRepository(error: error);
    final container = ProviderContainer(
      overrides: [musicRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    const track = TrackInfo(
      id: 'q8j3zwNhLNo',
      title: 'YO SOY TU TITAN',
      artist: 'Pamorkil',
      url: 'https://www.youtube.com/watch?v=q8j3zwNhLNo',
      streamUrl: 'https://media.example/rejected.m4a',
    );

    await expectLater(
      container
          .read(remoteTrackResolverProvider)
          .resolve(track, forceRefresh: true, allowStaleStreamFallback: false),
      throwsA(same(error)),
    );
    expect(repository.infoCalls, 1);
  });

  test('does not persist signed streams on Android', () async {
    SharedPreferences.setMockInitialValues({
      'remote_track_resolution_cache_v2': '{"stale":{}}',
    });
    final repository = _SuccessfulMusicRepository(includeStream: true);
    final container = ProviderContainer(
      overrides: [
        musicRepositoryProvider.overrideWithValue(repository),
        remoteTrackResolverProvider.overrideWith(
          (ref) => RemoteTrackResolver(ref, isAndroid: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    const track = TrackInfo(
      id: 'android-video',
      title: 'Android track',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=android-video',
    );

    await container.read(remoteTrackResolverProvider).resolve(track);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('remote_track_resolution_cache_v2'), isNull);

    final secondContainer = ProviderContainer(
      overrides: [
        musicRepositoryProvider.overrideWithValue(repository),
        remoteTrackResolverProvider.overrideWith(
          (ref) => RemoteTrackResolver(ref, isAndroid: true),
        ),
      ],
    );
    addTearDown(secondContainer.dispose);
    await secondContainer.read(remoteTrackResolverProvider).resolve(track);

    expect(repository.infoCalls, 2);
  });

  test(
    'keeps the RAM cache bounded and evicts its oldest resolutions',
    () async {
      final repository = _SuccessfulMusicRepository();
      final container = ProviderContainer(
        overrides: [musicRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final resolver = container.read(remoteTrackResolverProvider);
      final tracks = List.generate(
        40,
        (index) => TrackInfo(
          id: 'video-$index',
          title: 'Track $index',
          artist: 'Artist',
          url: 'https://www.youtube.com/watch?v=video-$index',
        ),
      );

      for (final track in tracks) {
        await resolver.resolve(track);
      }
      expect(repository.infoCalls, 40);

      // The newest 32 entries (8 through 39) remain available without another
      // extractor call. Looking them up must not accidentally grow the cache.
      for (var index = 39; index >= 8; index--) {
        final resolved = await resolver.resolve(tracks[index]);
        expect(resolved.id, tracks[index].id);
      }
      expect(repository.infoCalls, 40);

      // Entry 7 belongs to the eight oldest items and must have been evicted.
      await resolver.resolve(tracks[7]);
      expect(repository.infoCalls, 41);

      // The newly resolved item and a recent item remain cached after trimming.
      await resolver.resolve(tracks[7]);
      await resolver.resolve(tracks.last);
      expect(repository.infoCalls, 41);
    },
  );
}

class _FakeMusicRepository implements MusicRepository {
  _FakeMusicRepository({required this.error});

  final Object error;
  int infoCalls = 0;

  @override
  Future<TrackInfo> getInfo(String url) async {
    infoCalls++;
    throw error;
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) => getInfo(url);

  @override
  Future<List<TrackInfo>> search(String query) {
    throw UnimplementedError();
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    throw UnimplementedError();
  }
}

class _SuccessfulMusicRepository implements MusicRepository {
  _SuccessfulMusicRepository({this.includeStream = false});

  final bool includeStream;
  int infoCalls = 0;

  @override
  Future<TrackInfo> getInfo(String url) async {
    infoCalls++;
    final id = Uri.parse(url).queryParameters['v'] ?? '';
    return TrackInfo(
      id: id,
      title: 'Resolved $id',
      artist: 'Resolved artist',
      url: url,
      streamUrl: includeStream ? 'https://media.example/$id.m4a' : null,
      // The default omits a stream URL so cache-size tests stay independent
      // from the persistent SharedPreferences cache.
    );
  }

  @override
  Future<TrackInfo> getPlaybackInfo(String url) => getInfo(url);

  @override
  Future<List<TrackInfo>> search(String query) {
    throw UnimplementedError();
  }

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) {
    throw UnimplementedError();
  }
}
