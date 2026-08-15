import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/services/storage/backup_service.dart';
import 'package:bstream_music/services/storage/library_operation_coordinator.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory sandbox;
  late Directory mediaRoot;
  late File databaseFile;
  late _FakeDatabaseService databaseService;
  late LibraryOperationCoordinator coordinator;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sandbox = await Directory.systemTemp.createTemp('bstream_backup_test_');
    mediaRoot = Directory(p.join(sandbox.path, 'media'));
    databaseFile = File(p.join(sandbox.path, AppConstants.databaseName));
    await databaseFile.writeAsString('database-v1');
    databaseService = _FakeDatabaseService(databaseFile.path);
    coordinator = LibraryOperationCoordinator();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return switch (call.method) {
            'getTemporaryDirectory' => p.join(sandbox.path, 'temp'),
            'getApplicationSupportDirectory' => p.join(sandbox.path, 'support'),
            _ => null,
          };
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    await coordinator.dispose();
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('exports database and media files into a backup zip', () async {
    await File(
      p.join(mediaRoot.path, 'audio', 'song.mp3'),
    ).create(recursive: true);
    await File(
      p.join(mediaRoot.path, 'audio', 'song.mp3'),
    ).writeAsString('audio-bytes');
    await File(
      p.join(mediaRoot.path, 'thumbnails', 'song.jpg'),
    ).create(recursive: true);
    await File(
      p.join(mediaRoot.path, 'thumbnails', 'song.jpg'),
    ).writeAsString('thumbnail-bytes');

    final backup = await BackupService(databaseService, coordinator)
        .createBackupFile(
          mediaRoot: mediaRoot.path,
          outputPath: p.join(sandbox.path, 'backup.zip'),
        );
    final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());

    expect(archive.find('manifest.json'), isNotNull);
    expect(archive.find('database/${AppConstants.databaseName}'), isNotNull);
    expect(archive.find('audio/song.mp3'), isNotNull);
    expect(archive.find('thumbnails/song.jpg'), isNotNull);
    expect(databaseService.closeCalls, 1);
    expect(databaseService.initializeCalls, 1);
  });

  test('restore replaces media and ignores unsafe archive paths', () async {
    final archive = Archive()
      ..add(
        ArchiveFile.bytes(
          'database/${AppConstants.databaseName}',
          'database-v2'.codeUnits,
        ),
      )
      ..add(ArchiveFile.bytes('audio/song.mp3', 'new-audio'.codeUnits))
      ..add(ArchiveFile.bytes('audio/../escape.mp3', 'bad'.codeUnits))
      ..add(ArchiveFile.bytes('/audio/rooted.mp3', 'bad'.codeUnits))
      ..add(
        ArchiveFile.bytes('thumbnails/song.jpg', 'new-thumbnail'.codeUnits),
      );

    await File(
      p.join(mediaRoot.path, 'audio', 'old.mp3'),
    ).create(recursive: true);
    await File(p.join(mediaRoot.path, 'audio', 'old.mp3')).writeAsString('old');

    final backup = File(p.join(sandbox.path, 'restore.zip'));
    await backup.writeAsBytes(ZipEncoder().encodeBytes(archive));
    await BackupService(
      databaseService,
      coordinator,
    ).restoreBackupFile(backupPath: backup.path, mediaRoot: mediaRoot.path);

    expect(await databaseFile.readAsString(), 'database-v2');
    expect(
      await File(p.join(mediaRoot.path, 'audio', 'song.mp3')).readAsString(),
      'new-audio',
    );
    expect(
      await File(
        p.join(mediaRoot.path, 'thumbnails', 'song.jpg'),
      ).readAsString(),
      'new-thumbnail',
    );
    expect(
      File(p.join(mediaRoot.path, 'audio', 'old.mp3')).existsSync(),
      isFalse,
    );
    expect(File(p.join(mediaRoot.path, 'escape.mp3')).existsSync(), isFalse);
    expect(databaseService.closeCalls, 1);
    expect(databaseService.initializeCalls, 1);
    expect(databaseService.rewriteMediaRootCalls, 1);
    expect(databaseService.rewriteMediaRoot, mediaRoot.path);
  });

  test('restore validates the database before touching active data', () async {
    await File(
      p.join(mediaRoot.path, 'audio', 'old.mp3'),
    ).create(recursive: true);
    await File(p.join(mediaRoot.path, 'audio', 'old.mp3')).writeAsString('old');
    databaseService.validationError = const FormatException('corrupt backup');

    final backup = await _writeRestoreArchive(
      sandbox: sandbox,
      databaseContents: 'corrupt-database',
      audioContents: 'new-audio',
    );

    await expectLater(
      BackupService(
        databaseService,
        coordinator,
      ).restoreBackupFile(backupPath: backup.path, mediaRoot: mediaRoot.path),
      throwsFormatException,
    );

    expect(await databaseFile.readAsString(), 'database-v1');
    expect(
      await File(p.join(mediaRoot.path, 'audio', 'old.mp3')).readAsString(),
      'old',
    );
    expect(databaseService.validationCalls, 1);
    expect(databaseService.closeCalls, 0);
    expect(databaseService.initializeCalls, 0);
  });

  test('restore rejects an incompatible manifest before validation', () async {
    final archive = Archive()
      ..add(
        ArchiveFile.string(
          'manifest.json',
          '{"app":"Another app","schema":1,'
              '"database":"${AppConstants.databaseName}"}',
        ),
      )
      ..add(
        ArchiveFile.bytes(
          'database/${AppConstants.databaseName}',
          'database-v2'.codeUnits,
        ),
      );
    final backup = File(p.join(sandbox.path, 'invalid-manifest.zip'));
    await backup.writeAsBytes(ZipEncoder().encodeBytes(archive));

    await expectLater(
      BackupService(
        databaseService,
        coordinator,
      ).restoreBackupFile(backupPath: backup.path, mediaRoot: mediaRoot.path),
      throwsFormatException,
    );

    expect(await databaseFile.readAsString(), 'database-v1');
    expect(databaseService.validationCalls, 0);
    expect(databaseService.closeCalls, 0);
  });

  test('restore rolls back database and media when activation fails', () async {
    await File(
      p.join(mediaRoot.path, 'audio', 'old.mp3'),
    ).create(recursive: true);
    await File(p.join(mediaRoot.path, 'audio', 'old.mp3')).writeAsString('old');
    await File(
      p.join(mediaRoot.path, 'thumbnails', 'old.jpg'),
    ).create(recursive: true);
    await File(
      p.join(mediaRoot.path, 'thumbnails', 'old.jpg'),
    ).writeAsString('old-thumbnail');
    for (final suffix in const ['-wal', '-shm']) {
      await File('${databaseFile.path}$suffix').writeAsString('old$suffix');
    }
    databaseService.failNextInitialize = true;
    databaseService.createSidecarsOnFailedInitialize = true;

    final backup = await _writeRestoreArchive(
      sandbox: sandbox,
      databaseContents: 'database-v2',
      audioContents: 'new-audio',
    );

    await expectLater(
      BackupService(
        databaseService,
        coordinator,
      ).restoreBackupFile(backupPath: backup.path, mediaRoot: mediaRoot.path),
      throwsA(isA<StateError>()),
    );

    expect(await databaseFile.readAsString(), 'database-v1');
    expect(
      await File(p.join(mediaRoot.path, 'audio', 'old.mp3')).readAsString(),
      'old',
    );
    expect(
      await File(
        p.join(mediaRoot.path, 'thumbnails', 'old.jpg'),
      ).readAsString(),
      'old-thumbnail',
    );
    expect(
      File(p.join(mediaRoot.path, 'audio', 'song.mp3')).existsSync(),
      isFalse,
    );
    for (final suffix in const ['-wal', '-shm']) {
      expect(
        await File('${databaseFile.path}$suffix').readAsString(),
        'old$suffix',
      );
    }
    expect(databaseService.closeCalls, 2);
    expect(databaseService.initializeCalls, 2);
    expect(databaseService.rewriteMediaRootCalls, 0);
  });
}

