import 'dart:io';

import 'package:bstream_music/core/constants/app_constants.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory sandbox;
  late String databasePath;
  late _TestLocalDatabaseService service;

  setUp(() async {
    sqfliteFfiInit();
    sandbox = await Directory.systemTemp.createTemp(
      'bstream-backup-validation-',
    );
    databasePath = p.join(sandbox.path, AppConstants.databaseName);
    service = _TestLocalDatabaseService(databasePath);
  });

  tearDown(() async {
    await service.close();
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  test('accepts an intact supported BStream database', () async {
    await service.initialize();
    await service.close();

    await expectLater(service.validateBackupDatabase(databasePath), completes);
  });

  test('rejects corrupt and newer unsupported databases', () async {
    final corruptPath = p.join(sandbox.path, 'corrupt.db');
    await File(corruptPath).writeAsString('not sqlite');
    await expectLater(
      service.validateBackupDatabase(corruptPath),
      throwsFormatException,
    );

    await service.initialize();
    await service.close();
    final database = await databaseFactoryFfi.openDatabase(databasePath);
    await database.execute(
      'PRAGMA user_version = ${AppConstants.databaseVersion + 1}',
    );
    await database.close();

    await expectLater(
      service.validateBackupDatabase(databasePath),
      throwsFormatException,
    );
  });

  test(
    'accepts an early v8 backup without conflict messages and repairs it',
    () async {
      await service.initialize();
      await service.close();
      final legacy = await databaseFactoryFfi.openDatabase(databasePath);
      await legacy.execute(
        'ALTER TABLE playlist_sync_conflicts DROP COLUMN message',
      );
      await legacy.close();

      await expectLater(
        service.validateBackupDatabase(databasePath),
        completes,
      );

      await service.initialize();
      final columns = (await (await service.database).rawQuery(
        'PRAGMA table_info(playlist_sync_conflicts)',
      )).map((row) => row['name']).toSet();
      expect(columns, contains('message'));
    },
  );
}

class _TestLocalDatabaseService extends LocalDatabaseService {
  _TestLocalDatabaseService(this.path);

  final String path;

  @override
  Future<String> databasePath() async => path;
}
