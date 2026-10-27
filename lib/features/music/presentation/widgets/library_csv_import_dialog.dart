import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_dialog.dart';
import '../../../../services/storage/library_csv_import_service.dart';
import '../../../../services/storage/library_csv_service.dart';
import '../providers/music_providers.dart';

final _csvTransferDialogQueueProvider = Provider(
  (ref) => _CsvTransferDialogQueue(),
);

/// Includes the export save picker in the same queue: its controller state
/// must not be reset while a received CSV is waiting for confirmation.
Future<void> runLibraryCsvTransferFlow({
  required WidgetRef ref,
  required Future<void> Function() operation,
}) => ref.read(_csvTransferDialogQueueProvider).run(operation);

/// Uses the same explicit preview and confirmation for file-manager opens and
/// the Settings picker. Parsing alone never mutates the library.
Future<void> showLibraryCsvImportFlow({
  required BuildContext context,
  required WidgetRef ref,
  required String path,
  String? fileName,
}) {
  return runLibraryCsvTransferFlow(
    ref: ref,
    operation: () async {
      if (!context.mounted) return;
      final controller = ref.read(
        libraryCsvTransferControllerProvider.notifier,
      );
      final strings = ref.read(appStringsProvider);
      if (ref.read(libraryCsvTransferControllerProvider).isBusy) {
        throw StateError('Ya hay una transferencia CSV en curso.');
      }
      controller.reset();
      try {
        final document = await controller.preview(path);
        if (!context.mounted) return;
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (dialogContext) => _CsvImportPreviewDialog(
            document: document,
            strings: strings,
            fileName: fileName,
            onCancel: () => Navigator.of(dialogContext).pop(false),
            onConfirm: () => Navigator.of(dialogContext).pop(true),
          ),
        );
        if (!context.mounted || confirmed != true) return;
        await showAppDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              _CsvImportProgressDialog(document: document, strings: strings),
        );
      } finally {
        controller.reset();
      }
    },
  );
}

/// Keep simultaneous OS activations and the manual picker from stacking
/// confirmation dialogs or resetting another import's transfer state.
class _CsvTransferDialogQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> run(Future<void> Function() operation) async {
    final previous = _tail;
    final completion = Completer<void>();
    _tail = completion.future;
    try {
      await previous;
      await operation();
    } finally {
      completion.complete();
    }
  }
}

class _CsvImportPreviewDialog extends StatelessWidget {
  const _CsvImportPreviewDialog({
    required this.document,
    required this.strings,
    required this.onCancel,
    required this.onConfirm,
    this.fileName,
  });

  final LibraryCsvDocument document;
  final String? fileName;
  final AppStrings strings;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return AppAlertDialog(
      key: const ValueKey('csv-import-preview'),
      scrollable: true,
      title: Text(strings.csvImportTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (fileName?.trim().isNotEmpty == true) ...[
                Text(
                  fileName!,
                  key: const ValueKey('csv-import-file-name'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
              ],
              Chip(
                avatar: const Icon(Icons.table_view_rounded, size: 18),
                label: Text(_csvDetectedFormatLabel(document.detectedFormat)),
              ),
              const SizedBox(height: 12),
              Text(
                strings.csvImportPreview(
                  tracks: document.uniqueTrackCount,
                  playlists: document.playlistCount,
                  invalid: document.invalidRowCount,
                  duplicates: document.duplicateRowCount,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(strings.csvImportDataNotice)),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('csv-import-preview-cancel'),
          onPressed: onCancel,
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const ValueKey('csv-import-preview-confirm'),
          onPressed: onConfirm,
          child: Text(strings.importData),
        ),
      ],
    );
  }
}

class _CsvImportProgressDialog extends ConsumerStatefulWidget {
  const _CsvImportProgressDialog({
    required this.document,
    required this.strings,
  });

  final LibraryCsvDocument document;
  final AppStrings strings;

