import '../../core/errors/app_exception.dart';
import '../../features/music/domain/entities/track_info.dart';

/// Produces the useful resolver/player message without transport wrappers.
String readableAudioStreamError(Object error) {
  if (error is AudioStreamResolverException) {
    final cause = error.cause;
    if (cause is AppException || cause is AudioStreamResolverException) {
      return readableAudioStreamError(cause!);
    }
    if (cause != null) {
      final detail = _cleanAudioErrorText(cause.toString());
      if (detail.isNotEmpty && detail != error.message) {
        return '${error.message}\n$detail';
      }
    }
    return _cleanAudioErrorText(error.message);
  }
  if (error is AppException) {
    return _cleanAudioErrorText(error.message);
  }
  return _cleanAudioErrorText(error.toString());
}

String _cleanAudioErrorText(String value) {
  var message = value.trim();
  // Resolver/player failures often include the complete signed GoogleVideo
  // URL. Its query can be several kilobytes long and contains short-lived
  // signatures that should not be rendered in the UI or copied in a screen
  // capture. Keep the useful host/path while removing query and fragment data.
  message = message.replaceAllMapped(
    RegExp(r'(https?://[^\s?#]+)(?:\?[^\s#]*)?(?:#[^\s]*)?'),
    (match) => match.group(1)!,
  );
  return message.trim();
}

/// Thrown when an [AudioStreamResolver] cannot produce a usable stream.
class AudioStreamResolverException implements Exception {
  const AudioStreamResolverException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) {
      return 'AudioStreamResolverException: $message';
    }
    return 'AudioStreamResolverException: $message ($cause)';
  }
}

/// Which resolver produced a playable stream for a track.
enum AudioStreamSource {
  /// The default InnerTube playback client path.
  innerTube,

  /// An InnerTube client selected after the default path was rejected.
  innerTubeFallback,
}

/// Controls which portion of a resolver chain may be used.
enum AudioResolutionMode {
  /// Start with the verified default InnerTube client, then try fallbacks.
  primaryThenFallback,

  /// Skip the default InnerTube client after the player rejected its URL.
  fallbackOnly,
}

typedef AudioResolverFailureCallback =
    void Function(AudioStreamSource source, Object error);

/// Returns whether an in-flight resolution is still useful to its caller.
///
/// Resolvers use this between clients so an obsolete request cannot start an
/// expensive challenge-backed fallback after the user selected another track
/// or replaced the queue.
typedef AudioResolverContinuationCallback = bool Function();

/// Result of resolving a playable audio stream for a [TrackInfo].
///
/// The contract is intentionally narrow: it only carries the transport data
/// that the player, cache, and downloader need. Catalog metadata like the
/// title, artist, or artwork is not modified here.
class AudioStreamResolution {
  const AudioStreamResolution({
    required this.source,
    required this.streamUrl,
    this.streamExtension,
    this.streamMimeType,
    this.httpHeaders,
    this.videoId,
    this.formatId,
    this.codec,
    this.clientProfileKey,
    this.expiresAt,
  });

  /// Which resolver produced this result.
  final AudioStreamSource source;

  /// Direct media URL or a local `file:` URI prepared by a managed fallback.
  final String streamUrl;

  /// Optional container extension (e.g. `m4a`, `webm`).
  final String? streamExtension;

  /// Optional MIME type for the media URL.
  final String? streamMimeType;

  /// Optional headers required to play the media URL.
  final Map<String, String>? httpHeaders;

  /// Optional YouTube video id when available.
  final String? videoId;

  /// Optional itag / format identifier.
  final String? formatId;

  /// Codec reported by the extractor (for example `mp4a.40.2` or `opus`).
  final String? codec;

  /// Exact InnerTube client profile that produced the signed media URL.
  final String? clientProfileKey;

  /// Last instant at which the signed URL and any bound token may be reused.
  final DateTime? expiresAt;

  bool get isUsable {
    final uri = Uri.tryParse(streamUrl);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'file');
  }

  AudioStreamResolution withSource(AudioStreamSource newSource) {
    return AudioStreamResolution(
      source: newSource,
      streamUrl: streamUrl,
      streamExtension: streamExtension,
      streamMimeType: streamMimeType,
      httpHeaders: httpHeaders,
      videoId: videoId,
      formatId: formatId,
      codec: codec,
      clientProfileKey: clientProfileKey,
      expiresAt: expiresAt,
    );
  }

  static AudioStreamResolution fromTrack(
    TrackInfo track, {
    required AudioStreamSource source,
  }) {
    return AudioStreamResolution(
      source: source,
      streamUrl: track.streamUrl ?? '',
      streamExtension: track.streamExtension,
      streamMimeType: track.streamMimeType,
      httpHeaders: track.httpHeaders == null
          ? null
          : Map<String, String>.unmodifiable(track.httpHeaders!),
      videoId: track.id.isEmpty ? null : track.id,
      formatId: track.streamFormatId,
      codec: track.streamCodec,
      clientProfileKey: track.streamClientProfileKey,
    );
  }

  static AudioStreamResolution fromFallbackTrack(TrackInfo track) {
    return fromTrack(track, source: AudioStreamSource.innerTubeFallback);
  }
}

/// Strategy for resolving a playable audio stream for a track.
abstract interface class AudioStreamResolver {
  Future<AudioStreamResolution> resolve(TrackInfo track);

  Future<void> dispose();
}

/// Optional capability for a resolver that can stop expensive staged work
/// after its caller has selected a different track.
abstract interface class ContinuationAwareAudioStreamResolver {
  Future<AudioStreamResolution> resolveWhileCurrent(
    TrackInfo track, {
    AudioResolverContinuationCallback? shouldContinue,
  });
}

/// Optional capability for resolver chains that can skip the primary and can
/// report the exact moment a fallback starts.
abstract interface class FallbackAwareAudioStreamResolver {
  Future<AudioStreamResolution> resolveWithMode(
    TrackInfo track, {
    AudioResolutionMode mode = AudioResolutionMode.primaryThenFallback,
    AudioResolverFailureCallback? onResolverFailure,
    AudioResolverContinuationCallback? shouldContinue,
  });
}
