import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/background_work.dart';
import 'backup_audio_layout.dart';
import 'backup_restore_transaction.dart';
import 'library_operation_coordinator.dart';
import 'local_database_service.dart';

const int _backupMaxEntries = 25000;
const int _backupMaxExpandedBytes = 16 * 1024 * 1024 * 1024;
const int _backupMaxSingleEntryBytes = 8 * 1024 * 1024 * 1024;
const int _backupMaxExpansionRatio = 200;
const int _backupMinimumExpansionAllowance = 64 * 1024 * 1024;
const int _backupMaximumAudioIndexBytes = 16 * 1024 * 1024;
final _backupInvalidPathCharacters = RegExp(r'[<>:"|?*\x00-\x1f\x7f]');
final _backupReservedDevice = RegExp(
  r'^(?:con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
  caseSensitive: false,
);

/// Validates declared ZIP sizes before any backup entry is expanded to disk.
///
/// Media files in BStream backups are stored without compression, while the
/// database and manifest are compressed. The generous ratio allowance keeps
/// legitimate libraries compatible but rejects tiny ZIP bombs before they can
/// consume storage or inodes on a phone.
void validateBackupArchiveBudget({
  required int archiveBytes,
  required Iterable<int> entrySizes,
  int maxEntries = _backupMaxEntries,
  int maxExpandedBytes = _backupMaxExpandedBytes,
  int maxSingleEntryBytes = _backupMaxSingleEntryBytes,
  int maxExpansionRatio = _backupMaxExpansionRatio,
  int minimumExpansionAllowance = _backupMinimumExpansionAllowance,
}) {
  if (archiveBytes <= 0 ||
      maxEntries <= 0 ||
      maxExpandedBytes <= 0 ||
      maxSingleEntryBytes <= 0 ||
      maxExpansionRatio <= 0 ||
      minimumExpansionAllowance < 0) {
    throw const FormatException('El presupuesto del respaldo no es valido.');
  }

  var count = 0;
  var expandedBytes = 0;
  for (final size in entrySizes) {
    if (size < 0 || size > maxSingleEntryBytes) {
      throw const FormatException(
        'Un archivo del respaldo excede el limite permitido.',
      );
    }
    count++;
    expandedBytes += size;
    if (count > maxEntries || expandedBytes > maxExpandedBytes) {
      throw const FormatException('El respaldo excede los limites permitidos.');
    }
  }

  final ratioAllowance = archiveBytes * maxExpansionRatio;
  final allowedByCompression = ratioAllowance > minimumExpansionAllowance
      ? ratioAllowance
      : minimumExpansionAllowance;
  if (expandedBytes > allowedByCompression) {
    throw const FormatException(
      'El respaldo tiene una relacion de compresion no segura.',
    );
  }
}

class BackupService {
  const BackupService(this._databaseService, this._coordinator);

  final LocalDatabaseService _databaseService;
  final LibraryOperationCoordinator _coordinator;

  Future<File> createBackupFile({
    required String mediaRoot,
    String? outputPath,
    String downloadedFolderName = 'Downloaded songs',
  }) {
    return _coordinator.runExclusive(
      LibraryMaintenancePhase.preparingBackup,
      () => _createBackupFileInternal(
        mediaRoot: mediaRoot,
        outputPath: outputPath,
        downloadedFolderName: downloadedFolderName,
      ),
    );
  }

  Future<void> restoreBackupFile({
    required String backupPath,
    required String mediaRoot,
  }) {
    return _coordinator.runExclusive(
      LibraryMaintenancePhase.preparingRestore,
      () async {
        try {
          await _restoreBackupFileInternal(
            backupPath: backupPath,
            mediaRoot: mediaRoot,
          );
        } finally {
          // This runs before the coordinator releases waiting readers. Any
          // recommendation request queued against the previous database epoch
          // is rejected when its gate opens.
          _databaseService.advanceRecommendationGeneration();
        }
      },
    );
  }

