import 'dart:async';
import 'dart:convert';

import 'package:bstream_music/core/errors/app_exception.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'coalesces concurrent persistent-cache loads before resolving',
    () async {
      final now = DateTime.now();
      SharedPreferences.setMockInitialValues({
        'remote_track_resolution_cache_v6': jsonEncode({
          'youtube:abcdefghijk': {
            'createdAt': now.millisecondsSinceEpoch,
            'expiresAt': now
                .add(const Duration(minutes: 10))
                .millisecondsSinceEpoch,
            'track': {
              'id': 'abcdefghijk',
              'title': 'Persisted track',
              'artist': 'Persisted artist',
              'url': 'https://www.youtube.com/watch?v=abcdefghijk',
              'streamUrl': 'https://media.example/persisted.m4a',
              'stream_extension': 'm4a',
              'stream_mime_type': 'audio/mp4',
              'stream_source': AudioStreamSource.innerTube.name,
              'stream_client_profile_key': 'androidSdkless',
            },
          },
        }),
      });
      final resolver = _FakeAudioResolver(includeStream: true);
      final container = ProviderContainer(
        overrides: [
          audioStreamResolverProvider.overrideWithValue(resolver),
          remoteTrackResolverProvider.overrideWith(
            (ref) => RemoteTrackResolver(ref, useMobileCachePolicy: false),
          ),
        ],
      );
      addTearDown(container.dispose);
      const track = TrackInfo(
        id: 'abcdefghijk',
        title: 'Current metadata',
        artist: 'Current artist',
        url: 'https://www.youtube.com/watch?v=abcdefghijk',
      );
      final controller = container.read(remoteTrackResolverProvider);

      final results = await Future.wait(<Future<TrackInfo>>[
        controller.resolve(track),
        controller.resolve(track),
      ]);

      expect(
        results.map((value) => value.streamUrl),
        everyElement('https://media.example/persisted.m4a'),
      );
      expect(resolver.resolveCalls, 0);
    },
  );

  test('preserves the resolver error when no playable stream exists', () async {
    const error = DownloaderException(
      'YouTube extraction failed.',
      code: 'innertube_playback_failed',
    );
    final resolver = _FakeAudioResolver(error: error);
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
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
    expect(resolver.resolveCalls, 2);
  });

  test('falls back to the original track only when it is playable', () async {
    const error = DownloaderException(
      'Could not refresh the stream.',
      code: 'innertube_playback_failed',
    );
    final resolver = _FakeAudioResolver(error: error);
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
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
    expect(resolver.resolveCalls, 1);
  });

  test('does not reuse a stream already rejected by the player', () async {
    const error = DownloaderException(
      'Could not refresh the stream.',
      code: 'innertube_playback_failed',
    );
    final resolver = _FakeAudioResolver(error: error);
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
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
    expect(resolver.resolveCalls, 1);
  });

  test(
    'fallback resolution clears headers from the rejected direct URL',
    () async {
      final resolver = _FallbackFileAudioResolver();
      final container = ProviderContainer(
        overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
      );
      addTearDown(container.dispose);

      const track = TrackInfo(
        id: 'video-id',
        title: 'Track',
        artist: 'Artist',
        url: 'https://www.youtube.com/watch?v=video-id',
        streamUrl: 'https://googlevideo.example/rejected',
        streamExtension: 'webm',
        streamMimeType: 'audio/webm',
        streamSource: 'innerTube',
        httpHeaders: {'User-Agent': 'rejected-stream-agent'},
      );

      final resolved = await container
          .read(remoteTrackResolverProvider)
          .resolve(track, forceRefresh: true, allowStaleStreamFallback: false);

      expect(resolved.streamUrl, 'file:///cache/video-id.140.m4a');
      expect(resolved.streamExtension, 'm4a');
      expect(resolved.streamMimeType, 'audio/mp4');
      expect(resolved.streamClientProfileKey, 'visionOS');
      expect(resolved.streamSource, AudioStreamSource.innerTubeFallback.name);
      expect(resolved.httpHeaders, isNull);
    },
  );

  test('does not persist signed streams on mobile', () async {
    SharedPreferences.setMockInitialValues({
      'remote_track_resolution_cache_v2': '{"stale":{}}',
      'remote_track_resolution_cache_v3': '{"stale":{}}',
      'remote_track_resolution_cache_v4': '{"stale":{}}',
      'remote_track_resolution_cache_v5': '{"stale":{}}',
      'remote_track_resolution_cache_v6': '{"stale":{}}',
    });
    final resolver = _FakeAudioResolver(includeStream: true);
    final container = ProviderContainer(
      overrides: [
        audioStreamResolverProvider.overrideWithValue(resolver),
        remoteTrackResolverProvider.overrideWith(
          (ref) => RemoteTrackResolver(ref, useMobileCachePolicy: true),
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
    expect(prefs.getString('remote_track_resolution_cache_v3'), isNull);
    expect(prefs.getString('remote_track_resolution_cache_v4'), isNull);
    expect(prefs.getString('remote_track_resolution_cache_v5'), isNull);
    expect(prefs.getString('remote_track_resolution_cache_v6'), isNull);
    expect(resolver.resolveCalls, 1);

    final secondContainer = ProviderContainer(
      overrides: [
        audioStreamResolverProvider.overrideWithValue(resolver),
        remoteTrackResolverProvider.overrideWith(
          (ref) => RemoteTrackResolver(ref, useMobileCachePolicy: true),
        ),
      ],
    );
    addTearDown(secondContainer.dispose);
    await secondContainer.read(remoteTrackResolverProvider).resolve(track);

    expect(resolver.resolveCalls, 2);
  });

  test('does not reuse an in-memory stream past its signed expiry', () async {
    final resolver = _FakeAudioResolver(
      includeStream: true,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final container = ProviderContainer(
      overrides: [
        audioStreamResolverProvider.overrideWithValue(resolver),
        remoteTrackResolverProvider.overrideWith(
          (ref) => RemoteTrackResolver(ref, useMobileCachePolicy: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    const track = TrackInfo(
      id: 'expiry-test',
      title: 'Expiry test',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=expiry-test',
    );

    await container.read(remoteTrackResolverProvider).resolve(track);
    await container.read(remoteTrackResolverProvider).resolve(track);

    expect(resolver.resolveCalls, 2);
  });

  test('persists signed expiry alongside the cached track entry', () async {
    final expiresAt = DateTime.now().add(const Duration(minutes: 8));
    final resolver = _FakeAudioResolver(
      includeStream: true,
      expiresAt: expiresAt,
      clientProfileKey: 'androidSdkless',
    );
    final container = ProviderContainer(
      overrides: [
        audioStreamResolverProvider.overrideWithValue(resolver),
        remoteTrackResolverProvider.overrideWith(
          (ref) => RemoteTrackResolver(ref, useMobileCachePolicy: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    const track = TrackInfo(
      id: 'expirycache',
      title: 'Cached expiry',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=expirycache',
    );

    await container.read(remoteTrackResolverProvider).resolve(track);
    final prefs = await SharedPreferences.getInstance();
    String? raw;
    for (var attempt = 0; attempt < 20 && raw == null; attempt++) {
      await Future<void>.delayed(Duration.zero);
      raw = prefs.getString('remote_track_resolution_cache_v6');
    }

    final cache = jsonDecode(raw!) as Map<String, dynamic>;
    final entry = cache.values.single as Map<String, dynamic>;
    final cachedTrack = entry['track'] as Map<String, dynamic>;
    expect(entry['expiresAt'], expiresAt.millisecondsSinceEpoch);
    expect(cachedTrack['stream_client_profile_key'], 'androidSdkless');
  });

  test('local TTL expires an entry before a later signed expiry', () async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'remote_track_resolution_cache_v6': jsonEncode({
        'youtube:abcdefghijk': {
          'createdAt': now
              .subtract(const Duration(minutes: 21))
              .millisecondsSinceEpoch,
          'expiresAt': now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
          'track': {
            'id': 'abcdefghijk',
            'title': 'Stale track',
            'artist': 'Artist',
            'url': 'https://www.youtube.com/watch?v=abcdefghijk',
            'streamUrl': 'https://media.example/stale.m4a',
            'stream_source': AudioStreamSource.innerTube.name,
            'stream_client_profile_key': 'androidSdkless',
          },
        },
      }),
    });
    final resolver = _FakeAudioResolver(includeStream: true);
    final container = ProviderContainer(
      overrides: [
        audioStreamResolverProvider.overrideWithValue(resolver),
        remoteTrackResolverProvider.overrideWith(
          (ref) => RemoteTrackResolver(ref, useMobileCachePolicy: false),
        ),
      ],
    );
    addTearDown(container.dispose);
    const track = TrackInfo(
      id: 'abcdefghijk',
      title: 'Current track',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=abcdefghijk',
    );

    final resolved = await container
        .read(remoteTrackResolverProvider)
        .resolve(track);

    expect(resolved.streamUrl, 'https://media.example/abcdefghijk.m4a');
    expect(resolver.resolveCalls, 1);
  });

  test(
    'keeps the RAM cache bounded and evicts its oldest resolutions',
    () async {
      final resolver = _FakeAudioResolver();
      final container = ProviderContainer(
        overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
      );
      addTearDown(container.dispose);
      final resolverController = container.read(remoteTrackResolverProvider);
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
        await resolverController.resolve(track);
      }
      expect(resolver.resolveCalls, 40);

      // The newest 32 entries (8 through 39) remain available without another
      // extractor call. Looking them up must not accidentally grow the cache.
      for (var index = 39; index >= 8; index--) {
        final resolved = await resolverController.resolve(tracks[index]);
        expect(resolved.id, tracks[index].id);
      }
      expect(resolver.resolveCalls, 40);

      // Entry 7 belongs to the eight oldest items and must have been evicted.
      await resolverController.resolve(tracks[7]);
      expect(resolver.resolveCalls, 41);

      // The newly resolved item and a recent item remain cached after trimming.
      await resolverController.resolve(tracks[7]);
      await resolverController.resolve(tracks.last);
      expect(resolver.resolveCalls, 41);
    },
  );

  test(
    'keeps YouTube Music metadata while the resolver supplies transport',
    () async {
      final resolver = _MetadataOverwritingResolver();
      final container = ProviderContainer(
        overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
      );
      addTearDown(container.dispose);
      const track = TrackInfo(
        id: 'DlFXDl_ROAM',
        title: 'Die With A Smile',
        artist: 'Lady Gaga, Bruno Mars',
        artists: ['Lady Gaga', 'Bruno Mars'],
        album: 'MAYHEM',
        albumBrowseId: 'MPREb_album_mayhem',
        duration: Duration(minutes: 4, seconds: 12),
        thumbnailUrl: 'https://music.example/canonical.jpg',
        url: 'https://www.youtube.com/watch?v=DlFXDl_ROAM',
        metadataSource: TrackMetadataSource.youtubeMusic,
      );

      final resolved = await container
          .read(remoteTrackResolverProvider)
          .resolve(track);

      expect(resolved.id, track.id);
      expect(resolved.title, track.title);
      expect(resolved.artist, track.artist);
      expect(resolved.artists, track.artists);
      expect(resolved.album, track.album);
      expect(resolved.albumBrowseId, track.albumBrowseId);
      expect(resolved.duration, track.duration);
      expect(resolved.thumbnailUrl, track.thumbnailUrl);
      expect(resolved.metadataSource, TrackMetadataSource.youtubeMusic);
      expect(resolved.streamUrl, 'https://media.example/audio.m4a');
      expect(resolved.streamExtension, 'm4a');
      expect(resolved.streamMimeType, 'audio/mp4');
      expect(resolved.httpHeaders, {'User-Agent': 'stream-agent'});
    },
  );

  test('fills only missing YouTube Music metadata from playback', () async {
    final resolver = _MetadataOverwritingResolver();
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
    );
    addTearDown(container.dispose);
    const track = TrackInfo(
      id: 'DlFXDl_ROAM',
      title: 'Canonical catalog title',
      artist: 'Desconocido',
      url: 'https://www.youtube.com/watch?v=DlFXDl_ROAM',
      catalogThumbnailUrl: 'https://music.example/catalog.jpg',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );

    final resolved = await container
        .read(remoteTrackResolverProvider)
        .resolve(track);

    expect(resolved.id, track.id);
    expect(resolved.title, track.title);
    expect(resolved.artist, track.artist);
    expect(resolved.artists, track.artists);
    expect(resolved.album, track.album);
    expect(resolved.duration, track.duration);
    expect(resolved.thumbnailUrl, track.thumbnailUrl);
    expect(resolved.catalogThumbnailUrl, track.catalogThumbnailUrl);
    expect(resolved.metadataSource, TrackMetadataSource.youtubeMusic);
    expect(resolved.streamUrl, 'https://media.example/audio.m4a');
    expect(resolved.streamExtension, 'm4a');
    expect(resolved.streamMimeType, 'audio/mp4');
    expect(resolved.httpHeaders, {'User-Agent': 'stream-agent'});
  });

  test('a cached stream adopts newer YouTube Music metadata', () async {
    final resolver = _MetadataOverwritingResolver();
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
    );
    addTearDown(container.dispose);
    final controller = container.read(remoteTrackResolverProvider);
    const first = TrackInfo(
      id: 'video-id',
      title: 'First catalog title',
      artist: 'First artist',
      artists: ['First artist'],
      url: 'https://www.youtube.com/watch?v=video-id',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );
    const updated = TrackInfo(
      id: 'video-id',
      title: 'Updated catalog title',
      artist: 'First artist, Guest',
      artists: ['First artist', 'Guest'],
      album: 'Updated album',
      url: 'https://www.youtube.com/watch?v=video-id',
      metadataSource: TrackMetadataSource.youtubeMusic,
    );

    await controller.resolve(first);
    final cached = await controller.resolve(updated);

    expect(resolver.resolveCalls, 1);
    expect(cached.title, updated.title);
    expect(cached.artist, updated.artist);
    expect(cached.artists, updated.artists);
    expect(cached.album, updated.album);
    expect(cached.streamUrl, 'https://media.example/audio.m4a');
  });

  test('equivalent YouTube URLs share the same in-flight resolution', () async {
    final resolver = _FakeAudioResolver(includeStream: true);
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
    );
    addTearDown(container.dispose);
    final controller = container.read(remoteTrackResolverProvider);
    const shortUrl = TrackInfo(
      id: 'abcdefghijk',
      title: 'Track',
      artist: 'Artist',
      url: 'https://youtu.be/abcdefghijk',
    );
    const watchUrl = TrackInfo(
      id: 'abcdefghijk',
      title: 'Track',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=abcdefghijk',
    );

    await controller.resolve(shortUrl);
    await controller.resolve(watchUrl);

    expect(resolver.resolveCalls, 1);
  });

  test('an obsolete failure cannot evict a newer forced resolution', () async {
    final resolver = _ControllableAudioResolver();
    final container = ProviderContainer(
      overrides: [audioStreamResolverProvider.overrideWithValue(resolver)],
    );
    addTearDown(container.dispose);
    final controller = container.read(remoteTrackResolverProvider);
    const track = TrackInfo(
      id: 'abcdefghijk',
      title: 'Track',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=abcdefghijk',
    );

    final first = controller.resolve(
      track,
      forceRefresh: true,
      allowStaleStreamFallback: false,
    );
    await resolver.waitForCalls(1);
    final second = controller.resolve(
      track,
      forceRefresh: true,
      allowStaleStreamFallback: false,
    );
    await resolver.waitForCalls(2);
    expect(resolver.resolveCalls, 2);

    final firstFailure = expectLater(first, throwsA(isA<StateError>()));
    resolver.requests.first.completeError(StateError('obsolete failure'));
    await firstFailure;

    final third = controller.resolve(track);
    expect(resolver.resolveCalls, 2);
    resolver.requests[1].complete(
      const AudioStreamResolution(
        source: AudioStreamSource.innerTube,
        streamUrl: 'https://media.example/current.m4a',
      ),
    );

    expect((await second).streamUrl, 'https://media.example/current.m4a');
    expect((await third).streamUrl, 'https://media.example/current.m4a');
    expect(resolver.resolveCalls, 2);
  });

  test('retries with the fallback when the primary resolver fails', () async {
    final fallback = _FakeAudioResolver(
      includeStream: true,
      source: AudioStreamSource.innerTubeFallback,
    );
    final primary = _FailingAudioResolver();
    final container = ProviderContainer(
      overrides: [
        audioStreamResolverProvider.overrideWithValue(
          _ChainedResolver([primary, fallback]),
        ),
      ],
    );
    addTearDown(container.dispose);

    const track = TrackInfo(
      id: 'video-id',
      title: 'Track',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=video-id',
    );

    final resolved = await container
        .read(remoteTrackResolverProvider)
        .resolve(track);

    expect(resolved.streamUrl, 'https://media.example/video-id.m4a');
    expect(primary.resolveCalls, 1);
    expect(fallback.resolveCalls, 1);
  });

  test('returns the primary result when it is usable', () async {
    final primary = _FakeAudioResolver(
      includeStream: true,
      source: AudioStreamSource.innerTube,
    );
    final fallback = _FakeAudioResolver(
      includeStream: true,
      source: AudioStreamSource.innerTubeFallback,
    );
    final container = ProviderContainer(
      overrides: [
        audioStreamResolverProvider.overrideWithValue(
          _ChainedResolver([primary, fallback]),
        ),
      ],
    );
    addTearDown(container.dispose);

    const track = TrackInfo(
      id: 'video-id',
      title: 'Track',
      artist: 'Artist',
      url: 'https://www.youtube.com/watch?v=video-id',
    );

    final resolved = await container
        .read(remoteTrackResolverProvider)
        .resolve(track);

    expect(resolved.streamUrl, 'https://media.example/video-id.m4a');
    expect(primary.resolveCalls, 1);
    expect(fallback.resolveCalls, 0);
  });
}

class _FakeAudioResolver implements AudioStreamResolver {
  _FakeAudioResolver({
    this.error,
    this.includeStream = false,
    this.source = AudioStreamSource.innerTube,
    this.expiresAt,
    this.clientProfileKey = 'androidSdkless',
  });

  final Object? error;
  final bool includeStream;
  final AudioStreamSource source;
  final DateTime? expiresAt;
  final String? clientProfileKey;

  int resolveCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    resolveCalls++;
    if (error != null) {
      throw error!;
    }
    if (!includeStream) {
      return AudioStreamResolution(source: source, streamUrl: '');
    }
    final id = Uri.parse(track.url).queryParameters['v'] ?? track.id;
    return AudioStreamResolution(
      source: source,
      streamUrl: 'https://media.example/$id.m4a',
      streamExtension: 'm4a',
      streamMimeType: 'audio/mp4',
      clientProfileKey: clientProfileKey,
      expiresAt: expiresAt,
    );
  }

  @override
  Future<void> dispose() async {}
}

class _FallbackFileAudioResolver implements AudioStreamResolver {
  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    return const AudioStreamResolution(
      source: AudioStreamSource.innerTubeFallback,
      streamUrl: 'file:///cache/video-id.140.m4a',
      streamExtension: 'm4a',
      streamMimeType: 'audio/mp4',
      clientProfileKey: 'visionOS',
      formatId: '140',
      codec: 'mp4a.40.2',
    );
  }

  @override
  Future<void> dispose() async {}
}

class _ControllableAudioResolver implements AudioStreamResolver {
  final List<Completer<AudioStreamResolution>> requests = [];

  int get resolveCalls => requests.length;

  Future<void> waitForCalls(int count) async {
    while (requests.length < count) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) {
    final request = Completer<AudioStreamResolution>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<void> dispose() async {}
}

class _FailingAudioResolver implements AudioStreamResolver {
  int resolveCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    resolveCalls++;
    throw const AudioStreamResolverException('Primary unavailable');
  }

  @override
  Future<void> dispose() async {}
}

class _MetadataOverwritingResolver implements AudioStreamResolver {
  int resolveCalls = 0;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    resolveCalls++;
    return AudioStreamResolution(
      source: AudioStreamSource.innerTubeFallback,
      streamUrl: 'https://media.example/audio.m4a',
      streamExtension: 'm4a',
      streamMimeType: 'audio/mp4',
      httpHeaders: const {'User-Agent': 'stream-agent'},
      formatId: 'youtube',
    );
  }

  @override
  Future<void> dispose() async {}
}

class _ChainedResolver implements AudioStreamResolver {
  _ChainedResolver(this._resolvers);

  final List<AudioStreamResolver> _resolvers;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    Object? lastError;
    for (final resolver in _resolvers) {
      try {
        final result = await resolver.resolve(track);
        if (result.isUsable) {
          return result;
        }
      } catch (error) {
        lastError = error;
      }
    }
    throw AudioStreamResolverException(
      'No resolver produced a usable stream.',
      cause: lastError,
    );
  }

  @override
  Future<void> dispose() async {
    for (final resolver in _resolvers) {
      await resolver.dispose();
    }
  }
}
