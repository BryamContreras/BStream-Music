import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/local_track.dart';
import 'music_providers.dart';

/// One library traversal shared by recommendations, playlists and playback.
final localTrackIndexProvider = Provider<LocalTrackIndex>((ref) {
  final tracks = ref.watch(
    libraryTracksProvider.select((library) => library.value),
  );
  return tracks == null
      ? const LocalTrackIndex.empty()
      : LocalTrackIndex(tracks);
});

typedef _IndexedLocalTrack = ({int position, LocalTrack track});

class LocalTrackIndex {
  const LocalTrackIndex.empty()
    : _byId = const {},
      _lastByRepeatedId = const {},
      _bySourceId = const {},
      _bySourceUrl = const {},
      totalDuration = null;

  factory LocalTrackIndex(
    Iterable<LocalTrack> tracks, {
    bool indexSourceUrls = true,
  }) {
    final byId = <String, _IndexedLocalTrack>{};
    final lastByRepeatedId = <String, LocalTrack>{};
    final bySourceId = <String, _IndexedLocalTrack>{};
    final bySourceUrl = <String, _IndexedLocalTrack>{};
    Duration? totalDuration;
    var position = 0;
    for (final track in tracks) {
      final duration = track.duration;
      if (duration != null) {
        totalDuration = (totalDuration ?? Duration.zero) + duration;
      }
      final indexed = (position: position++, track: track);
      if (byId.putIfAbsent(track.id, () => indexed).position !=
          indexed.position) {
        lastByRepeatedId[track.id] = track;
      }
      final sourceId = track.sourceId?.trim();
      if (sourceId != null && sourceId.isNotEmpty) {
        bySourceId.putIfAbsent(sourceId, () => indexed);
      }
      final sourceUrl = indexSourceUrls ? track.sourceUrl?.trim() : null;
      if (sourceUrl != null && sourceUrl.isNotEmpty) {
        bySourceUrl.putIfAbsent(sourceUrl, () => indexed);
      }
    }
    return LocalTrackIndex._(
      byId,
      lastByRepeatedId,
      bySourceId,
      bySourceUrl,
      totalDuration,
    );
  }

  const LocalTrackIndex._(
    this._byId,
    this._lastByRepeatedId,
    this._bySourceId,
    this._bySourceUrl,
    this.totalDuration,
  );

  final Map<String, _IndexedLocalTrack> _byId;
  final Map<String, LocalTrack> _lastByRepeatedId;
  final Map<String, _IndexedLocalTrack> _bySourceId;
  final Map<String, _IndexedLocalTrack> _bySourceUrl;
  final Duration? totalDuration;

  /// Matches the legacy library's map-by-ID lookup, including duplicates.
  LocalTrack? lastByExactId(String id) =>
      _lastByRepeatedId[id] ?? _byId[id]?.track;

  LocalTrack? firstById(String? id) {
    final normalized = id?.trim();
    return normalized == null || normalized.isEmpty
        ? null
        : _byId[normalized]?.track;
  }

  LocalTrack? firstBySourceUrl(String? url) => _bySourceUrl[url?.trim()]?.track;

  LocalTrack? forPlaylist({
    required String? localId,
    required String? sourceId,
  }) {
    final id = localId?.trim();
    if (id != null && id.isNotEmpty) {
      return _lastByRepeatedId[id] ?? _byId[id]?.track;
    }
    return _bySourceId[sourceId]?.track;
  }

  /// Home previously stopped at the first match of either identity. Preserve
  /// library order rather than preferring a later exact local ID match.
  LocalTrack? firstMatching({String? localId, String? sourceId}) {
    final normalizedLocalId = localId?.trim();
    final normalizedSourceId = sourceId?.trim();
    final local = normalizedLocalId == null || normalizedLocalId.isEmpty
        ? null
        : _byId[normalizedLocalId];
    final source = normalizedSourceId == null || normalizedSourceId.isEmpty
        ? null
        : _bySourceId[normalizedSourceId];
    if (local == null) return source?.track;
    if (source == null) return local.track;
    return local.position <= source.position ? local.track : source.track;
  }
}
