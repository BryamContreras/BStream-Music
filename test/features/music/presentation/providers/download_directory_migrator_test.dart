import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('DownloadDirectoryMigrator', () {
    late Directory sandbox;
    const migrator = DownloadDirectoryMigrator(
      hashVerificationThresholdBytes: 1024,
    );

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp(
        'bstream-directory-migrator-',
      );
    });

    tearDown(() async {
      if (await sandbox.exists()) {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'rejects relative, root and nested paths in either direction',
      () async {
        expect(
          () => DownloadDirectoryMigrator.normalizeAbsoluteRoot('relative'),
          throwsArgumentError,
        );
        expect(
          () => DownloadDirectoryMigrator.normalizeAbsoluteRoot(
            p.rootPrefix(sandbox.path),
          ),
          throwsArgumentError,
        );

        final source = Directory(p.join(sandbox.path, 'source'));
        await source.create();
        await expectLater(
          migrator.validatePaths(
            sourceRoot: source.path,
            targetRoot: p.join(source.path, 'nested'),
          ),
          throwsArgumentError,
        );

        final nestedSource = Directory(
          p.join(sandbox.path, 'parent', 'source'),
        );
        await nestedSource.create(recursive: true);
        await expectLater(
          migrator.validatePaths(
            sourceRoot: nestedSource.path,
            targetRoot: nestedSource.parent.path,
          ),
          throwsArgumentError,
        );
      },
    );

    test('migration journal round-trips only safe absolute roots', () {
      final source = p.join(sandbox.path, 'source');
      final target = p.join(sandbox.path, 'target');
      final simulatedJunctionAlias = p.join(sandbox.path, 'source-alias');
      final decoded = DownloadDirectoryMigrationJournal.tryDecode(
        DownloadDirectoryMigrationJournal(
          sourceRoot: source,
          targetRoot: target,
          referenceSourceRoot: simulatedJunctionAlias,
        ).encode(),
      );

      expect(decoded, isNotNull);
      expect(decoded!.sourceRoot, p.normalize(Directory(source).absolute.path));
      expect(decoded.targetRoot, p.normalize(Directory(target).absolute.path));
      expect(
        decoded.referenceSourceRoot,
        p.normalize(Directory(simulatedJunctionAlias).absolute.path),
      );
      final legacyDecoded = DownloadDirectoryMigrationJournal.tryDecode(
        jsonEncode(<String, Object?>{
          'version': 1,
          'sourceRoot': source,
          'targetRoot': target,
        }),
      );
      expect(legacyDecoded, isNotNull);
      expect(legacyDecoded!.referenceSourceRoot, legacyDecoded.sourceRoot);
      expect(DownloadDirectoryMigrationJournal.tryDecode('{not-json'), isNull);
      expect(
        DownloadDirectoryMigrationJournal.tryDecode(
          jsonEncode(<String, Object?>{
            'version': 1,
            'sourceRoot': 'relative',
            'targetRoot': target,
          }),
        ),
        isNull,
      );
      expect(
        DownloadDirectoryMigrationJournal.tryDecode(
          jsonEncode(<String, Object?>{
            'version': 1,
            'sourceRoot': source,
            'targetRoot': p.join(source, 'nested'),
          }),
        ),
        isNull,
      );
    });

    test('reference roots cannot target an unrelated directory', () async {
      final source = Directory(p.join(sandbox.path, 'source'));
      final unrelated = Directory(p.join(sandbox.path, 'unrelated'));
      await source.create();
      await unrelated.create();

      expect(
        await migrator.validateReferenceSourceRoot(
          referenceSourceRoot: source.path,
          canonicalSourceRoot: source.path,
        ),
        p.normalize(source.absolute.path),
      );
      await expectLater(
        migrator.validateReferenceSourceRoot(
          referenceSourceRoot: unrelated.path,
          canonicalSourceRoot: source.path,
        ),
        throwsArgumentError,
      );
    });

    test(
      'safely swaps an existing target and preserves unrelated files',
      () async {
        final source = Directory(p.join(sandbox.path, 'source'));
        final target = Directory(p.join(sandbox.path, 'target'));
        await _write(p.join(source.path, 'audio', 'song.m4a'), 'source-audio');
        await _write(
          p.join(source.path, 'thumbnails', 'song.jpg'),
          'source-thumbnail',
        );
        await _write(p.join(source.path, 'keep.txt'), 'source-unmanaged');
        await _write(p.join(target.path, 'audio', 'existing.m4a'), 'existing');
        await _write(p.join(target.path, 'notes.txt'), 'target-unmanaged');

        var committed = false;
        var rolledBack = false;
        final result = await migrator.migrate(
          sourceRoot: source.path,
          targetRoot: target.path,
          commitReferences: (paths) async {
            committed = true;
            expect(
              await File(
                p.join(paths.targetRoot, 'audio', 'song.m4a'),
              ).readAsString(),
              'source-audio',
            );
            expect(
              await File(p.join(source.path, 'audio', 'song.m4a')).exists(),
              isTrue,
              reason: 'the source must survive until references commit',
            );
          },
          rollbackReferences: (_) async {
            rolledBack = true;
          },
        );

        expect(committed, isTrue);
        expect(rolledBack, isFalse);
        expect(result.targetRoot, p.normalize(target.absolute.path));
        expect(
          await File(
            p.join(target.path, 'audio', 'existing.m4a'),
          ).readAsString(),
          'existing',
        );
        expect(
          await File(
            p.join(target.path, 'thumbnails', 'song.jpg'),
          ).readAsString(),
          'source-thumbnail',
        );
        expect(
          await File(p.join(target.path, 'notes.txt')).readAsString(),
          'target-unmanaged',
        );
        expect(await Directory(p.join(source.path, 'audio')).exists(), isFalse);
        expect(
          await Directory(p.join(source.path, 'thumbnails')).exists(),
          isFalse,
        );
        expect(
          await File(p.join(source.path, 'keep.txt')).readAsString(),
          'source-unmanaged',
        );
        expect(await _migrationArtifacts(sandbox), isEmpty);
      },
    );

    test(
      'detects same-size content collisions by hash before activation',
      () async {
        final source = Directory(p.join(sandbox.path, 'source'));
        final target = Directory(p.join(sandbox.path, 'target'));
        final sourceFile = await _write(
          p.join(source.path, 'audio', 'collision.m4a'),
          List<String>.filled(2048, 'A').join(),
        );
        final targetFile = await _write(
          p.join(target.path, 'audio', 'collision.m4a'),
          List<String>.filled(2048, 'B').join(),
        );
        var committed = false;
        var rolledBack = false;

        await expectLater(
          migrator.migrate(
            sourceRoot: source.path,
            targetRoot: target.path,
            commitReferences: (_) async {
              committed = true;
            },
            rollbackReferences: (_) async {
              rolledBack = true;
            },
          ),
          throwsStateError,
        );

        expect(committed, isFalse);
        expect(rolledBack, isFalse);
        expect(
          await sourceFile.readAsString(),
          List<String>.filled(2048, 'A').join(),
        );
        expect(
          await targetFile.readAsString(),
          List<String>.filled(2048, 'B').join(),
        );
        expect(await _migrationArtifacts(sandbox), isEmpty);
      },
    );

    test('resumes idempotently from already activated managed files', () async {
      final source = Directory(p.join(sandbox.path, 'source'));
      final target = Directory(p.join(sandbox.path, 'target'));
      final sourceFile = await _write(
        p.join(source.path, 'audio', 'already-copied.m4a'),
        'verified-copy',
      );
      final targetFile = await _write(
        p.join(target.path, 'audio', 'already-copied.m4a'),
        'verified-copy',
      );
      final originalModified = DateTime.utc(2020, 1, 2, 3, 4, 5);
      await targetFile.setLastModified(originalModified);
      await _write(
        p.join(target.path, 'outside-managed.txt'),
        'must remain untouched',
      );

      await migrator.migrate(
        sourceRoot: source.path,
        targetRoot: target.path,
        commitReferences: (_) async {},
        rollbackReferences: (_) async {},
      );

      expect(await sourceFile.exists(), isFalse);
      expect(await targetFile.readAsString(), 'verified-copy');
      expect((await targetFile.lastModified()).toUtc(), originalModified);
      expect(
        await File(p.join(target.path, 'outside-managed.txt')).readAsString(),
        'must remain untouched',
      );
      expect(await _migrationArtifacts(target), isEmpty);
    });

    test(
      'leaves source media changed after reference commit untouched',
      () async {
        final source = Directory(p.join(sandbox.path, 'source'));
        final target = Directory(p.join(sandbox.path, 'target'));
        final sourceFile = await _write(
          p.join(source.path, 'audio', 'changed.m4a'),
          'verified-before-commit',
        );

        await migrator.migrate(
          sourceRoot: source.path,
          targetRoot: target.path,
          commitReferences: (_) async {
            await sourceFile.writeAsString('changed-after-commit', flush: true);
          },
          rollbackReferences: (_) async {},
        );

        expect(await sourceFile.readAsString(), 'changed-after-commit');
        expect(
          await File(
            p.join(target.path, 'audio', 'changed.m4a'),
          ).readAsString(),
          'verified-before-commit',
        );
      },
    );

    test('stale cleanup ignores unowned root content', () async {
      final target = Directory(p.join(sandbox.path, 'target'));
      await target.create();
      final unowned = Directory(
        p.join(target.path, '.bstream-migration-stage-personal'),
      );
      await unowned.create();
      await _write(p.join(unowned.path, 'keep.txt'), 'external');
      const token = 'owned-token';
      final owned = Directory(
        p.join(target.path, '.bstream-migration-stage-$token'),
      );
      await owned.create();
      await _write(
        p.join(owned.path, '.bstream-owned-migration.json'),
        jsonEncode(<String, Object?>{
          'version': 1,
          'kind': 'bstream.download-directory-migration',
          'token': token,
          'sourceRoot': p.join(sandbox.path, 'source'),
          'targetRoot': target.path,
        }),
      );

      await migrator.cleanupStaleArtifacts(target.path);

      expect(await unowned.exists(), isTrue);
      expect(
        await File(p.join(unowned.path, 'keep.txt')).readAsString(),
        'external',
      );
      expect(await owned.exists(), isFalse);
    });

    test('restores the original target when reference commit fails', () async {
      final source = Directory(p.join(sandbox.path, 'source'));
      final target = Directory(p.join(sandbox.path, 'target'));
      await _write(p.join(source.path, 'audio', 'new.m4a'), 'new');
      await _write(p.join(target.path, 'audio', 'old.m4a'), 'old');
      await _write(p.join(target.path, 'keep.txt'), 'keep');
      var rollbackCalls = 0;

      await expectLater(
        migrator.migrate(
          sourceRoot: source.path,
          targetRoot: target.path,
          commitReferences: (_) async {
            throw StateError('reference update failed');
          },
          rollbackReferences: (_) async {
            rollbackCalls += 1;
          },
        ),
        throwsStateError,
      );

      expect(rollbackCalls, 1);
      expect(
        await File(p.join(source.path, 'audio', 'new.m4a')).readAsString(),
        'new',
      );
      expect(
        await File(p.join(target.path, 'audio', 'old.m4a')).readAsString(),
        'old',
      );
      expect(
        await File(p.join(target.path, 'keep.txt')).readAsString(),
        'keep',
      );
      expect(
        await File(p.join(target.path, 'audio', 'new.m4a')).exists(),
        isFalse,
      );
      expect(await _migrationArtifacts(sandbox), isEmpty);
    });
  });
}

Future<File> _write(String path, String contents) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  return file.writeAsString(contents, flush: true);
}

Future<List<String>> _migrationArtifacts(Directory parent) async {
  return <String>[
    await for (final entity in parent.list())
      if (p.basename(entity.path).contains('.bstream-')) entity.path,
  ];
}
