import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../../features/music/domain/entities/catalog_track.dart';
import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/playlist.dart';
import '../../features/music/domain/entities/playlist_entry.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../../features/music/domain/repositories/catalog_playlist_repository.dart';
import '../../features/music/domain/repositories/library_repository.dart';
import 'library_csv_service.dart';

typedef LibraryCsvTrackSearch = Future<List<TrackInfo>> Function(String query);
typedef LibraryCsvGate = Future<T> Function<T>(Future<T> Function() operation);

class LibraryCsvImportProgress {
  const LibraryCsvImportProgress({
    required this.total,
    required this.processed,
    required this.imported,
    required this.reused,
    required this.failed,
    required this.currentTitle,
    this.cancelRequested = false,
  });

  final int total;
  final int processed;
  final int imported;
  final int reused;
  final int failed;
  final String currentTitle;
  final bool cancelRequested;

  double get fraction => total == 0 ? 0 : processed / total;
}

class LibraryCsvImportFailure {
  const LibraryCsvImportFailure({
    required this.rowNumber,
    required this.title,
    required this.message,
    this.ambiguous = false,
  });

  final int rowNumber;
  final String title;
  final String message;
  final bool ambiguous;
}

class LibraryCsvImportResult {
  const LibraryCsvImportResult({
    required this.total,
    required this.processed,
    required this.imported,
    required this.reused,
    required this.failed,
    required this.playlistsUpdated,
    required this.cancelled,
    required this.failures,
  });

  final int total;
  final int processed;
  final int imported;
  final int reused;
  final int failed;
  final int playlistsUpdated;
  final bool cancelled;
  final List<LibraryCsvImportFailure> failures;

  int get successful => imported + reused;
}

class LibraryCsvImportService {
  LibraryCsvImportService(
    this._repository,
    this._playlists,
    this._search,
    this._gate, {
    int maxConcurrentTracks = 3,
  }) : _maxConcurrentTracks = maxConcurrentTracks {
    if (maxConcurrentTracks <= 0) {
      throw ArgumentError.value(
        maxConcurrentTracks,
        'maxConcurrentTracks',
        'Debe ser mayor que cero.',
      );
    }
  }

  static const maxFailureDetails = 100;

  final LibraryRepository _repository;
  final CatalogPlaylistRepository _playlists;
  final LibraryCsvTrackSearch _search;
  final LibraryCsvGate _gate;
  final int _maxConcurrentTracks;
  final Uuid _uuid = const Uuid();

