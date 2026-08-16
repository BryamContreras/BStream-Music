import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants/app_constants.dart';
import 'backup_restore_transaction.dart';
import 'library_operation_coordinator.dart';
import 'local_database_service.dart';

class BackupService {
  const BackupService(this._databaseService, this._coordinator);

  final LocalDatabaseService _databaseService;
  final LibraryOperationCoordinator _coordinator;

  Future<File> createBackupFile({
    required String mediaRoot,
    String? outputPath,
  }) {
    return _coordinator.runExclusive(
      LibraryMaintenancePhase.preparingBackup,
      () => _createBackupFileInternal(
        mediaRoot: mediaRoot,
        outputPath: outputPath,
      ),
    );
  }

  Future<void> restoreBackupFile({
    required String backupPath,
    required String mediaRoot,
  }) {
    return _coordinator.runExclusive(
      LibraryMaintenancePhase.preparingRestore,
      () => _restoreBackupFileInternal(
        backupPath: backupPath,
        mediaRoot: mediaRoot,
      ),
    );
  }

  Future<File> _createBackupFileInternal({
    required String mediaRoot,
    String? outputPath,
  }) async {
    await Directory(mediaRoot).create(recursive: true);
    await Directory(p.join(mediaRoot, 'audio')).create(recursive: true);
    await Directory(p.join(mediaRoot, 'thumbnails')).create(recursive: true);

    final destination = File(
      outputPath ??
          p.join(
            (await getTemporaryDirectory()).path,
            'bstream_backup_${DateTime.now().millisecondsSinceEpoch}.zip',
          ),
    );
    await destination.parent.create(recursive: true);
    if (await destination.exists()) {
      await destination.delete();
    }

    final snapshotRoot = Directory(
      p.join(
        (await getTemporaryDirectory()).path,
        'bstream_backup_snapshot_${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    try {
      await snapshotRoot.create(recursive: true);
      final databasePath = await _databaseService.databasePath();

      _coordinator.updatePhase(LibraryMaintenancePhase.snapshotting);

      // Best-effort WAL checkpoint to flush data before closing.
      // If the database is not open or the checkpoint fails, we still
      // proceed with the snapshot from the closed files.
      try {
        await _databaseService.withDatabase((db) async {
          await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        });
      } catch (_) {
        // Database may not be open yet, or checkpoint may fail.
        // Continue with the snapshot from closed files.
      }

      await _databaseService.close();
      try {
        final databaseSnapshotDir = Directory(
          p.join(snapshotRoot.path, 'database'),
        );
        await databaseSnapshotDir.create(recursive: true);
        final databaseFile = File(databasePath);
        if (await databaseFile.exists()) {
          await databaseFile.copy(
            p.join(snapshotRoot.path, 'database', AppConstants.databaseName),
          );
        }
        for (final suffix in const ['-wal', '-shm', '-journal']) {
          final sidecar = File('$databasePath$suffix');
          if (await sidecar.exists()) {
            await sidecar.copy(
              p.join(
                snapshotRoot.path,
                'database',
                '${AppConstants.databaseName}$suffix',
              ),
            );
          }
        }
        for (final folder in const ['audio', 'thumbnails']) {
          final sourceDir = Directory(p.join(mediaRoot, folder));
          if (await sourceDir.exists()) {
            await _copyDirectory(
              source: sourceDir,
              destination: Directory(p.join(snapshotRoot.path, folder)),
            );
          }
        }
      } finally {
        await _databaseService.initialize();
      }

      final databaseSnapshot = File(
        p.join(snapshotRoot.path, 'database', AppConstants.databaseName),
      );
      final encoder = ZipFileEncoder();
      encoder.create(destination.path, level: ZipFileEncoder.gzip);
      var closed = false;
      try {
        encoder.addArchiveFile(
          ArchiveFile.string(
            'manifest.json',
            jsonEncode({
              'app': AppConstants.appName,
              'schema': 1,
              'database': AppConstants.databaseName,
              'exportedAt': DateTime.now().toIso8601String(),
            }),
          ),
        );
        if (await databaseSnapshot.exists()) {
          await encoder.addFile(
            databaseSnapshot,
            'database/${AppConstants.databaseName}',
            ZipFileEncoder.gzip,
          );
        }
        for (final folder in const ['audio', 'thumbnails']) {
          final directory = Directory(p.join(snapshotRoot.path, folder));
          if (await directory.exists()) {
            await encoder.addDirectory(
              directory,
              includeDirName: true,
              level: ZipFileEncoder.store,
            );
          }
        }
        await encoder.close();
        closed = true;
      } finally {
        if (!closed) {
          try {
            await encoder.close();
          } catch (_) {
            // Preserve the original export error.
          }
        }
      }
    } finally {
      if (await snapshotRoot.exists()) {
        await snapshotRoot.delete(recursive: true);
      }
    }
    return destination;
  }

  Future<void> _restoreBackupFileInternal({
    required String backupPath,
    required String mediaRoot,
  }) async {
    final backup = File(backupPath);
    if (!await backup.exists() || await backup.length() == 0) {
      throw const FormatException(
        'El archivo de respaldo no existe o está vacío.',
      );
    }

    final temporaryRoot = Directory(
      p.join(
        (await getTemporaryDirectory()).path,
        'bstream_import_${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
    await temporaryRoot.create(recursive: true);

    try {
      _coordinator.updatePhase(LibraryMaintenancePhase.preparingRestore);
      await Isolate.run(
        () => _extractBackupArchive(
          backupPath: backup.path,
          outputPath: temporaryRoot.path,
        ),
      );

      final extractedDatabase = File(
        p.join(temporaryRoot.path, 'database', AppConstants.databaseName),
      );
      if (!await extractedDatabase.exists()) {
        throw const FormatException(
          'El respaldo no contiene la base de datos.',
        );
      }

      await _validateBackupManifest(temporaryRoot);
      await _databaseService.validateBackupDatabase(extractedDatabase.path);

      _coordinator.updatePhase(LibraryMaintenancePhase.committingRestore);
      final mediaDirectory = Directory(mediaRoot);
      await mediaDirectory.create(recursive: true);
      final databasePath = await _databaseService.databasePath();
      final transaction = await BackupRestoreTransaction.prepare(
        extractedRoot: temporaryRoot,
        mediaRoot: mediaDirectory,
        activeDatabase: File(databasePath),
      );

      try {
        await _databaseService.close();
        await transaction.commit();
        await _databaseService.initialize();
        await _databaseService.rewriteLocalTrackMediaRoot(mediaRoot: mediaRoot);
      } catch (error, stackTrace) {
        Object? rollbackError;
        StackTrace? rollbackStackTrace;

        Future<void> attemptRollbackStep(Future<void> Function() action) async {
          try {
            await action();
          } catch (failure, failureStackTrace) {
            rollbackError ??= failure;
            rollbackStackTrace ??= failureStackTrace;
          }
        }

        await attemptRollbackStep(_databaseService.close);
        await attemptRollbackStep(transaction.rollback);
        await attemptRollbackStep(_databaseService.initialize);

        if (rollbackError != null) {
          Error.throwWithStackTrace(
            BackupRestoreException(
              restoreError: error,
              rollbackError: rollbackError!,
            ),
            rollbackStackTrace ?? stackTrace,
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      try {
        await transaction.complete();
      } catch (_) {
        // The restored library is already active. Cleanup is best effort so a
        // stale inactive rollback copy never turns a successful restore into
        // a reported data-loss failure.
      }
    } finally {
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    }
  }

  static Future<void> _copyDirectory({
    required Directory source,
    required Directory destination,
  }) async {
    await destination.create(recursive: true);
    if (!await source.exists()) {
      return;
    }
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: source.path);
      final targetPath = p.join(destination.path, relative);
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        final target = File(targetPath);
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      }
    }
  }
}

class BackupRestoreException implements Exception {
  const BackupRestoreException({
    required this.restoreError,
    required this.rollbackError,
  });

  final Object restoreError;
  final Object rollbackError;

  @override
  String toString() {
    return 'La restauración falló y no se pudo recuperar completamente la '
        'biblioteca anterior. Restauración: $restoreError. '
        'Recuperación: $rollbackError';
  }
}

Future<void> _extractBackupArchive({
  required String backupPath,
  required String outputPath,
}) async {
  const maxEntries = 100000;
  const maxExpandedBytes = 64 * 1024 * 1024 * 1024;

  final input = InputFileStream(backupPath);
  final archive = ZipDecoder().decodeStream(input);
  var entryCount = 0;
  var expandedBytes = 0;
  try {
    for (final entry in archive) {
      if (entry.isDirectory || entry.isSymbolicLink) {
        continue;
      }
      entryCount++;
      expandedBytes += entry.size;
      if (entryCount > maxEntries || expandedBytes > maxExpandedBytes) {
        throw const FormatException(
          'El respaldo excede los límites permitidos.',
        );
      }

      final relative = _safeBackupEntryName(entry.name);
      if (relative == null) {
        continue;
      }
      final destination = File(p.join(outputPath, relative));
      await destination.parent.create(recursive: true);
      final output = OutputFileStream(destination.path);
      try {
        entry.writeContent(output);
      } finally {
        await output.close();
      }
    }
  } finally {
    await archive.clear();
    await input.close();
  }
}

Future<void> _validateBackupManifest(Directory extractedRoot) async {
  const maximumManifestBytes = 64 * 1024;
  final manifest = File(p.join(extractedRoot.path, 'manifest.json'));
  if (!await manifest.exists()) {
    // Backups created before manifests were introduced remain importable; the
    // SQLite integrity and schema checks are still authoritative.
    return;
  }
  if (await manifest.length() > maximumManifestBytes) {
    throw const FormatException(
      'El manifiesto del respaldo excede el límite permitido.',
    );
  }

  try {
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map ||
        decoded['app'] != AppConstants.appName ||
        decoded['schema'] != 1 ||
        decoded['database'] != AppConstants.databaseName) {
      throw const FormatException(
        'El manifiesto del respaldo no es compatible.',
      );
    }
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('El manifiesto del respaldo no es válido.', error);
  }
}

String? _safeBackupEntryName(String name) {
  final normalized = name.replaceAll(r'\', '/').trim();
  if (normalized == 'manifest.json') {
    return 'manifest.json';
  }
  if (normalized == 'database/${AppConstants.databaseName}') {
    return p.join('database', AppConstants.databaseName);
  }

  String? prefix;
  if (normalized.startsWith('audio/')) {
    prefix = 'audio';
  } else if (normalized.startsWith('thumbnails/')) {
    prefix = 'thumbnails';
  }
  if (prefix == null) {
    return null;
  }

  final relative = normalized.substring(prefix.length + 1);
  if (relative.isEmpty || relative.startsWith('/') || relative.contains(':')) {
    return null;
  }
  final parts = relative.split('/');
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    return null;
  }
  return p.join(prefix, p.joinAll(parts));
}