Future<File> _writeRestoreArchive({
  required Directory sandbox,
  required String databaseContents,
  required String audioContents,
}) async {
  final archive = Archive()
    ..add(
      ArchiveFile.bytes(
        'database/${AppConstants.databaseName}',
        databaseContents.codeUnits,
      ),
    )
    ..add(ArchiveFile.bytes('audio/song.mp3', audioContents.codeUnits));
  final backup = File(
    p.join(
      sandbox.path,
      'restore-${DateTime.now().microsecondsSinceEpoch}.zip',
    ),
  );
  await backup.writeAsBytes(ZipEncoder().encodeBytes(archive));
  return backup;
}

class _FakeDatabaseService extends LocalDatabaseService {
  _FakeDatabaseService(this.path);

  final String path;
  int closeCalls = 0;
  int initializeCalls = 0;
  int validationCalls = 0;
  int rewriteMediaRootCalls = 0;
  String? rewriteMediaRoot;
  Object? validationError;
  bool failNextInitialize = false;
  bool createSidecarsOnFailedInitialize = false;

  @override
  Future<String> databasePath() async => path;

  @override
  Future<T> withDatabase<T>(Future<T> Function(Database) operation) async {
    // No-op in tests: the fake database file is not a real SQLite database.
    throw StateError('withDatabase is not supported in fake database service');
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (failNextInitialize) {
      failNextInitialize = false;
      if (createSidecarsOnFailedInitialize) {
        for (final suffix in const ['-wal', '-shm']) {
          await File('$path$suffix').writeAsString('new$suffix');
        }
      }
      throw StateError('activation failed');
    }
  }

  @override
  Future<void> validateBackupDatabase(String path) async {
    validationCalls++;
    final error = validationError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> rewriteLocalTrackMediaRoot({
    required String mediaRoot,
    String? oldMediaRoot,
  }) async {
    rewriteMediaRootCalls++;
    rewriteMediaRoot = mediaRoot;
  }
}
