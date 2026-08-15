import '../../features/music/domain/entities/track_info.dart';
import 'audio_stream_resolver.dart';
import 'downloader_service.dart';

/// Resolves a playable audio stream using the existing [DownloaderService].
///
/// This is the fallback path. It is used when `youtube_explode_dart` is
/// unavailable, when the URL is not a YouTube URL, or when the primary
/// resolver raised a recoverable error.
class YtDlpAudioResolver implements AudioStreamResolver {
  YtDlpAudioResolver(this._downloader);

  final DownloaderService _downloader;

  @override
  Future<AudioStreamResolution> resolve(TrackInfo track) async {
    final url = track.url.trim().isNotEmpty ? track.url : track.id;
    if (url.isEmpty) {
      throw const AudioStreamResolverException(
        'Cannot resolve a stream without a URL.',
      );
    }
    if (_downloader case final ManagedPlaybackDownloader managed) {
      final resource = await managed.prepareManagedPlayback(url);
      final fileUri = resource.uri;
      if (!AudioStreamResolution(
        source: AudioStreamSource.ytDlp,
        streamUrl: fileUri,
      ).isUsable) {
        throw const AudioStreamResolverException(
          'yt-dlp did not prepare a playable local resource.',
        );
      }
      return AudioStreamResolution(
        source: AudioStreamSource.ytDlp,
        streamUrl: fileUri,
        streamExtension: resource.extension,
        streamMimeType: resource.mimeType,
        formatId: resource.formatId,
        codec: resource.codec,
      );
    }

    final resolved = await _downloader.getPlaybackInfo(url);
    final streamUrl = resolved.streamUrl?.trim() ?? '';
    if (streamUrl.isEmpty ||
        !AudioStreamResolution(
          source: AudioStreamSource.ytDlp,
          streamUrl: streamUrl,
        ).isUsable) {
      throw const AudioStreamResolverException(
        'yt-dlp did not return a playable stream URL.',
      );
    }
    return AudioStreamResolution.fromFallbackTrack(resolved);
  }

  @override
  Future<void> dispose() async {}
}