  @override
  ConsumerState<_CsvImportProgressDialog> createState() =>
      _CsvImportProgressDialogState();
}

class _CsvImportProgressDialogState
    extends ConsumerState<_CsvImportProgressDialog> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _started = true);
      unawaited(_runImport());
    });
  }

  Future<void> _runImport() async {
    try {
      await ref
          .read(libraryCsvTransferControllerProvider.notifier)
          .importDocument(widget.document);
    } catch (_) {
      // The controller publishes the terminal error for this dialog.
    }
  }

  @override
  Widget build(BuildContext context) {
    final transfer = ref.watch(libraryCsvTransferControllerProvider);
    final progress = transfer.progress;
    final result = transfer.result;
    final failed = transfer.phase == LibraryCsvTransferPhase.failed;
    final completed = result != null;
    final terminal = failed || completed;
    final cancelRequested = transfer.cancelRequested;

    return PopScope(
      canPop: terminal,
      child: AppAlertDialog(
        key: const ValueKey('csv-import-progress-dialog'),
        scrollable: true,
        title: Text(
          failed
              ? widget.strings.csvImportFailed
              : completed
              ? widget.strings.csvImportCompleted
              : widget.strings.csvImporting,
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: _buildContent(
              context,
              progress: progress,
              result: result,
              error: transfer.error,
              failed: failed,
              started: _started,
              cancelRequested: cancelRequested,
            ),
          ),
        ),
        actions: [
          if (!terminal)
            TextButton(
              key: const ValueKey('csv-import-request-cancel'),
              onPressed: cancelRequested
                  ? null
                  : () => ref
                        .read(libraryCsvTransferControllerProvider.notifier)
                        .requestCancel(),
              child: Text(
                cancelRequested
                    ? widget.strings.csvStopRequested
                    : widget.strings.stopAfterCurrent,
              ),
            ),
          if (terminal)
            FilledButton(
              key: const ValueKey('csv-import-close'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(widget.strings.close),
            ),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context, {
    required LibraryCsvImportProgress? progress,
    required LibraryCsvImportResult? result,
    required Object? error,
    required bool failed,
    required bool started,
    required bool cancelRequested,
  }) {
    if (result != null) {
      final details = result.failures.take(3).toList(growable: false);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            result.cancelled
                ? Icons.stop_circle_outlined
                : Icons.check_circle_rounded,
            size: 40,
            color: result.cancelled
                ? Theme.of(context).colorScheme.tertiary
                : Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(
            widget.strings.csvImportResult(
              imported: result.imported,
              reused: result.reused,
              failed: result.failed,
              playlists: result.playlistsUpdated,
            ),
          ),
          if (result.cancelled) ...[
            const SizedBox(height: 8),
            Text(widget.strings.csvImportCancelled),
          ],
          if (details.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final failure in details)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${failure.title}: ${readableCsvError(failure.message)}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ],
      );
    }
    if (failed) {
      return Text(
        '${widget.strings.csvImportFailed}\n${readableCsvError(error)}',
        key: const ValueKey('csv-import-error'),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }

    final processed = progress?.processed ?? 0;
    final total = progress?.total ?? widget.document.uniqueTrackCount;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          key: const ValueKey('csv-import-progress'),
          value: started && progress != null ? progress.fraction : null,
        ),
        const SizedBox(height: 12),
        Text(widget.strings.csvImportProgress(processed, total)),
        if ((progress?.currentTitle ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            progress!.currentTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (cancelRequested) ...[
          const SizedBox(height: 10),
          Text(widget.strings.csvStopRequested),
        ],
      ],
    );
  }
}

String _csvDetectedFormatLabel(LibraryCsvDetectedFormat format) =>
    switch (format) {
      LibraryCsvDetectedFormat.bstream => 'BStream',
      LibraryCsvDetectedFormat.metroList => 'MetroList',
      LibraryCsvDetectedFormat.harmony => 'Harmony / RiMusic',
      LibraryCsvDetectedFormat.exportify => 'Exportify',
      LibraryCsvDetectedFormat.soundiiz => 'Soundiiz',
      LibraryCsvDetectedFormat.generic => 'CSV',
    };

String readableCsvError(Object? error) {
  if (error == null) return '';
  var message = error.toString().trim();
  message = message.replaceFirst(
    RegExp(r'^(?:FormatException|Exception|StateError):\s*'),
    '',
  );
  final lines = message
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .take(3)
      .join('\n');
  final readable = lines.isEmpty ? message : lines;
  return readable.length <= 600 ? readable : '${readable.substring(0, 597)}...';
}
