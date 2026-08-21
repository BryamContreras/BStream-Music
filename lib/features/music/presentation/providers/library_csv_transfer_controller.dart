part of 'music_providers.dart';

final libraryCsvServiceProvider = Provider<LibraryCsvService>((ref) {
  return const LibraryCsvService();
});

final libraryCsvImportServiceProvider = Provider<LibraryCsvImportService>((
  ref,
) {
  return LibraryCsvImportService(
    ref.watch(libraryRepositoryProvider),
    (query) => ref.read(searchTracksProvider).call(query),
    (track, {required taskId, onResolved}) async {
      final outcome = await ref
          .read(localTrackDownloadHelperProvider)
          .resolveForLibrary(
            track,
            taskId: taskId,
            onResolved: onResolved,
            allowConcurrentDownload: true,
          );
      return LibraryCsvDownloadedTrack(
        track: outcome.track,
        reusedExisting: outcome.reusedExisting,
      );
    },
    _libraryCsvGate(ref),
    maxConcurrentTracks: 3,
  );
});

final libraryCsvTransferControllerProvider =
    NotifierProvider<LibraryCsvTransferController, LibraryCsvTransferState>(
      LibraryCsvTransferController.new,
    );

enum LibraryCsvTransferPhase {
  idle,
  parsing,
  importing,
  exporting,
  completed,
  failed,
}

class LibraryCsvTransferState {
  const LibraryCsvTransferState({
    this.phase = LibraryCsvTransferPhase.idle,
    this.document,
    this.progress,
    this.result,
    this.error,
    this.errorStackTrace,
    this.cancelRequested = false,
  });

  final LibraryCsvTransferPhase phase;
  final LibraryCsvDocument? document;
  final LibraryCsvImportProgress? progress;
  final LibraryCsvImportResult? result;
  final Object? error;
  final StackTrace? errorStackTrace;
  final bool cancelRequested;

  bool get isBusy =>
      phase == LibraryCsvTransferPhase.parsing ||
      phase == LibraryCsvTransferPhase.importing ||
      phase == LibraryCsvTransferPhase.exporting;
}

class LibraryCsvTransferController extends Notifier<LibraryCsvTransferState> {
  bool _cancelRequested = false;

  @override
  LibraryCsvTransferState build() => const LibraryCsvTransferState();

  Future<LibraryCsvDocument> preview(String path) async {
    _ensureIdle();
    _cancelRequested = false;
    state = const LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.parsing,
    );
    try {
      final document = await compute(_parseLibraryCsvFile, path);
      state = LibraryCsvTransferState(
        phase: LibraryCsvTransferPhase.completed,
        document: document,
      );
      return document;
    } catch (error, stackTrace) {
      state = LibraryCsvTransferState(
        phase: LibraryCsvTransferPhase.failed,
        error: error,
        errorStackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<LibraryCsvImportResult> importDocument(
    LibraryCsvDocument document,
  ) async {
    _ensureIdle();
    _cancelRequested = false;
    state = LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.importing,
      document: document,
    );
    try {
      final result = await ref
          .read(libraryCsvImportServiceProvider)
          .import(
            document,
            isCancellationRequested: () => _cancelRequested,
            onProgress: (progress) {
              if (state.phase != LibraryCsvTransferPhase.importing) return;
              state = LibraryCsvTransferState(
                phase: LibraryCsvTransferPhase.importing,
                document: document,
                progress: progress,
                cancelRequested: _cancelRequested,
              );
            },
          );
      ref
        ..invalidate(libraryTracksProvider)
        ..invalidate(playlistsControllerProvider);
      state = LibraryCsvTransferState(
        phase: LibraryCsvTransferPhase.completed,
        document: document,
        result: result,
        cancelRequested: result.cancelled,
      );
      return result;
    } catch (error, stackTrace) {
      ref
        ..invalidate(libraryTracksProvider)
        ..invalidate(playlistsControllerProvider);
      state = LibraryCsvTransferState(
        phase: LibraryCsvTransferPhase.failed,
        document: document,
        error: error,
        errorStackTrace: stackTrace,
        cancelRequested: _cancelRequested,
      );
      rethrow;
    }
  }

  void requestCancel() {
    if (state.phase != LibraryCsvTransferPhase.importing || _cancelRequested) {
      return;
    }
    _cancelRequested = true;
    final progress = state.progress;
    state = LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.importing,
      document: state.document,
      progress: progress == null
          ? null
          : LibraryCsvImportProgress(
              total: progress.total,
              processed: progress.processed,
              downloaded: progress.downloaded,
              reused: progress.reused,
              failed: progress.failed,
              currentTitle: progress.currentTitle,
              cancelRequested: true,
            ),
      cancelRequested: true,
    );
  }

  Future<LibraryCsvDocument> prepareExport() async {
    _ensureIdle();
    _cancelRequested = false;
    state = const LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.exporting,
    );
    try {
      final document = await ref
          .read(libraryOperationCoordinatorProvider)
          .runExclusive(LibraryMaintenancePhase.exportingCsv, () async {
            final repository = ref.read(libraryRepositoryProvider);
            final tracks = await repository.getLocalTracks();
            final playlists = await repository.getPlaylists();
            return LibraryCsvDocument.fromLibrary(
              tracks: tracks,
              playlists: playlists,
            );
          });
      state = LibraryCsvTransferState(
        phase: LibraryCsvTransferPhase.completed,
        document: document,
      );
      return document;
    } catch (error, stackTrace) {
      state = LibraryCsvTransferState(
        phase: LibraryCsvTransferPhase.failed,
        error: error,
        errorStackTrace: stackTrace,
      );
      rethrow;
    }
  }

  void reset() {
    if (state.isBusy) return;
    _cancelRequested = false;
    state = const LibraryCsvTransferState();
  }

  void _ensureIdle() {
    if (state.isBusy) {
      throw StateError('Ya hay una transferencia CSV en curso.');
    }
  }
}

LibraryCsvGate _libraryCsvGate(Ref ref) {
  return <T>(operation) => ref
      .read(libraryOperationCoordinatorProvider)
      .runExclusive(LibraryMaintenancePhase.importingCsv, operation);
}

Future<LibraryCsvDocument> _parseLibraryCsvFile(String path) {
  return const LibraryCsvService().importFile(path);
}
