import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Loads one YouTube manifest for one explicitly selected InnerTube client.
///
/// Keeping this boundary injectable makes the retry policy deterministic in
/// tests and, more importantly, prevents `getManifest` from querying every
/// configured client after the first one already returned usable audio.
typedef YoutubeManifestLoader =
    Future<StreamManifest> Function(
      VideoId videoId,
      YoutubeApiClient client,
      bool requireWatchPage,
    );

/// Confirms that the exact audio stream selected from a manifest is readable.
///
/// `youtube_explode_dart` validates only the first stream in a manifest, which
/// can be a working muxed stream while the selected audio-only URL is rejected.
/// Keeping this callback optional lets managed downloads retain the package's
/// own ranged/fragmented transfer implementation.
typedef YoutubeSelectedAudioValidator =
    Future<void> Function(AudioOnlyStreamInfo stream);

/// A single, ordered attempt used by [resolvePreferredYoutubeAudioStream].
class YoutubeManifestAttempt {
  const YoutubeManifestAttempt({
    required this.name,
    required this.client,
    this.requireWatchPage = false,
  });

  final String name;
  final YoutubeApiClient client;
  final bool requireWatchPage;
}

/// Details from a failed staged manifest resolution.
class YoutubeAudioManifestException implements Exception {
  const YoutubeAudioManifestException(this.failures);

  final List<YoutubeManifestFailure> failures;

  Object? get cause => failures.isEmpty ? null : failures.last.error;

  @override
  String toString() {
    if (failures.isEmpty) {
      return 'No YouTube manifest returned usable audio.';
    }
    final clients = failures.map((failure) => failure.clientName).join(', ');
    return 'No YouTube manifest returned usable audio (tried $clients). '
        'Last error: ${failures.last.error}';
  }
}

class YoutubeManifestFailure {
  const YoutubeManifestFailure({required this.clientName, required this.error});

  final String clientName;
  final Object error;
}

