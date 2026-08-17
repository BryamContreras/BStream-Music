import 'dart:async';
import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../features/music/domain/entities/track_info.dart';
import '../../audio_stream_resolver.dart';
import 'youtube_audio_stream_selector.dart';

typedef YoutubePlaybackHttpClientFactory = HttpClient Function();

/// Failure raised when a selected GoogleVideo URL cannot provide audio bytes.
class YoutubePlaybackStreamValidationException implements Exception {
  const YoutubePlaybackStreamValidationException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'YoutubePlaybackStreamValidationException: $message$status';
  }
}

/// Performs a bounded byte probe against the exact stream given to the player.
///
/// A streamed GET is used instead of HEAD because GoogleVideo may expose a
/// working muxed URL while rejecting a separate audio-only format. Only the
/// first non-empty response chunk is consumed; the connection is then closed.
class YoutubePlaybackStreamValidator {
  YoutubePlaybackStreamValidator({
    required Map<String, String> headers,
    this.timeout = const Duration(seconds: 4),
    YoutubePlaybackHttpClientFactory? clientFactory,
  }) : headers = Map<String, String>.unmodifiable(headers),
       _clientFactory = clientFactory ?? HttpClient.new {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }
  }

  final Map<String, String> headers;
  final Duration timeout;
  final YoutubePlaybackHttpClientFactory _clientFactory;

  Future<void> validate(AudioOnlyStreamInfo stream) async {
    final client = _clientFactory()..connectionTimeout = timeout;
    try {
      await _validate(client, stream.url).timeout(
        timeout,
        onTimeout: () => throw YoutubePlaybackStreamValidationException(
          'The selected audio stream did not respond in time.',
          cause: TimeoutException('Audio stream probe timed out.', timeout),
        ),
      );
    } on YoutubePlaybackStreamValidationException {
      rethrow;
    } catch (error) {
      throw YoutubePlaybackStreamValidationException(
        'The selected audio stream could not be opened.',
        cause: error,
      );
    } finally {
      // Also cancels a request that outlived Future.timeout.
      client.close(force: true);
    }
  }

  Future<void> _validate(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');

    final response = await request.close();
    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      throw YoutubePlaybackStreamValidationException(
        'The selected audio stream was rejected.',
        statusCode: response.statusCode,
      );
    }

    final iterator = StreamIterator<List<int>>(response);
    try {
      while (await iterator.moveNext()) {
        if (iterator.current.isNotEmpty) {
          return;
        }
      }
    } finally {
      await iterator.cancel();
    }
    throw const YoutubePlaybackStreamValidationException(
      'The selected audio stream returned no bytes.',
    );
  }
}

/// Resolves a playable audio stream using the YouTube manifest.
///
/// The resolver only handles YouTube URLs and IDs. Non-YouTube inputs are
/// rejected by throwing a [AudioStreamResolverException] so the caller can
/// fall back to another resolver.
class YoutubeExplodeAudioResolver implements AudioStreamResolver {
  YoutubeExplodeAudioResolver({
    YoutubeExplode? client,
    YoutubeSelectedAudioValidator? validatePlaybackStream,
    Map<String, String> playbackHttpHeaders = YoutubeHttpClient.defaultHeaders,
    this.playbackProbeTimeout = const Duration(seconds: 4),
  }) : _injectedClient = client,
       _playbackHttpHeaders = Map<String, String>.unmodifiable(
         playbackHttpHeaders,
       ),
       _injectedPlaybackValidator = validatePlaybackStream;

  final YoutubeExplode? _injectedClient;
  final Map<String, String> _playbackHttpHeaders;
  final YoutubeSelectedAudioValidator? _injectedPlaybackValidator;
  final Duration playbackProbeTimeout;
  YoutubeExplode? _ownedClient;
  Future<YoutubeExplode>? _clientFuture;
  YoutubeSelectedAudioValidator? _ownedPlaybackValidator;
  bool _disposed = false;

  YoutubeSelectedAudioValidator get _validatePlaybackStream {
    final injected = _injectedPlaybackValidator;
    if (injected != null) {
      return injected;
    }
    return _ownedPlaybackValidator ??= YoutubePlaybackStreamValidator(
      headers: _playbackHttpHeaders,
      timeout: playbackProbeTimeout,
    ).validate;
  }

  YoutubeExplode get _client {
    final owned = _ownedClient;
    if (owned != null) {
      return owned;
    }
    final injected = _injectedClient;
    if (injected != null) {
      return injected;
    }
    final created = YoutubeExplode();
    _ownedClient = created;
    return created;
  }

  Future<YoutubeExplode> _ensureClient() {
    if (_disposed) {
      throw StateError('YoutubeExplodeAudioResolver was disposed.');
    }
    return _clientFuture ??= Future<YoutubeExplode>.value(_client);
  }

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    final videoId = _parseYouTubeVideoId(track);
    if (videoId == null) {
      throw const AudioStreamResolverException(
        'youtube_explode_dart only resolves YouTube URLs.',
      );
    }

    final client = await _ensureClient();
    try {
      final stream = await resolvePreferredYoutubeAudioStream(
        videoId: videoId,
        loadManifest: (videoId, ytClient, requireWatchPage) {
          return client.videos.streams.getManifest(
            videoId,
            ytClients: [ytClient],
            requireWatchPage: requireWatchPage,
          );
        },
        validateSelectedStream: _validatePlaybackStream,
        // A DASH base URL does not contain the fragment paths. The package can
        // assemble those for downloads, but native players only receive this
        // URL, so let yt-dlp handle manifests with no direct audio stream.
        requireDirectUrl: true,
      );
      final url = stream.url.toString();
      if (!url.startsWith('http')) {
        throw const AudioStreamResolverException(
          'Manifest returned a non-media URL.',
        );
      }
      return AudioStreamResolution(
        source: AudioStreamSource.youtubeExplode,
        streamUrl: url,
        streamExtension: youtubeAudioContainerExtension(stream.container),
        streamMimeType: youtubeAudioContainerMimeType(stream.container),
        httpHeaders: _playbackHttpHeaders,
        videoId: videoId.value,
        formatId: stream.tag.toString(),
        codec: stream.audioCodec,
      );
    } catch (error) {
      if (error is AudioStreamResolverException) {
        rethrow;
      }
      throw AudioStreamResolverException(
        'youtube_explode_dart failed to resolve the stream.',
        cause: error is YoutubeAudioManifestException
            ? (error.cause ?? error)
            : error,
      );
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final owned = _ownedClient;
    _ownedClient = null;
    _clientFuture = null;
    owned?.close();
  }

  static VideoId? _parseYouTubeVideoId(TrackInfo track) {
    final candidate = track.url.trim().isNotEmpty
        ? track.url
        : (track.id.trim().isNotEmpty ? track.id : null);
    if (candidate == null || candidate.isEmpty) {
      return null;
    }
    try {
      return VideoId.fromString(candidate);
    } catch (_) {
      return null;
    }
  }
}
