part of 'music_providers.dart';

class DownloadMetadataRefreshSummary {
  const DownloadMetadataRefreshSummary({
    this.updated = 0,
    this.skipped = 0,
    this.failed = 0,
  });

  final int updated;
  final int skipped;
  final int failed;
}

class DownloadMetadataRefreshState {
  const DownloadMetadataRefreshState({
    this.running = false,
    this.processed = 0,
    this.total = 0,
    this.summary = const DownloadMetadataRefreshSummary(),
  });

  final bool running;
  final int processed;
  final int total;
  final DownloadMetadataRefreshSummary summary;
}

final downloadMetadataRefreshControllerProvider =
    NotifierProvider<
      DownloadMetadataRefreshController,
      DownloadMetadataRefreshState
    >(DownloadMetadataRefreshController.new);

/// Explicit maintenance for existing app-owned downloads. Each file shares the
/// regular download writer and maintenance gate, without resolving remote data.
class DownloadMetadataRefreshController
    extends Notifier<DownloadMetadataRefreshState> {
  Future<DownloadMetadataRefreshSummary>? _active;

  @override
  DownloadMetadataRefreshState build() => const DownloadMetadataRefreshState();

  Future<DownloadMetadataRefreshSummary> refresh() {
    final active = _active;
    if (active != null) return active;
    late final Future<DownloadMetadataRefreshSummary> operation;
    operation = _refresh().whenComplete(() {
      if (identical(_active, operation)) _active = null;
    });
    _active = operation;
    return operation;
  }

  Future<DownloadMetadataRefreshSummary> _refresh() async {
    state = const DownloadMetadataRefreshState(running: true);
    var summary = const DownloadMetadataRefreshSummary();
    var processed = 0;
    var total = 0;
    try {
      var library = await ref.read(libraryTracksProvider.future);
      var byId = {for (final track in library) track.id: track};
      final ids = byId.keys.toList(growable: false);
      total = ids.length;
      if (!ref.mounted) return summary;
      state = DownloadMetadataRefreshState(running: true, total: total);
      final coordinator = ref.read(libraryOperationCoordinatorProvider);
      for (final id in ids) {
        if (!ref.mounted) break;
        AudioMetadataWriteResult result;
        try {
          result = await coordinator.runWithGate(() async {
            // A restore or directory migration may have run between files.
            // Reuse the provider's cached list and rebuild its index only when
            // it changes, rather than querying SQLite for every track.
            final currentLibrary = await ref.read(libraryTracksProvider.future);
            if (!identical(currentLibrary, library)) {
              library = currentLibrary;
              byId = {for (final track in library) track.id: track};
            }
            final track = byId[id];
            if (track == null || track.isExternal) {
              return AudioMetadataWriteResult.unsupported;
            }
            final settings = await ref.read(settingsControllerProvider.future);
            final audioRoot = Directory(
              p.join(settings.downloadDirectory, 'audio'),
            );
            if (!await _isOwnedMetadataRefreshFile(track.filePath, audioRoot)) {
              return AudioMetadataWriteResult.unsupported;
            }
            final presented = ref.read(playerControllerProvider).value;
            final opened = ref.read(playerServiceProvider).currentSnapshot;
            if (_metadataRefreshMatchesOpenTrack(presented, track) ||
                _metadataRefreshMatchesOpenTrack(opened, track)) {
              return AudioMetadataWriteResult.unsupported;
            }
            return ref
                .read(downloadAudioMetadataServiceProvider)
                .embed(
                  filePath: track.filePath,
                  title: track.title,
                  artist: track.artist,
                  album: track.album,
                  artworkPath: track.thumbnailPath,
                );
          });
        } on LibraryBusyException {
          rethrow;
        } catch (error, stackTrace) {
          debugPrint('Downloaded metadata refresh failed: $error\n$stackTrace');
          result = AudioMetadataWriteResult.failed;
        }
        summary = switch (result) {
          AudioMetadataWriteResult.written => DownloadMetadataRefreshSummary(
            updated: summary.updated + 1,
            skipped: summary.skipped,
            failed: summary.failed,
          ),
          AudioMetadataWriteResult.unchanged ||
          AudioMetadataWriteResult.unsupported =>
            DownloadMetadataRefreshSummary(
              updated: summary.updated,
              skipped: summary.skipped + 1,
              failed: summary.failed,
            ),
          AudioMetadataWriteResult.failed => DownloadMetadataRefreshSummary(
            updated: summary.updated,
            skipped: summary.skipped,
            failed: summary.failed + 1,
          ),
        };
        processed++;
        if (ref.mounted) {
          state = DownloadMetadataRefreshState(
            running: true,
            total: total,
            processed: processed,
            summary: summary,
          );
        }
      }
      return summary;
    } finally {
      if (ref.mounted) {
        state = DownloadMetadataRefreshState(
          total: total,
          processed: processed,
          summary: summary,
        );
      }
    }
  }
}

Future<bool> _isOwnedMetadataRefreshFile(
  String path,
  Directory audioRoot,
) async {
  if (!p.isWithin(
    p.normalize(p.absolute(audioRoot.path)),
    p.normalize(p.absolute(path)),
  )) {
    return false;
  }
  final file = File(path);
  if (!await file.exists() || !await audioRoot.exists()) return false;
  // A file or directory symlink must not turn an app-owned path into a write
  // to the user's external music collection.
  final storageRoot = await audioRoot.parent.resolveSymbolicLinks();
  final resolvedAudioRoot = await audioRoot.resolveSymbolicLinks();
  if (!p.isWithin(storageRoot, resolvedAudioRoot)) return false;
  return p.isWithin(resolvedAudioRoot, await file.resolveSymbolicLinks());
}

bool _metadataRefreshMatchesOpenTrack(
  PlayerSnapshot? snapshot,
  LocalTrack track,
) {
  if (snapshot == null) return false;
  if (snapshot.trackId == track.id ||
      (track.sourceId != null && snapshot.trackId == track.sourceId)) {
    return true;
  }
  final source = snapshot.sourceUrl?.trim();
  if (source == null || source.isEmpty) return false;
  if (source == track.sourceUrl || p.equals(source, track.filePath)) {
    return true;
  }
  final uri = Uri.tryParse(source);
  return uri != null &&
      uri.scheme == 'file' &&
      p.equals(uri.toFilePath(), track.filePath);
}