  Future<File> _createBackupFileInternal({
    required String mediaRoot,
    String? outputPath,
    required String downloadedFolderName,
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
      final audioMetadata = await _databaseService.getBackupAudioMetadata();

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

      // Async file I/O does not move ZIP compression off the UI isolate.
      // The worker sees plain metadata and file paths, never a live database.
      await runBackgroundWork<void>(
        _BackupArchiveWriter(
          snapshotRoot.path,
          destination.path,
          mediaRoot,
          audioMetadata,
          downloadedFolderName,
        ).write,
      );
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
      await runBackgroundWork(
        () => _extractBackupArchive(
          backupPath: backup.path,
          outputPath: temporaryRoot.path,
        ),
        debugName: 'BStream backup extraction',
      );

      final extractedDatabase = File(
        p.join(temporaryRoot.path, 'database', AppConstants.databaseName),
      );
      if (!await extractedDatabase.exists()) {
        throw const FormatException(
          'El respaldo no contiene la base de datos.',
        );
      }

      final audioIndex = await _validateBackupManifest(temporaryRoot);
      await _databaseService.validateBackupDatabase(extractedDatabase.path);
      if (audioIndex != null) {
        // Portable playlists belong in the exported ZIP. The app restores
        // membership from SQLite and regenerates M3Us on its next export.
        for (final path in audioIndex.playlistFiles) {
          await File(
            p.join(temporaryRoot.path, p.joinAll(path.split('/'))),
          ).delete();
        }
      }

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
        if (audioIndex != null) {
          await _applyRestoredAudioPaths(
            audioIndex.tracks,
            mediaRoot: mediaRoot,
          );
        }
        await _databaseService.rebasePlaylistSyncAfterRestore();
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

  Future<void> _applyRestoredAudioPaths(
    Map<String, String> audioPaths, {
    required String mediaRoot,
  }) async {
    // Schema 2 identifies every included download by ID. A row without a
    // mapping had no owned audio in the snapshot; rebasing it by basename
    // could accidentally attach an unrelated file after flattening folders.
    // Keep such rows unavailable beneath a directory absent from the payload.
    final audioRoot = p.join(mediaRoot, 'audio');
    var unavailableRoot = p.join(audioRoot, '.bstream-unavailable');
    var suffix = 2;
    while (await FileSystemEntity.type(unavailableRoot, followLinks: false) !=
        FileSystemEntityType.notFound) {
      unavailableRoot = p.join(audioRoot, '.bstream-unavailable-${suffix++}');
    }
    await _databaseService.withDatabase(
      (db) => db.transaction((transaction) async {
        final rows = await transaction.query('local_tracks', columns: ['id']);
        final unmatched = audioPaths.keys.toSet();
        final batch = transaction.batch();
        var unavailableIndex = 0;
        for (final row in rows) {
          final id = row['id'] as String;
          final relative = audioPaths[id];
          unmatched.remove(id);
          batch.update(
            'local_tracks',
            {
              'file_path': relative == null
                  ? p.join(unavailableRoot, '${unavailableIndex++}.missing')
                  : p.join(mediaRoot, p.joinAll(relative.split('/'))),
            },
            where: 'id = ?',
            whereArgs: [id],
          );
        }
        if (unmatched.isNotEmpty) {
          throw const FormatException(
            'El índice de audio no coincide con la biblioteca del respaldo.',
          );
        }
        await batch.commit(noResult: true);
      }),
    );
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
  await _preflightBackupArchive(backupPath);

  final input = InputFileStream(backupPath);
  Archive? archive;
  try {
    archive = ZipDecoder().decodeStream(input);
    final files = <ArchiveFile>[];
    for (final entry in archive) {
      if (entry.isSymbolicLink) {
        throw const FormatException(
          'El respaldo no puede contener enlaces simbolicos.',
        );
      }
      if (entry.isDirectory) {
        continue;
      }
      files.add(entry);
    }
    validateBackupArchiveBudget(
      archiveBytes: await File(backupPath).length(),
      entrySizes: files.map((entry) => entry.size),
    );

    final approvedEntries = <String, ({String relative, ArchiveFile entry})>{};
    for (final entry in files) {
      final relative = _safeBackupEntryName(entry.name);
      if (relative == null) {
        continue;
      }
      final canonicalKey = _canonicalBackupDestinationKey(relative);
      if (approvedEntries.containsKey(canonicalKey)) {
        throw FormatException(
          'El respaldo contiene una entrada duplicada: $relative',
        );
      }
      approvedEntries[canonicalKey] = (relative: relative, entry: entry);
    }

    for (final approved in approvedEntries.values) {
      final relative = approved.relative;
      final entry = approved.entry;
      final destination = File(p.join(outputPath, relative));
      await destination.parent.create(recursive: true);
      if (await destination.exists()) {
        // The destination filesystem may equate Unicode variants that have
        // different ZIP names. Reject aliases before any active data is touched.
        throw FormatException(
          'El respaldo contiene una ruta equivalente: $relative',
        );
      }
      final output = _BoundedBackupOutputStream(
        OutputFileStream(destination.path),
        maximumBytes: entry.size,
      );
      try {
        entry.writeContent(output);
      } finally {
        await output.close();
      }
      if (await destination.length() != entry.size) {
        throw FormatException(
          'El respaldo contiene un archivo truncado: $relative',
        );
      }
    }
  } finally {
    await archive?.clear();
    await input.close();
  }
}

/// Reads central-directory metadata without expanding any entry.
///
/// [ZipDecoder] materializes symbolic-link contents while constructing an
/// [Archive]. Rejecting those entries and enforcing declared budgets here is
/// therefore intentionally a separate pass that runs first. It also sees
/// exact duplicate headers that [Archive] would otherwise collapse by name.
Future<void> _preflightBackupArchive(String backupPath) async {
  final input = InputFileStream(backupPath);
  try {
    final directory = ZipDirectory()..read(input);
    if (directory.filePosition < 0) {
      throw const FormatException('El archivo no es un respaldo ZIP valido.');
    }
    if (directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        directory.totalCentralDirectoryEntriesOnThisDisk !=
            directory.totalCentralDirectoryEntries) {
      throw const FormatException(
        'Los respaldos ZIP divididos no son compatibles.',
      );
    }

    final headers = directory.fileHeaders;
    if (headers.length != directory.totalCentralDirectoryEntries) {
      throw const FormatException(
        'El directorio del respaldo ZIP esta incompleto.',
      );
    }
    validateBackupArchiveBudget(
      archiveBytes: await File(backupPath).length(),
      // Count directories and ignored entries too. They still consume parser
      // memory even though BStream never writes them to the extraction root.
      entrySizes: headers.map((header) => header.uncompressedSize),
    );

    final approvedPaths = <String>{};
    for (final header in headers) {
      if (_isZipSymbolicLink(header)) {
        throw const FormatException(
          'El respaldo no puede contener enlaces simbolicos.',
        );
      }
      if (_isZipDirectory(header)) {
        continue;
      }

      final relative = _safeBackupEntryName(header.filename);
      if (relative == null) {
        continue;
      }
      if ((header.generalPurposeBitFlag & 0x1) != 0) {
        throw const FormatException(
          'El respaldo no puede contener archivos cifrados.',
        );
      }
      if (header.compressionMethod != ZipFile.zipCompressionStore &&
          header.compressionMethod != ZipFile.zipCompressionDeflate &&
          header.compressionMethod != ZipFile.zipCompressionBZip2) {
        throw FormatException(
          'El respaldo usa una compresion ZIP no compatible: '
          '${header.compressionMethod}',
        );
      }

      final canonicalKey = _canonicalBackupDestinationKey(relative);
      if (!approvedPaths.add(canonicalKey)) {
        throw FormatException(
          'El respaldo contiene una entrada duplicada: $relative',
        );
      }
    }
  } finally {
    await input.close();
  }
}

bool _isZipDirectory(ZipFileHeader header) {
  return header.filename.endsWith('/') || header.filename.endsWith(r'\');
}

bool _isZipSymbolicLink(ZipFileHeader header) {
  const unixCreator = 3;
  const unixFileTypeMask = 0xf000;
  const unixSymbolicLink = 0xa000;
  return header.versionMadeBy >> 8 == unixCreator &&
      ((header.externalFileAttributes >> 16) & unixFileTypeMask) ==
          unixSymbolicLink;
}

String _canonicalBackupDestinationKey(String relative) {
  // Use portable, case-insensitive ZIP identity on every platform. A backup
  // created on Android may later be restored on Windows, where case-only
  // variants would target the same file.
  return p.posix.normalize(relative.replaceAll(r'\', '/')).toLowerCase();
}

class _BoundedBackupOutputStream extends OutputStream {
  _BoundedBackupOutputStream(this._output, {required this.maximumBytes})
    : super(byteOrder: _output.byteOrder);

  final OutputFileStream _output;
  final int maximumBytes;
  int _writtenBytes = 0;

  @override
  int get length => _output.length;

  @override
  bool get isOpen => _output.isOpen;

  @override
  void clear() {
    _output.clear();
  }

  @override
  Future<void> close() => _output.close();

  @override
  void closeSync() => _output.closeSync();

  @override
  void flush() => _output.flush();

  @override
  void writeByte(int value) {
    _reserve(1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final byteCount = length ?? bytes.length;
    if (byteCount < 0 || byteCount > bytes.length) {
      throw RangeError.range(byteCount, 0, bytes.length, 'length');
    }
    _reserve(byteCount);
    _output.writeBytes(bytes, length: byteCount);
  }

  @override
  void writeStream(InputStream stream) {
    _reserve(stream.length);
    _output.writeStream(stream);
  }

  @override
  Uint8List subset(int start, [int? end]) => _output.subset(start, end);

  void _reserve(int byteCount) {
    if (_writtenBytes + byteCount > maximumBytes) {
      throw const FormatException(
        'Un archivo del respaldo excede el tamano declarado.',
      );
    }
    _writtenBytes += byteCount;
  }
}

class _BackupAudioIndex {
  const _BackupAudioIndex(this.tracks, this.playlistFiles);

  final Map<String, String> tracks;
  final List<String> playlistFiles;
}

Future<_BackupAudioIndex?> _validateBackupManifest(
  Directory extractedRoot,
) async {
  const maximumManifestBytes = 64 * 1024;
  final manifest = File(p.join(extractedRoot.path, 'manifest.json'));
  if (!await manifest.exists()) {
    // Backups created before manifests were introduced remain importable; the
    // SQLite integrity and schema checks are still authoritative.
    if (await File(p.join(extractedRoot.path, 'audio-index.json')).exists()) {
      throw const FormatException('El índice de audio no tiene manifiesto.');
    }
    return null;
  }
  if (await manifest.length() > maximumManifestBytes) {
    throw const FormatException(
      'El manifiesto del respaldo excede el límite permitido.',
    );
  }

  try {
    final decoded = jsonDecode(await manifest.readAsString());
    if (decoded is! Map<String, dynamic> ||
        decoded['app'] != AppConstants.appName ||
        (decoded['schema'] != 1 && decoded['schema'] != 2) ||
        decoded['database'] != AppConstants.databaseName) {
      throw const FormatException(
        'El manifiesto del respaldo no es compatible.',
      );
    }
    if (decoded['schema'] == 1) {
      if (decoded.containsKey('audioIndex') ||
          await File(p.join(extractedRoot.path, 'audio-index.json')).exists()) {
        throw const FormatException(
          'El formato del índice de audio no coincide.',
        );
      }
      return null;
    }
    if (decoded['audioIndex'] != 'audio-index.json') {
      throw const FormatException(
        'El respaldo no declara un índice de audio válido.',
      );
    }
    return await _readBackupAudioIndex(extractedRoot);
  } on FormatException {
    rethrow;
  } catch (error) {
    throw FormatException('El manifiesto del respaldo no es válido.', error);
  }
}

Future<_BackupAudioIndex> _readBackupAudioIndex(Directory root) async {
  final file = File(p.join(root.path, 'audio-index.json'));
  if (!await file.exists() ||
      await file.length() > _backupMaximumAudioIndexBytes) {
    throw const FormatException('El índice de audio falta o excede el límite.');
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic> ||
      decoded['schema'] != 1 ||
      decoded['audioFiles'] is! List ||
      decoded['playlistFiles'] is! List ||
      decoded['tracks'] is! Map<String, dynamic>) {
    throw const FormatException('El índice de audio no es compatible.');
  }
  final audioFiles = <String>{};
  final allPaths = <String>{};
  final canonicalPaths = <String>{};
  for (final field in ['audioFiles', 'playlistFiles']) {
    for (final raw in decoded[field] as List<dynamic>) {
      if (raw is! String || !_isPortableIndexedAudioPath(raw)) {
        throw const FormatException(
          'El índice contiene una ruta de audio no segura.',
        );
      }
      if (!canonicalPaths.add(_canonicalBackupDestinationKey(raw))) {
        throw const FormatException('El índice contiene una ruta duplicada.');
      }
      allPaths.add(raw);
      if (field == 'audioFiles') audioFiles.add(raw);
      if (allPaths.length > _backupMaxEntries ||
          !await File(p.join(root.path, p.joinAll(raw.split('/')))).exists()) {
        throw const FormatException(
          'Un archivo del índice no existe en el respaldo.',
        );
      }
      if (field == 'playlistFiles' &&
          (p.posix.basename(raw) != 'playlist.m3u8' ||
              !await _hasBackupPlaylistHeader(
                File(p.join(root.path, p.joinAll(raw.split('/')))),
              ))) {
        throw const FormatException(
          'El índice contiene una lista auxiliar no válida.',
        );
      }
    }
  }
  final rawTracks = decoded['tracks'] as Map<String, dynamic>;
  if (rawTracks.length > _backupMaxEntries) {
    throw const FormatException('El índice contiene demasiadas canciones.');
  }
  final tracks = <String, String>{};
  for (final entry in rawTracks.entries) {
    final path = entry.value;
    if (entry.key.isEmpty || path is! String || !audioFiles.contains(path)) {
      throw const FormatException(
        'Una canción del índice no tiene audio válido.',
      );
    }
    tracks[entry.key] = path;
  }
  final audioRoot = Directory(p.join(root.path, 'audio'));
  if (await audioRoot.exists()) {
    await for (final entity in audioRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p
          .split(p.relative(entity.path, from: root.path))
          .join('/');
      if (!allPaths.contains(relative)) {
        throw const FormatException(
          'El respaldo contiene audio fuera del índice.',
        );
      }
    }
  }
  return _BackupAudioIndex(
    tracks,
    (decoded['playlistFiles'] as List<dynamic>).cast<String>(),
  );
}

Future<bool> _hasBackupPlaylistHeader(File file) async {
  final input = await file.open();
  try {
    return ascii.decode(await input.read(8), allowInvalid: true) == '#EXTM3U\n';
  } finally {
    await input.close();
  }
}

bool _isPortableIndexedAudioPath(String path) {
  if (!path.startsWith('audio/') ||
      path.contains(r'\') ||
      path.trim() != path) {
    return false;
  }
  final safe = _safeBackupEntryName(path);
  if (safe == null || p.split(safe).join('/') != path) return false;
  for (final part in path.split('/').skip(1)) {
    if (part.endsWith('.') ||
        part.endsWith(' ') ||
        _backupInvalidPathCharacters.hasMatch(part) ||
        utf8.encode(part).length > 255 ||
        _backupReservedDevice.hasMatch(part.split('.').first.trim())) {
      return false;
    }
  }
  return true;
}

class _BackupArchiveWriter {
  const _BackupArchiveWriter(
    this.snapshotPath,
    this.destinationPath,
    this.originalMediaRoot,
    this.metadata,
    this.downloadedFolderName,
  );

  final String snapshotPath;
  final String destinationPath;
  final String originalMediaRoot;
  final BackupAudioMetadata metadata;
  final String downloadedFolderName;

  Future<void> write() async {
    final databaseSnapshot = File(
      p.join(snapshotPath, 'database', AppConstants.databaseName),
    );
    final audioRoot = p.join(snapshotPath, 'audio');
    final layout = await BackupAudioLayout.build(
      snapshotAudioRoot: audioRoot,
      originalMediaRoot: originalMediaRoot,
      metadata: metadata,
      downloadedFolderName: downloadedFolderName,
    );
    final indexed =
        layout.grouped ||
        metadata.tracks.any(
          (row) => !layout.trackPaths.containsKey(row['id']),
        ) ||
        layout.audioFiles.any((file) {
          final original = p.posix.join(
            'audio',
            p.split(p.relative(file.sourcePath, from: audioRoot)).join('/'),
          );
          return original != file.archivePath;
        });
    String? audioIndex;
    if (indexed) {
      audioIndex = jsonEncode({
        'schema': 1,
        'audioFiles': [for (final file in layout.audioFiles) file.archivePath],
        'playlistFiles': [
          for (final file in layout.playlists) file.archivePath,
        ],
        'tracks': layout.trackPaths,
      });
      if (utf8.encode(audioIndex).length > _backupMaximumAudioIndexBytes ||
          layout.trackPaths.length > _backupMaxEntries ||
          layout.audioFiles.length + layout.playlists.length + 3 >
              _backupMaxEntries) {
        throw const FormatException(
          'El índice de audio excede el límite permitido.',
        );
      }
      if ([
        ...layout.audioFiles.map((file) => file.archivePath),
        ...layout.playlists.map((file) => file.archivePath),
      ].any((path) => !_isPortableIndexedAudioPath(path))) {
        throw const FormatException(
          'El respaldo contiene un nombre de audio no portable.',
        );
      }
    }
    final encoder = ZipFileEncoder();
    encoder.create(destinationPath, level: ZipFileEncoder.gzip);
    var closed = false;
    try {
      encoder.addArchiveFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'app': AppConstants.appName,
            'schema': indexed ? 2 : 1,
            'database': AppConstants.databaseName,
            'exportedAt': DateTime.now().toIso8601String(),
            if (indexed) 'audioIndex': 'audio-index.json',
          }),
        ),
      );
      if (audioIndex != null) {
        encoder.addArchiveFile(
          ArchiveFile.string('audio-index.json', audioIndex),
        );
      }
      if (await databaseSnapshot.exists()) {
        await encoder.addFile(
          databaseSnapshot,
          'database/${AppConstants.databaseName}',
          ZipFileEncoder.gzip,
        );
      }
      for (final file in layout.audioFiles) {
        await encoder.addFile(
          File(file.sourcePath),
          file.archivePath,
          ZipFileEncoder.store,
        );
      }
      for (final file in layout.playlists) {
        encoder.addArchiveFile(
          ArchiveFile.string(file.archivePath, file.contents),
        );
      }
      for (final folder in const ['thumbnails']) {
        final directory = Directory(p.join(snapshotPath, folder));
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
  }
}

String? _safeBackupEntryName(String name) {
  final normalized = name.replaceAll(r'\', '/').trim();
  if (normalized == 'manifest.json' || normalized == 'audio-index.json') {
    return normalized;
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
