import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../../features/music/domain/entities/local_track.dart';
import '../../features/music/domain/entities/playlist.dart';
import '../../features/music/domain/entities/track_info.dart';
import '../../features/music/domain/repositories/library_repository.dart';
import 'library_csv_service.dart';

typedef LibraryCsvTrackSearch = Future<List<TrackInfo>> Function(String query);
typedef LibraryCsvTrackDownload =
    Future<LibraryCsvDownloadedTrack> Function(
      TrackInfo track, {
      required String taskId,
      void Function(TrackInfo resolved)? onResolved,
    });
typedef LibraryCsvGate = Future<T> Function<T>(Future<T> Function() operation);

class LibraryCsvDownloadedTrack {
  const LibraryCsvDownloadedTrack({
    required this.track,
    required this.reusedExisting,
  });

  final LocalTrack track;
  final bool reusedExisting;
}

class LibraryCsvImportProgress {
  const LibraryCsvImportProgress({
    required this.total,
    required this.processed,
    required this.downloaded,
    required this.reused,
    required this.failed,
    required this.currentTitle,
    this.cancelRequested = false,
  });

  final int total;
  final int processed;
  final int downloaded;
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
    required this.downloaded,
    required this.reused,
    required this.failed,
    required this.playlistsUpdated,
    required this.cancelled,
    required this.failures,
  });

  final int total;
  final int processed;
  final int downloaded;
  final int reused;
  final int failed;
  final int playlistsUpdated;
  final bool cancelled;
  final List<LibraryCsvImportFailure> failures;

  int get successful => downloaded + reused;
}

class LibraryCsvImportService {
  LibraryCsvImportService(
    this._repository,
    this._search,
    this._download,
    this._gate,
  );

  static const maxFailureDetails = 100;

  final LibraryRepository _repository;
  final LibraryCsvTrackSearch _search;
  final LibraryCsvTrackDownload _download;
  final LibraryCsvGate _gate;
  final Uuid _uuid = const Uuid();

  Future<LibraryCsvImportResult> import(
    LibraryCsvDocument document, {
    required bool Function() isCancellationRequested,
    void Function(LibraryCsvImportProgress progress)? onProgress,
  }) async {
    final total = document.tracks.length;
    var processed = 0;
    var downloaded = 0;
    var reused = 0;
    var failed = 0;
    final failures = <LibraryCsvImportFailure>[];
    final playlistTracks =
        <
          String,
          ({
            String? id,
            String name,
            List<({int position, String trackId})> items,
          })
        >{};

    void publish(String title) {
      onProgress?.call(
        LibraryCsvImportProgress(
          total: total,
          processed: processed,
          downloaded: downloaded,
          reused: reused,
          failed: failed,
          currentTitle: title,
          cancelRequested: isCancellationRequested(),
        ),
      );
    }

    publish('');
    for (var index = 0; index < document.tracks.length; index++) {
      if (isCancellationRequested()) break;
      final entry = document.tracks[index];
      publish(entry.displayTitle);
      try {
        final resolved = await _resolve(entry);
        final outcome = await _download(
          resolved,
          taskId: 'csv-${entry.rowNumber}-${index + 1}',
        );
        if (outcome.reusedExisting) {
          reused++;
        } else {
          downloaded++;
        }
        for (final membership in entry.memberships) {
          final displayName = membership.name.trim();
          if (displayName.isEmpty) continue;
          final normalizedName = displayName.toLowerCase();
          final playlistId = membership.id?.trim();
          final bucketKey = playlistId?.isNotEmpty == true
              ? 'id:$playlistId'
              : 'name:$normalizedName';
          final bucket = playlistTracks.putIfAbsent(
            bucketKey,
            () => (
              id: playlistId?.isNotEmpty == true ? playlistId : null,
              name: displayName,
              items: <({int position, String trackId})>[],
            ),
          );
          bucket.items.add((
            position: membership.position,
            trackId: outcome.track.id,
          ));
        }
      } on LibraryCsvAmbiguousMatchException catch (error) {
        failed++;
        _recordFailure(
          failures,
          LibraryCsvImportFailure(
            rowNumber: entry.rowNumber,
            title: entry.displayTitle,
            message: error.message,
            ambiguous: true,
          ),
        );
      } catch (error) {
        failed++;
        _recordFailure(
          failures,
          LibraryCsvImportFailure(
            rowNumber: entry.rowNumber,
            title: entry.displayTitle,
            message: error.toString(),
          ),
        );
      } finally {
        processed++;
        publish(entry.displayTitle);
      }
    }

    var playlistsUpdated = 0;
    for (final playlistEntry in playlistTracks.values) {
      final orderedIds = playlistEntry.items
        ..sort((left, right) => left.position.compareTo(right.position));
      final uniqueIds = <String>[];
      final seen = <String>{};
      for (final item in orderedIds) {
        if (seen.add(item.trackId)) uniqueIds.add(item.trackId);
      }
      if (uniqueIds.isEmpty) continue;
      try {
        await _gate(() async {
          final playlists = await _repository.getPlaylists();
          final normalizedName = playlistEntry.name.toLowerCase();
          Playlist? existing;
          for (final candidate in playlists) {
            final matchesId =
                playlistEntry.id != null && candidate.id == playlistEntry.id;
            final matchesName =
                playlistEntry.id == null &&
                candidate.name.trim().toLowerCase() == normalizedName;
            if (matchesId || matchesName) {
              existing = candidate;
              break;
            }
          }
          final now = DateTime.now();
          if (existing == null) {
            await _repository.savePlaylist(
              Playlist(
                id: playlistEntry.id ?? 'csv-${_uuid.v4()}',
                name: playlistEntry.name,
                trackIds: uniqueIds,
                createdAt: now,
                updatedAt: now,
              ),
            );
          } else {
            final merged = <String>[...existing.trackIds];
            final known = merged.toSet();
            for (final id in uniqueIds) {
              if (known.add(id)) merged.add(id);
            }
            await _repository.savePlaylist(
              existing.copyWith(trackIds: merged, updatedAt: now),
            );
          }
        });
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

    return LibraryCsvImportResult(
      total: total,
      processed: processed,
      downloaded: downloaded,
      reused: reused,
      failed: failed,
      playlistsUpdated: playlistsUpdated,
      cancelled: isCancellationRequested() && processed < total,
      failures: List.unmodifiable(failures),
    );
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
        'No hubo una coincidencia suficientemente segura para descargar.',
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