  Future<LibraryCsvImportResult> import(
    LibraryCsvDocument document, {
    required bool Function() isCancellationRequested,
    void Function(LibraryCsvImportProgress progress)? onProgress,
  }) async {
    final total = document.tracks.length;
    var processed = 0;
    var imported = 0;
    var reused = 0;
    var failed = 0;
    final failures = <LibraryCsvImportFailure>[];
    final entryFailures = List<LibraryCsvImportFailure?>.filled(total, null);
    final outcomes = List<TrackInfo?>.filled(total, null);
    final playlistTracks =
        <
          String,
          ({
            String? id,
            String name,
            List<({int position, int sourceOrder})> items,
          })
        >{};

    void publish(String title) {
      onProgress?.call(
        LibraryCsvImportProgress(
          total: total,
          processed: processed,
          imported: imported,
          reused: reused,
          failed: failed,
          currentTitle: title,
          cancelRequested: isCancellationRequested(),
        ),
      );
    }

    publish('');
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (isCancellationRequested() || nextIndex >= total) return;
        final index = nextIndex++;
        final entry = document.tracks[index];
        publish(entry.displayTitle);
        try {
          final resolved = await _resolve(entry);
          if (_videoId(resolved.id, resolved.url) == null) {
            throw const FormatException(
              'La canción no tiene un ID de YouTube válido.',
            );
          }
          outcomes[index] = resolved;
        } on LibraryCsvAmbiguousMatchException catch (error) {
          failed++;
          entryFailures[index] = LibraryCsvImportFailure(
            rowNumber: entry.rowNumber,
            title: entry.displayTitle,
            message: error.message,
            ambiguous: true,
          );
        } catch (error) {
          failed++;
          entryFailures[index] = LibraryCsvImportFailure(
            rowNumber: entry.rowNumber,
            title: entry.displayTitle,
            message: error.toString(),
          );
        } finally {
          processed++;
          publish(entry.displayTitle);
        }
      }
    }

    final workerCount = math.min(_maxConcurrentTracks, total);
    await Future.wait(List.generate(workerCount, (_) => worker()));
    failures.addAll(
      entryFailures.whereType<LibraryCsvImportFailure>().take(
        maxFailureDetails,
      ),
    );

    // Search may finish out of order. Persist catalog memberships in source
    // order without involving the audio downloader or the legacy track_ids API.
    for (var index = 0; index < outcomes.length; index++) {
      final outcome = outcomes[index];
      if (outcome == null) continue;
      final entry = document.tracks[index];
      final memberships = entry.memberships
          .where((item) => item.name.trim().isNotEmpty)
          .toList();
      // Rows exported without playlist membership still need a visible home
      // now that importing them no longer creates a downloaded library file.
      if (memberships.isEmpty) {
        memberships.add(
          LibraryCsvMembership(
            name: document.defaultPlaylistName,
            position: index + 1,
          ),
        );
      }
      for (final membership in memberships) {
        final displayName = membership.name.trim();
        if (displayName.isEmpty) continue;
        final normalizedName = displayName.toLowerCase();
        final playlistId = _playlistId(membership);
        final bucketKey = playlistId?.isNotEmpty == true
            ? 'id:$playlistId'
            : 'name:$normalizedName';
        final bucket = playlistTracks.putIfAbsent(
          bucketKey,
          () => (
            id: playlistId?.isNotEmpty == true ? playlistId : null,
            name: displayName,
            items: <({int position, int sourceOrder})>[],
          ),
        );
        bucket.items.add((position: membership.position, sourceOrder: index));
      }
    }

    var playlistsUpdated = 0;
    final persisted = <int>{};
    final reusedVideoIds = <String>{};
    if (playlistTracks.isNotEmpty) {
      await _gate(() async {
        final localByVideoId = <String, LocalTrack>{};
        for (final track in await _repository.getLocalTracks()) {
          final videoId = _videoId(track.sourceId, track.sourceUrl);
          if (videoId != null) localByVideoId.putIfAbsent(videoId, () => track);
        }
        reusedVideoIds.addAll(localByVideoId.keys);
        for (final playlistEntry in playlistTracks.values) {
          final ordered = playlistEntry.items
            ..sort((left, right) {
              final byPosition = left.position.compareTo(right.position);
              return byPosition != 0
                  ? byPosition
                  : left.sourceOrder.compareTo(right.sourceOrder);
            });
          try {
            reusedVideoIds.addAll(
              await _mergePlaylist(
                id: playlistEntry.id,
                name: playlistEntry.name,
                tracks: [
                  for (final item in ordered) outcomes[item.sourceOrder]!,
                ],
                localByVideoId: localByVideoId,
              ),
            );
            persisted.addAll(ordered.map((item) => item.sourceOrder));
            playlistsUpdated++;
          } catch (error) {
            _recordFailure(
              failures,
              LibraryCsvImportFailure(
                rowNumber: 0,
                title: playlistEntry.name,
                message: 'No se pudo actualizar la playlist: $error',
              ),
            );
          }
        }
      });
    }
    reused = persisted.where((index) {
      final track = outcomes[index]!;
      return reusedVideoIds.contains(_videoId(track.id, track.url));
    }).length;
    imported = persisted.length - reused;
    failed = processed - persisted.length;
    publish('');

    return LibraryCsvImportResult(
      total: total,
      processed: processed,
      imported: imported,
      reused: reused,
      failed: failed,
      playlistsUpdated: playlistsUpdated,
      cancelled: isCancellationRequested() && processed < total,
      failures: List.unmodifiable(failures),
    );
  }

  Future<Set<String>> _mergePlaylist({
    required String? id,
    required String name,
    required List<TrackInfo> tracks,
    required Map<String, LocalTrack> localByVideoId,
  }) async {
    var targetId = id;
    if (targetId == null) {
      for (final candidate in await _playlists.getCatalogPlaylists()) {
        if (!candidate.isFavorites &&
            candidate.name.trim().toLowerCase() == name.toLowerCase()) {
          targetId = candidate.id;
          break;
        }
      }
    }
    targetId ??= 'csv-${_uuid.v4()}';
    var existing = await _playlists.getCatalogPlaylist(targetId);
    if (existing == null) {
      await _playlists.createCatalogPlaylist(
        id: targetId,
        name: name,
        now: DateTime.now(),
      );
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      existing = await _playlists.getCatalogPlaylist(targetId);
      if (existing == null) {
        throw StateError('La playlist ya no está disponible.');
      }
      final now = DateTime.now();
      final entries = existing.entries
          .where((entry) => !entry.isDeleted)
          .toList();
      final originalEntryCount = entries.length;
      final byVideo = <String, int>{};
      final byLocal = <String, int>{};
      for (var index = 0; index < entries.length; index++) {
        final entry = entries[index];
        if (entry.videoId != null) {
          byVideo.putIfAbsent(entry.videoId!, () => index);
        }
        if (entry.localTrackId != null) {
          byLocal.putIfAbsent(entry.localTrackId!, () => index);
        }
      }
      final reused = <String>{};
      var changed = false;
      for (final track in tracks) {
        final videoId = _videoId(track.id, track.url)!;
        final local = localByVideoId[videoId];
        final index =
            byVideo[videoId] ?? (local == null ? null : byLocal[local.id]);
        final catalog = CatalogTrack.youtube(
          videoId: videoId,
          title: track.title,
          artists: track.artists.isEmpty
              ? [if (track.artist.trim().isNotEmpty) track.artist]
              : track.artists,
          artistBrowseIds: track.artistBrowseIds,
          album: track.album,
          duration: track.duration,
          thumbnailUrl:
              track.catalogThumbnailUrl ??
              track.thumbnailUrl ??
              'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
          sourceUrl: 'https://www.youtube.com/watch?v=$videoId',
        );
        if (index != null) {
          if (index < originalEntryCount) reused.add(videoId);
          final entry = entries[index];
          if (entry.track.youtubeVideoId == null ||
              (entry.localTrackId == null && local != null)) {
            entries[index] = entry.copyWith(
              track: entry.track.youtubeVideoId == null ? catalog : entry.track,
              localTrackId: entry.localTrackId ?? local?.id,
              updatedAt: now,
            );
            changed = true;
          }
          byVideo[videoId] = index;
          continue;
        }
        byVideo[videoId] = entries.length;
        entries.add(
          PlaylistEntry(
            id: _uuid.v4(),
            playlistId: targetId,
            track: catalog,
            localTrackId: local?.id,
            position: entries.length,
            createdAt: now,
            updatedAt: now,
          ),
        );
        changed = true;
      }
      if (!changed) return reused;
      try {
        await _playlists.replaceCatalogEntries(
          playlistId: targetId,
          entries: entries,
          now: now,
          expectedRevision: existing.playlist.localRevision,
        );
        return reused;
      } on PlaylistRevisionConflict {
        if (attempt == 2) rethrow;
      }
    }
    throw StateError('La playlist cambió durante la importación.');
  }

  String? _playlistId(LibraryCsvMembership membership) {
    final id = membership.id?.trim();
    if (id == Playlist.favoritesId || id == 'LM' || id == 'VLLM') {
      return Playlist.favoritesId;
    }
    if (id != null && id.isNotEmpty) return id;
    const favoritesNames = {
      'favorites',
      'favourites',
      'favoritos',
      'favoritas',
      'liked songs',
      'liked music',
      'tus me gusta',
      'canciones que te gustan',
    };
    return favoritesNames.contains(membership.name.trim().toLowerCase())
        ? Playlist.favoritesId
        : null;
  }

  String? _videoId(String? id, String? url) {
    final direct = id?.trim();
    if (direct != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(direct)) {
      return direct;
    }
    final uri = Uri.tryParse(url ?? '');
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host != 'youtu.be' &&
        host != 'youtube.com' &&
        !host.endsWith('.youtube.com')) {
      return null;
    }
    final candidate = host == 'youtu.be' && uri.pathSegments.isNotEmpty
        ? uri.pathSegments.first
        : uri.queryParameters['v'];
    return candidate != null &&
            RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(candidate)
        ? candidate
        : null;
  }

  Future<TrackInfo> _resolve(LibraryCsvTrack entry) async {
    final videoId = entry.youtubeVideoId?.trim();
    if (videoId != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
      return TrackInfo(
        id: videoId,
        title: entry.title,
        artist: entry.artist,
        artists: entry.artists,
        album: entry.album,
        duration: entry.duration,
        thumbnailUrl: entry.thumbnailUrl,
        url: 'https://www.youtube.com/watch?v=$videoId',
      );
    }

    final descriptiveFields = [entry.title, entry.artist, entry.album]
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    final descriptiveQuery = descriptiveFields.join(' ');
    final query = descriptiveQuery.isNotEmpty
        ? descriptiveQuery
        : (entry.isrc?.trim() ?? '');
    if (query.isEmpty) {
      throw const FormatException('La fila no tiene información para buscar.');
    }
    final candidates = await _search(query);
    if (candidates.isEmpty) {
      throw const FormatException('No se encontraron resultados seguros.');
    }
    final uniqueCandidates = <String, TrackInfo>{};
    for (final candidate in candidates) {
      final key = candidate.id.trim().isNotEmpty
          ? candidate.id.trim()
          : candidate.url.trim();
      uniqueCandidates.putIfAbsent(key, () => candidate);
    }
    final ranked = [
      for (final candidate in uniqueCandidates.values)
        (candidate: candidate, score: _candidateScore(entry, candidate)),
    ]..sort((left, right) => right.score.compareTo(left.score));
    final best = ranked.first;
    final threshold = entry.artist.trim().isEmpty ? 0.70 : 0.62;
    final secondScore = ranked.length > 1 ? ranked[1].score : 0.0;
    if (best.score < threshold ||
        (best.score < 0.90 && best.score - secondScore < 0.06)) {
      throw LibraryCsvAmbiguousMatchException(
        'No hubo una coincidencia suficientemente segura para importar.',
      );
    }
    return best.candidate;
  }

  double _candidateScore(LibraryCsvTrack entry, TrackInfo candidate) {
    final titleScore = _tokenSimilarity(entry.title, candidate.title);
    final artistScore = entry.artist.trim().isEmpty
        ? 1.0
        : math.max(
            _tokenSimilarity(entry.artist, candidate.artist),
            candidate.artists.fold<double>(
              0,
              (score, artist) =>
                  math.max(score, _tokenSimilarity(entry.artist, artist)),
            ),
          );
    final albumScore = entry.album == null || entry.album!.trim().isEmpty
        ? 0.5
        : _tokenSimilarity(entry.album!, candidate.album ?? '');
    final durationScore = _durationScore(entry.duration, candidate.duration);
    var score =
        titleScore * 0.68 +
        artistScore * 0.20 +
        albumScore * 0.04 +
        durationScore * 0.08;
    final sourceQualifiers = _qualifiers(entry.title);
    final candidateQualifiers = _qualifiers(candidate.title);
    if (candidateQualifiers.difference(sourceQualifiers).isNotEmpty) {
      score -= 0.18;
    }
    return score.clamp(0.0, 1.0);
  }

  double _durationScore(Duration? expected, Duration? actual) {
    if (expected == null || actual == null) return 0.5;
    final difference = (expected.inSeconds - actual.inSeconds).abs();
    if (difference <= 3) return 1;
    if (difference <= 10) return 0.8;
    if (difference <= 30) return 0.35;
    return 0;
  }

  double _tokenSimilarity(String left, String right) {
    final leftTokens = _tokens(left);
    final rightTokens = _tokens(right);
    if (leftTokens.isEmpty || rightTokens.isEmpty) return 0;
    if (leftTokens.join(' ') == rightTokens.join(' ')) return 1;
    final leftSet = leftTokens.toSet();
    final rightSet = rightTokens.toSet();
    final overlap = leftSet.intersection(rightSet).length;
    final coverage = overlap / leftSet.length;
    final precision = overlap / rightSet.length;
    return coverage * 0.7 + precision * 0.3;
  }

  List<String> _tokens(String input) {
    var normalized = input.toLowerCase();
    const accents = {
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
    };
    for (final entry in accents.entries) {
      normalized = normalized.replaceAll(entry.key, entry.value);
    }
    return normalized
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty && !_ignoredTokens.contains(token))
        .toList(growable: false);
  }

  Set<String> _qualifiers(String value) =>
      _tokens(value).where(_versionQualifiers.contains).toSet();

  void _recordFailure(
    List<LibraryCsvImportFailure> failures,
    LibraryCsvImportFailure failure,
  ) {
    if (failures.length < maxFailureDetails) failures.add(failure);
  }
}

class LibraryCsvAmbiguousMatchException implements Exception {
  const LibraryCsvAmbiguousMatchException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _ignoredTokens = {
  'the',
  'a',
  'an',
  'official',
  'audio',
  'video',
  'lyrics',
  'lyric',
};
const _versionQualifiers = {
  'live',
  'remix',
  'karaoke',
  'cover',
  'instrumental',
  'slowed',
  'reverb',
  'sped',
  'acoustic',
};
