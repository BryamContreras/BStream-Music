import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/services/storage/backup_service.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory sandbox;
  late Directory mediaRoot;
  late File databaseFile;
  late _FakeDatabaseService databaseService;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sandbox = await Directory.systemTemp.createTemp('bstream_backup_test_');
    mediaRoot = Directory(p.join(sandbox.path, 'media'));
    databaseFile = File(p.join(sandbox.path, AppConstants.databaseName));
    await databaseFile.writeAsString('database-v1');
    databaseService = _FakeDatabaseService(databaseFile.path);

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

    final backup = await BackupService(databaseService).createBackupFile(
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
}

class _FakeDatabaseService extends LocalDatabaseService {
  _FakeDatabaseService(this.path);

  final String path;
  int closeCalls = 0;
  int initializeCalls = 0;
  int rewriteMediaRootCalls = 0;
  String? rewriteMediaRoot;

  @override
  Future<String> databasePath() async => path;

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
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
