import '../../../../core/utils/image_source.dart';
import '../../domain/entities/catalog_track.dart';
import '../../domain/entities/local_track.dart';

/// One large cover plus two rows of four secondary covers.
const int playlistArtworkSourceLimit = 9;

class PlaylistArtworkSource {
  const PlaylistArtworkSource({required this.source, this.fallbackSource});

  final String source;
  final String? fallbackSource;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PlaylistArtworkSource &&
            other.source == source &&
            other.fallbackSource == fallbackSource;
  }

  @override
  int get hashCode => Object.hash(source, fallbackSource);
}

/// Prefers the canonical catalog cover over a saved YouTube video thumbnail.
PlaylistArtworkSource? preferredLocalPlaylistArtworkSource(LocalTrack track) {
  return _preferredArtworkSource(
    primaryCandidates: <String?>[
      track.catalogThumbnailUrl,
      track.thumbnailPath,
      track.thumbnailUrl,
    ],
    fallbackCandidates: <String?>[track.thumbnailPath, track.thumbnailUrl],
  );
}

/// Prefers a sharp network rendition for individual downloaded-track
/// surfaces, with the saved file retained as the offline fallback.
///
/// Playlist collages intentionally prefer local files to avoid many network
/// requests. A full player or library row can instead benefit from the
/// catalog/video source that [SourceImage] upgrades to its high-resolution
/// rendition.
PlaylistArtworkSource? preferredLocalTrackArtworkSource(LocalTrack track) {
  return _preferredArtworkSource(
    primaryCandidates: <String?>[
      highResolutionGoogleArtworkSource(track.catalogThumbnailUrl),
      highResolutionGoogleArtworkSource(track.thumbnailUrl),
      track.thumbnailPath,
    ],
    fallbackCandidates: <String?>[
      track.thumbnailPath,
      track.thumbnailUrl,
      track.catalogThumbnailUrl,
    ],
  );
}

/// Chooses high-resolution artwork for one catalog row while retaining a
/// downloaded cover as its offline fallback.
PlaylistArtworkSource? preferredCatalogTrackArtworkSource(
  CatalogTrack track, {
  LocalTrack? localTrack,
}) {
  return _preferredArtworkSource(
    primaryCandidates: <String?>[
      highResolutionGoogleArtworkSource(localTrack?.catalogThumbnailUrl),
      highResolutionGoogleArtworkSource(track.thumbnailUrl),
      highResolutionGoogleArtworkSource(localTrack?.thumbnailUrl),
      localTrack?.thumbnailPath,
    ],
    fallbackCandidates: <String?>[
      localTrack?.thumbnailPath,
      localTrack?.thumbnailUrl,
      track.thumbnailUrl,
    ],
  );
}

/// Uses the canonical local catalog cover when known, then playlist metadata
/// and finally the best saved/video fallback.
PlaylistArtworkSource? preferredCatalogPlaylistArtworkSource(
  CatalogTrack track, {
  LocalTrack? localTrack,
}) {
  return _preferredArtworkSource(
    primaryCandidates: <String?>[
      localTrack?.catalogThumbnailUrl,
      track.thumbnailUrl,
      localTrack?.thumbnailPath,
      localTrack?.thumbnailUrl,
    ],
    fallbackCandidates: <String?>[
      localTrack?.thumbnailPath,
      localTrack?.thumbnailUrl,
      track.thumbnailUrl,
    ],
  );
}

/// Returns a deduplicated, daily-stable rotation for a playlist collage.
///
/// The order changes on a later local calendar day, but remains stable during
/// ordinary rebuilds so artwork does not flicker while scrolling or playing.
List<PlaylistArtworkSource> rotatingPlaylistArtworkSources({
  required String playlistId,
  required Iterable<PlaylistArtworkSource?> candidates,
  DateTime? now,
  int maximum = playlistArtworkSourceLimit,
}) {
  if (maximum < 1) {
    throw RangeError.range(maximum, 1, null, 'maximum');
  }

  final sources = <PlaylistArtworkSource>[];
  final seen = <String>{};
  for (final candidate in candidates) {
    final normalized = _normalizedArtworkSource(candidate?.source);
    if (normalized != null && seen.add(normalized)) {
      final fallback = _normalizedArtworkSource(candidate?.fallbackSource);
      sources.add(
        PlaylistArtworkSource(
          source: normalized,
          fallbackSource: fallback == normalized ? null : fallback,
        ),
      );
    }
  }
  if (sources.length <= 1) {
    return List<PlaylistArtworkSource>.unmodifiable(sources);
  }

  final current = now ?? DateTime.now();
  final localDay =
      DateTime.utc(
        current.year,
        current.month,
        current.day,
      ).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
  final primaryIndex =
      (_stableArtworkHash(playlistId) + localDay) % sources.length;
  final primary = sources.removeAt(primaryIndex);
  _shuffleArtworkSources(
    sources,
    seed: _stableArtworkHash('$playlistId:$localDay'),
  );
  return List<PlaylistArtworkSource>.unmodifiable(
    <PlaylistArtworkSource>[primary, ...sources].take(maximum),
  );
}

PlaylistArtworkSource? _preferredArtworkSource({
  required Iterable<String?> primaryCandidates,
  required Iterable<String?> fallbackCandidates,
}) {
  String? primary;
  for (final candidate in primaryCandidates) {
    final normalized = _normalizedArtworkSource(candidate);
    if (normalized != null) {
      primary = normalized;
      break;
    }
  }
  if (primary == null) {
    return null;
  }

  String? fallback;
  for (final candidate in fallbackCandidates) {
    final normalized = _normalizedArtworkSource(candidate);
    if (normalized != null && normalized != primary) {
      fallback = normalized;
      break;
    }
  }
  return PlaylistArtworkSource(source: primary, fallbackSource: fallback);
}

String? _normalizedArtworkSource(String? source) {
  final normalized = source?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  if (isNetworkImageSource(normalized) ||
      isDeviceAudioArtworkSource(normalized)) {
    return normalized;
  }
  return imageFileFromSource(normalized)?.path;
}

int _stableArtworkHash(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

void _shuffleArtworkSources(
  List<PlaylistArtworkSource> sources, {
  required int seed,
}) {
  var state = seed & 0xffffffff;
  for (var index = sources.length - 1; index > 0; index--) {
    state = ((state * 1664525) + 1013904223) & 0xffffffff;
    final swapIndex = state % (index + 1);
    final value = sources[index];
    sources[index] = sources[swapIndex];
    sources[swapIndex] = value;
  }
}