/// Current tokenless client copied from yt-dlp's maintained InnerTube table.
///
/// Unlike the mobile clients, VisionOS currently has neither a JS-player nor
/// a GVS PO-token requirement. Keeping it here avoids waiting for a package
/// release whenever YouTube rotates client versions.
///
/// Creates a fresh mutable client payload for each manifest attempt.
///
/// `youtube_explode_dart` currently adds session-scoped fields such as
/// `visitorData` to the nested client map (for iOS in particular). A `const`
/// payload throws at runtime when the package performs that mutation, while a
/// shared mutable payload would leak the visitor data into later sessions.
YoutubeApiClient get youtubeVisionOsClient => YoutubeApiClient({
  'context': {
    'client': {
      'clientName': 'VISIONOS',
      'clientVersion': '1.02',
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice17,1',
      'userAgent':
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 '
          'Safari/605.1.15',
      'osName': 'visionOS',
      'osVersion': '26.5.23O471',
      'hl': 'en',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
  },
}, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

/// Current iOS edge fallback. HTTPS streams commonly require a GVS PO token,
/// so it remains behind both VisionOS attempts instead of being a normal path.
YoutubeApiClient get youtubeCurrentIosClient => YoutubeApiClient({
  'context': {
    'client': {
      'clientName': 'IOS',
      'clientVersion': '21.26.4',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'userAgent':
          'com.google.ios.youtube/21.26.4 '
          '(iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
      'osName': 'iPhone',
      'osVersion': '18.3.2.22D82',
      'hl': 'en',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
  },
}, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

/// Current Android VR last-resort client. PO-token enforcement is selective,
/// so this client is also kept out of the normal resolution path.
YoutubeApiClient get youtubeCurrentAndroidVrClient => YoutubeApiClient({
  'context': {
    'client': {
      'clientName': 'ANDROID_VR',
      'clientVersion': '1.65.10',
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'androidSdkVersion': 32,
      'userAgent':
          'com.google.android.apps.youtube.vr.oculus/1.65.10 '
          '(Linux; U; Android 12L; eureka-user '
          'Build/SQ3A.220605.009.A1) gzip',
      'osName': 'Android',
      'osVersion': '12L',
      'hl': 'en',
      'timeZone': 'UTC',
      'utcOffsetMinutes': 0,
    },
  },
}, 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

/// Ordered clients used for normal playback and downloads.
///
/// Attempts are deliberately sequential. VisionOS with watch-page context is
/// the reliable path; the context-free request remains as a cheaper retry for
/// environments where the watch page itself is unavailable. Mobile clients
/// are consulted only when both VisionOS variants fail or have no compatible
/// audio.
List<YoutubeManifestAttempt> get defaultYoutubeManifestAttempts => [
  YoutubeManifestAttempt(
    name: 'visionOS+watch',
    client: youtubeVisionOsClient,
    requireWatchPage: true,
  ),
  YoutubeManifestAttempt(name: 'visionOS', client: youtubeVisionOsClient),
  YoutubeManifestAttempt(name: 'iOS', client: youtubeCurrentIosClient),
  YoutubeManifestAttempt(
    name: 'androidVr',
    client: youtubeCurrentAndroidVrClient,
  ),
];

/// Resolves the first usable stream without eagerly querying every client.
///
/// A client-specific `VideoUnplayableException` is not considered final: the
/// next client is still tried. This matters for regional, made-for-kids, and
/// rollout differences where YouTube reports different playability per client.
Future<AudioOnlyStreamInfo> resolvePreferredYoutubeAudioStream({
  required VideoId videoId,
  required YoutubeManifestLoader loadManifest,
  YoutubeSelectedAudioValidator? validateSelectedStream,
  bool requireDirectUrl = false,
  Iterable<YoutubeManifestAttempt>? attempts,
}) async {
  final failures = <YoutubeManifestFailure>[];
  final orderedAttempts = attempts ?? defaultYoutubeManifestAttempts;

  for (final attempt in orderedAttempts) {
    try {
      final manifest = await loadManifest(
        videoId,
        attempt.client,
        attempt.requireWatchPage,
      );
      final selected = selectPreferredYoutubeAudioStream(
        manifest.audioOnly,
        requireDirectUrl: requireDirectUrl,
      );
      if (selected != null) {
        await validateSelectedStream?.call(selected);
        return selected;
      }
      failures.add(
        YoutubeManifestFailure(
          clientName: attempt.name,
          error: const FormatException(
            'Manifest had no compatible audio-only stream.',
          ),
        ),
      );
    } catch (error) {
      failures.add(
        YoutubeManifestFailure(clientName: attempt.name, error: error),
      );
    }
  }

  throw YoutubeAudioManifestException(List.unmodifiable(failures));
}

/// Selects a broadly compatible audio-only YouTube stream.
///
/// YouTube normally exposes AAC inside an MP4 container and Opus inside WebM.
/// MP4/AAC is preferred for player compatibility, while every other
/// audio-only container remains eligible as a last resort.
AudioOnlyStreamInfo? selectPreferredYoutubeAudioStream(
  Iterable<AudioOnlyStreamInfo> streams, {
  bool requireDirectUrl = false,
}) {
  final available = streams
      .where((stream) => !requireDirectUrl || stream.fragments.isEmpty)
      .toList(growable: false);
  if (available.isEmpty) {
    return null;
  }

  // Avoid accidentally selecting an alternate dub or audio-description track.
  // Streams without language metadata are treated as default candidates.
  final defaultAudio = available
      .where(
        (stream) =>
            stream.audioTrack == null || stream.audioTrack!.audioIsDefault,
      )
      .toList(growable: false);
  final candidates = defaultAudio.isEmpty ? available : defaultAudio;

  final mp4 = candidates
      .where((stream) => stream.container == StreamContainer.mp4)
      .toList(growable: false);
  final mp4Aac = mp4
      .where((stream) => isYoutubeAacCodec(stream.audioCodec))
      .toList(growable: false);

  if (mp4Aac.isNotEmpty) {
    return _highestBitrate(mp4Aac);
  }
  if (mp4.isNotEmpty) {
    return _highestBitrate(mp4);
  }
  return _highestBitrate(candidates);
}

bool isYoutubeAacCodec(String codec) {
  final normalized = codec.trim().toLowerCase();
  return normalized.startsWith('mp4a') || normalized.contains('aac');
}

String? youtubeAudioContainerExtension(StreamContainer container) {
  return switch (container.name) {
    'mp4' => 'm4a',
    'webm' => 'webm',
    '3gpp' => '3gp',
    'm3u8' => 'm3u8',
    _ => null,
  };
}

String? youtubeAudioContainerMimeType(StreamContainer container) {
  return switch (container.name) {
    'mp4' => 'audio/mp4',
    'webm' => 'audio/webm',
    '3gpp' => 'audio/3gpp',
    'm3u8' => 'application/x-mpegURL',
    _ => null,
  };
}

AudioOnlyStreamInfo _highestBitrate(Iterable<AudioOnlyStreamInfo> streams) {
  final sorted = streams.toList()
    ..sort((left, right) => right.bitrate.compareTo(left.bitrate));
  return sorted.first;
}
