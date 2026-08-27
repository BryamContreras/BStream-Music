import 'dart:io';

import 'package:bstream_music/services/storage/portable_sqlite_upsert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'portable upsert preserves untouched columns and reports secondary conflicts',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute('''
        CREATE TABLE records (
          id TEXT PRIMARY KEY,
          remote_id TEXT NOT NULL UNIQUE,
          value TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');

      await db.transaction(
        (transaction) => portableSqliteUpsert(
          transaction,
          table: 'records',
          keyValues: const <String, Object?>{'id': 'one'},
          insertValues: const <String, Object?>{
            'id': 'one',
            'remote_id': 'remote-one',
            'value': 'first',
            'created_at': 'created-first',
          },
          updateValues: (_) => const <String, Object?>{'value': 'first'},
        ),
      );
      await db.transaction(
        (transaction) => portableSqliteUpsert(
          transaction,
          table: 'records',
          keyValues: const <String, Object?>{'id': 'one'},
          insertValues: const <String, Object?>{
            'id': 'one',
            'remote_id': 'remote-one',
            'value': 'second',
            'created_at': 'must-not-replace-created-at',
          },
          updateValues: (_) => const <String, Object?>{'value': 'second'},
        ),
      );

      final updated = (await db.query('records')).single;
      expect(updated['value'], 'second');
      expect(updated['created_at'], 'created-first');

      await expectLater(
        db.transaction(
          (transaction) => portableSqliteUpsert(
            transaction,
            table: 'records',
            keyValues: const <String, Object?>{'id': 'two'},
            insertValues: const <String, Object?>{
              'id': 'two',
              'remote_id': 'remote-one',
              'value': 'conflict',
              'created_at': 'created-second',
            },
            updateValues: (_) => const <String, Object?>{},
          ),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(await db.query('records'), hasLength(1));
    },
  );

  test('production SQL remains compatible with SQLite before 3.24', () {
    final modernUpsert = RegExp(
      r'ON\s+CONFLICT\s*(?:\([^)]*\))?\s+DO\s+(?:UPDATE|NOTHING)',
      caseSensitive: false,
      multiLine: true,
    );
    final dartSources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final source in dartSources) {
      expect(
        modernUpsert.hasMatch(source.readAsStringSync()),
        isFalse,
        reason:
            '${source.path} uses SQLite UPSERT syntax unavailable on older '
            'supported Android releases.',
      );
    }
  });
}
