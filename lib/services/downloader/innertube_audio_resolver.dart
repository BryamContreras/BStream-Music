import '../../features/music/domain/entities/track_info.dart';
import '../youtube_music/playback/innertube_playback_service.dart';
import '../youtube_music/playback/innertube_video_id.dart';
import 'audio_stream_resolver.dart';

/// Application adapter for the Dart-only InnerTube playback engine.
final class InnerTubeAudioResolver
    implements
        AudioStreamResolver,
        ContinuationAwareAudioStreamResolver,
        FallbackAwareAudioStreamResolver {
  InnerTubeAudioResolver(this._playback, {this.disposePlaybackService = false});

  final InnerTubePlaybackService _playback;
  final bool disposePlaybackService;
  bool _disposed = false;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) =>
      resolveWithMode(track);

  @override
  Future<AudioStreamResolution> resolveWhileCurrent(
    TrackInfo track, {
    AudioResolverContinuationCallback? shouldContinue,
  }) => resolveWithMode(track, shouldContinue: shouldContinue);

  @override
  Future<AudioStreamResolution> resolveWithMode(
    TrackInfo track, {
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  }) async {
    if (_disposed) {
      throw const AudioStreamResolverException(
        'The InnerTube audio resolver is disposed.',
      );
    }
    final sourceReference = track.url.trim();
    final idReference = track.id.trim();
    final reference = InnerTubeVideoId.extract(sourceReference) != null
        ? sourceReference
        : idReference;
    if (InnerTubeVideoId.extract(reference) == null) {
      throw const AudioStreamResolverException(
        'InnerTube requires a YouTube URL or video ID.',
      );
    }
    final source = mode == AudioResolutionMode.fallbackOnly
        ? AudioStreamSource.innerTubeFallback
        : AudioStreamSource.innerTube;
    try {
      final previousProfile = track.streamClientProfileKey?.trim();
      final resolved = await _playback.resolve(
        reference,
        skipPrimary: mode == AudioResolutionMode.fallbackOnly,
        excludedProfileKeys:
            mode == AudioResolutionMode.fallbackOnly &&
                previousProfile != null &&
                previousProfile.isNotEmpty
            ? <String>{previousProfile}
            : const <String>{},
        shouldContinue: shouldContinue,
      );
      return AudioStreamResolution(
        source: source,
        streamUrl: resolved.uri.toString(),
        streamExtension: resolved.extension,
        streamMimeType: resolved.format.mimeType,
        httpHeaders: resolved.headers,
        videoId: resolved.videoId,
        formatId: resolved.format.itag.toString(),
        codec: resolved.codec,
        clientProfileKey: resolved.profile.key,
        expiresAt: resolved.expiresAt,
      );
    } catch (error) {
      onResolverFailure?.call(source, error);
      if (error is AudioStreamResolverException) rethrow;
      throw AudioStreamResolverException(
        'InnerTube could not resolve a playable audio stream.',
        cause: error,
      );
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (disposePlaybackService) await _playback.dispose();
  }
}
