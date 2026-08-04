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
