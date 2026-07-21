import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants/app_constants.dart';
import 'local_database_service.dart';

class BackupService {
  const BackupService(this._databaseService);

  final LocalDatabaseService _databaseService;

  Future<File> createBackupFile({
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

    await _databaseService.close();
    try {
      final databasePath = await _databaseService.databasePath();
      await Isolate.run(
        () => _createBackupArchive(
          outputPath: destination.path,
          databasePath: databasePath,
          mediaRoot: mediaRoot,
        ),
      );
    } finally {
      await _databaseService.initialize();
    }
    return destination;
  }

  Future<void> restoreBackupFile({
    required String backupPath,
    required String mediaRoot,
  }) async {
    final backup = File(backupPath);
    if (!await backup.exists() || await backup.length() == 0) {
      throw const FormatException(
        'El archivo de respaldo no existe o esta vacio.',
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

      await Directory(mediaRoot).create(recursive: true);
      await _databaseService.close();
      try {
        await _replaceDirectory(
          source: Directory(p.join(temporaryRoot.path, 'audio')),
          destination: Directory(p.join(mediaRoot, 'audio')),
        );
        await _replaceDirectory(
          source: Directory(p.join(temporaryRoot.path, 'thumbnails')),
          destination: Directory(p.join(mediaRoot, 'thumbnails')),
        );

        final databasePath = await _databaseService.databasePath();
        final databaseFile = File(databasePath);
        await databaseFile.parent.create(recursive: true);
        await extractedDatabase.copy(databaseFile.path);
      } finally {
        await _databaseService.initialize();
      }
      await _databaseService.rewriteLocalTrackMediaRoot(mediaRoot: mediaRoot);
    } finally {
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    }
  }

  Future<void> _replaceDirectory({
    required Directory source,
    required Directory destination,
  }) async {
    if (await destination.exists()) {
      await destination.delete(recursive: true);
    }
    await destination.create(recursive: true);
    if (!await source.exists()) {
      return;
    }
    await _copyDirectory(source: source, destination: destination);
  }

  Future<void> _copyDirectory({
    required Directory source,
    required Directory destination,
  }) async {
    await for (final entity in source.list(recursive: true)) {
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

Future<void> _createBackupArchive({
  required String outputPath,
  required String databasePath,
  required String mediaRoot,
}) async {
  final encoder = ZipFileEncoder();
  encoder.create(outputPath, level: ZipFileEncoder.gzip);
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

    final databaseFile = File(databasePath);
    if (await databaseFile.exists()) {
      await encoder.addFile(
        databaseFile,
        'database/${AppConstants.databaseName}',
        ZipFileEncoder.gzip,
      );
    }

    for (final folder in const ['audio', 'thumbnails']) {
      final directory = Directory(p.join(mediaRoot, folder));
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
          'El respaldo excede los limites permitidos.',
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

String? _safeBackupEntryName(String name) {
  final normalized = name.replaceAll(r'\', '/').trim();
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
