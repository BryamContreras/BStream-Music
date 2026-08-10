import 'dart:io';

import 'package:path/path.dart' as p;

/// Stages a restore on the same filesystems as the active library and swaps
/// every target with rollback support.
///
/// No active file is touched by [prepare]. After [commit], [rollback] can put
/// the exact previous database and media directories back until [complete]
/// discards the rollback copies.
class BackupRestoreTransaction {
  BackupRestoreTransaction._({
    required this._transactionRoot,
    required this._swaps,
  });

  final Directory _transactionRoot;
  final List<_RestoreSwap> _swaps;

  static Future<BackupRestoreTransaction> prepare({
    required Directory extractedRoot,
    required Directory mediaRoot,
    required File activeDatabase,
  }) async {
    final token = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final transactionRoot = Directory(
      p.join(mediaRoot.parent.path, '.bstream-restore-$token'),
    );
    final stagedAudio = Directory(p.join(transactionRoot.path, 'audio'));
    final stagedThumbnails = Directory(
      p.join(transactionRoot.path, 'thumbnails'),
    );
    final stagedDatabase = File(
      p.join(
        activeDatabase.parent.path,
        '.${p.basename(activeDatabase.path)}.restore-$token',
      ),
    );
    final databaseRollback = File('${activeDatabase.path}.rollback-$token');

    final transaction = BackupRestoreTransaction._(
      transactionRoot: transactionRoot,
      swaps: [
        _DirectoryRestoreSwap(
          staged: stagedAudio,
          target: Directory(p.join(mediaRoot.path, 'audio')),
          rollback: Directory(p.join(transactionRoot.path, 'rollback-audio')),
        ),
        _DirectoryRestoreSwap(
          staged: stagedThumbnails,
          target: Directory(p.join(mediaRoot.path, 'thumbnails')),
          rollback: Directory(
            p.join(transactionRoot.path, 'rollback-thumbnails'),
          ),
        ),
        for (final suffix in const ['-wal', '-shm', '-journal'])
          _FileRestoreSwap(
            target: File('${activeDatabase.path}$suffix'),
            rollback: File('${databaseRollback.path}$suffix'),
          ),
        _FileRestoreSwap(
          staged: stagedDatabase,
          target: activeDatabase,
          rollback: databaseRollback,
        ),
      ],
    );

    try {
      await transactionRoot.create(recursive: true);
      await activeDatabase.parent.create(recursive: true);
      await _copyDirectory(
        source: Directory(p.join(extractedRoot.path, 'audio')),
        destination: stagedAudio,
      );
      await _copyDirectory(
        source: Directory(p.join(extractedRoot.path, 'thumbnails')),
        destination: stagedThumbnails,
      );
      await File(
        p.join(extractedRoot.path, 'database', p.basename(activeDatabase.path)),
      ).copy(stagedDatabase.path);
      return transaction;
    } catch (_) {
      await transaction._discardAll();
      rethrow;
    }
  }

  Future<void> commit() async {
    for (final swap in _swaps) {
      await swap.commit();
    }
  }

  Future<void> rollback() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final swap in _swaps.reversed) {
      try {
        await swap.rollbackSwap();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    for (final swap in _swaps) {
      try {
        await swap.discardStaged();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
    await _deleteDirectoryIfExists(_transactionRoot);
  }

  Future<void> complete() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final swap in _swaps) {
      try {
        await swap.discardRollback();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    try {
      await _deleteDirectoryIfExists(_transactionRoot);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _discardAll() async {
    for (final swap in _swaps) {
      await swap.discardStaged();
      await swap.discardRollback();
    }
    await _deleteDirectoryIfExists(_transactionRoot);
  }
}

abstract class _RestoreSwap {
  Future<void> commit();
  Future<void> rollbackSwap();
  Future<void> discardStaged();
  Future<void> discardRollback();
}

class _DirectoryRestoreSwap implements _RestoreSwap {
  _DirectoryRestoreSwap({
    required this.staged,
    required this.target,
    required this.rollback,
  });

  final Directory staged;
  final Directory target;
  final Directory rollback;
  bool _previousMoved = false;
  bool _stagedMoved = false;

  @override
  Future<void> commit() async {
    if (await target.exists()) {
      await _deleteDirectoryIfExists(rollback);
      await target.rename(rollback.path);
      _previousMoved = true;
    }
    await target.parent.create(recursive: true);
    await staged.rename(target.path);
    _stagedMoved = true;
  }

  @override
  Future<void> rollbackSwap() async {
    if (_stagedMoved) {
      await _deleteDirectoryIfExists(target);
      _stagedMoved = false;
    }
    if (_previousMoved && await rollback.exists()) {
      await rollback.rename(target.path);
      _previousMoved = false;
    }
  }

  @override
  Future<void> discardStaged() => _deleteDirectoryIfExists(staged);

  @override
  Future<void> discardRollback() => _deleteDirectoryIfExists(rollback);
}

class _FileRestoreSwap implements _RestoreSwap {
  _FileRestoreSwap({this.staged, required this.target, required this.rollback});

  final File? staged;
  final File target;
  final File rollback;
  bool _previousMoved = false;
  bool _targetPrepared = false;

  @override
  Future<void> commit() async {
    if (await target.exists()) {
      await _deleteFileIfExists(rollback);
      await target.rename(rollback.path);
      _previousMoved = true;
    }
    _targetPrepared = true;
    final stagedFile = staged;
    if (stagedFile != null) {
      await target.parent.create(recursive: true);
      await stagedFile.rename(target.path);
    }
  }

  @override
  Future<void> rollbackSwap() async {
    // SQLite can create fresh WAL/SHM/journal files while the restored
    // database is being activated. Remove any current target even for swaps
    // without a staged replacement, then put the original sidecar back.
    if (_targetPrepared) {
      await _deleteFileIfExists(target);
      _targetPrepared = false;
    }
    if (_previousMoved && await rollback.exists()) {
      await rollback.rename(target.path);
      _previousMoved = false;
    }
  }

  @override
  Future<void> discardStaged() async {
    final stagedFile = staged;
    if (stagedFile != null) {
      await _deleteFileIfExists(stagedFile);
    }
  }

  @override
  Future<void> discardRollback() => _deleteFileIfExists(rollback);
}

Future<void> _copyDirectory({
  required Directory source,
  required Directory destination,
}) async {
  await destination.create(recursive: true);
  if (!await source.exists()) {
    return;
  }
  await for (final entity in source.list(recursive: true, followLinks: false)) {
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

Future<void> _deleteDirectoryIfExists(Directory directory) async {
  if (await directory.exists()) {
    await directory.delete(recursive: true);
  }
}

Future<void> _deleteFileIfExists(File file) async {
  if (await file.exists()) {
    await file.delete();
  }
}
