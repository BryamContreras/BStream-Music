import 'package:sqflite_common_ffi/sqflite_ffi.dart';

typedef PortableSqliteUpdateBuilder =
    Map<String, Object?> Function(Map<String, Object?> currentRow);

/// Inserts a row when [keyValues] is absent, otherwise updates the existing
/// row with values derived from its current state.
///
/// This intentionally uses only the long-supported SELECT, INSERT and UPDATE
/// statements. Callers that can race with another writer must invoke it from
/// an existing database transaction so the read and write remain atomic.
Future<bool> portableSqliteUpsert(
  Transaction db, {
  required String table,
  required Map<String, Object?> keyValues,
  required Map<String, Object?> insertValues,
  required PortableSqliteUpdateBuilder updateValues,
}) async {
  if (keyValues.isEmpty) {
    throw ArgumentError.value(keyValues, 'keyValues', 'Must not be empty.');
  }
  for (final entry in keyValues.entries) {
    if (!insertValues.containsKey(entry.key) ||
        insertValues[entry.key] != entry.value) {
      throw ArgumentError(
        'Insert value for ${entry.key} must match its key value.',
      );
    }
  }

  final where = keyValues.keys.map((column) => '$column = ?').join(' AND ');
  final whereArgs = keyValues.values.toList(growable: false);
  final rows = await db.query(
    table,
    where: where,
    whereArgs: whereArgs,
    limit: 1,
  );
  if (rows.isEmpty) {
    await db.insert(
      table,
      insertValues,
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    return true;
  }

  final updates = updateValues(Map<String, Object?>.from(rows.single));
  if (updates.isNotEmpty) {
    await db.update(table, updates, where: where, whereArgs: whereArgs);
  }
  return false;
}
