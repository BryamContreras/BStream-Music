part of 'music_providers.dart';

typedef DownloadDirectoryReferenceUpdate =
    Future<void> Function(DownloadDirectoryMigrationPaths paths);

class DownloadDirectoryMigrationPaths {
  const DownloadDirectoryMigrationPaths({
    required this.sourceRoot,
    required this.targetRoot,
  });

  final String sourceRoot;
  final String targetRoot;
}

class DownloadDirectoryMigrationJournal {
  const DownloadDirectoryMigrationJournal({
    required this.sourceRoot,
    required this.targetRoot,
    String? referenceSourceRoot,
  }) : referenceSourceRoot = referenceSourceRoot ?? sourceRoot;

  final String sourceRoot;
  final String targetRoot;
  final String referenceSourceRoot;

  String encode() => jsonEncode(<String, Object?>{
    'version': 1,
    'sourceRoot': sourceRoot,
    'targetRoot': targetRoot,
    'referenceSourceRoot': referenceSourceRoot,
  });

  static DownloadDirectoryMigrationJournal? tryDecode(String? encoded) {
    if (encoded == null || encoded.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map || decoded['version'] != 1) {
        return null;
      }
      final sourceValue = decoded['sourceRoot'];
      final targetValue = decoded['targetRoot'];
      if (sourceValue is! String || targetValue is! String) {
        return null;
      }
      final referenceValue = decoded['referenceSourceRoot'] ?? sourceValue;
      if (referenceValue is! String) {
        return null;
      }
      final sourceRoot = DownloadDirectoryMigrator.normalizeAbsoluteRoot(
        sourceValue,
        parameterName: 'sourceRoot',
      );
      final targetRoot = DownloadDirectoryMigrator.normalizeAbsoluteRoot(
        targetValue,
        parameterName: 'targetRoot',
      );
      final referenceSourceRoot =
          DownloadDirectoryMigrator.normalizeAbsoluteRoot(
            referenceValue,
            parameterName: 'referenceSourceRoot',
          );
      if (DownloadDirectoryMigrator.rootsEqual(sourceRoot, targetRoot) ||
          DownloadDirectoryMigrator._isWithin(
            child: targetRoot,
            parent: sourceRoot,
          ) ||
          DownloadDirectoryMigrator._isWithin(
            child: sourceRoot,
            parent: targetRoot,
          )) {
        return null;
      }
      return DownloadDirectoryMigrationJournal(
        sourceRoot: sourceRoot,
        targetRoot: targetRoot,
        referenceSourceRoot: referenceSourceRoot,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

class DownloadDirectoryMigrationException implements Exception {
  const DownloadDirectoryMigrationException({
    required this.cause,
    required this.rollbackErrors,
  });

  final Object cause;
  final List<Object> rollbackErrors;

  @override
  String toString() {
    return 'La migración del directorio falló y no pudo revertirse por '
        'completo: $cause (rollback: $rollbackErrors)';
  }
}

/// Copies only BStream-owned media through a verified, same-volume staging tree.
///
/// Existing destination files are never overwritten. Activation is idempotent:
/// a process interruption can leave verified duplicate files in the destination,
/// while the source and its references remain authoritative until commit.
class DownloadDirectoryMigrator {
  const DownloadDirectoryMigrator({
    this.hashVerificationThresholdBytes = 32 * 1024 * 1024,
  }) : assert(hashVerificationThresholdBytes >= 0);

  static const _managedDirectories = <String>['audio', 'thumbnails'];
  static const _stagingPrefix = '.bstream-migration-stage-';
  static const _stagingMarkerName = '.bstream-owned-migration.json';

  // Kept for source compatibility. Every file is now hashed regardless of
  // this legacy threshold.
  final int hashVerificationThresholdBytes;

  static String normalizeAbsoluteRoot(
    String value, {
    String parameterName = 'path',
  }) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !p.isAbsolute(trimmed)) {
      throw ArgumentError.value(
        value,
        parameterName,
        'Debe ser una ruta absoluta no vacía.',
      );
    }
    final normalized = p.normalize(Directory(trimmed).absolute.path);
    if (_comparisonKey(p.dirname(normalized)) == _comparisonKey(normalized)) {
      throw ArgumentError.value(
        value,
        parameterName,
        'La raíz del sistema de archivos no es un destino permitido.',
      );
    }
    return normalized;
  }

  static bool rootsEqual(String left, String right) {
    try {
      return _comparisonKey(normalizeAbsoluteRoot(left)) ==
          _comparisonKey(normalizeAbsoluteRoot(right));
    } on ArgumentError {
      return false;
    }
  }

  Future<bool> hasManagedContent(String rootPath) async {
    final root = normalizeAbsoluteRoot(rootPath);
    for (final name in _managedDirectories) {
      final directory = Directory(p.join(root, name));
      if (!await directory.exists()) {
        continue;
      }
      await for (final _ in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        return true;
      }
    }
    return false;
  }

  Future<DownloadDirectoryMigrationPaths> validatePaths({
    required String sourceRoot,
    required String targetRoot,
  }) async {
    final source = await _canonicalRoot(
      sourceRoot,
      parameterName: 'sourceRoot',
    );
    final target = await _canonicalRoot(
      targetRoot,
      parameterName: 'targetRoot',
    );
    if (_samePath(source, target)) {
      throw ArgumentError.value(
        targetRoot,
        'targetRoot',
        'El origen y el destino deben ser directorios diferentes.',
      );
    }
    if (_isWithin(child: target, parent: source) ||
        _isWithin(child: source, parent: target)) {
      throw ArgumentError.value(
        targetRoot,
        'targetRoot',
        'El origen y el destino no pueden estar anidados.',
      );
    }
    return DownloadDirectoryMigrationPaths(
      sourceRoot: source,
      targetRoot: target,
    );
  }

  /// Preserves the lexical root stored in database rows while proving it
  /// resolves to the canonical migration source. This covers junction or
  /// symlink ancestors without allowing a corrupted journal to rewrite paths
  /// from an unrelated directory.
  Future<String> validateReferenceSourceRoot({
    required String referenceSourceRoot,
    required String canonicalSourceRoot,
  }) async {
    final reference = normalizeAbsoluteRoot(
      referenceSourceRoot,
      parameterName: 'referenceSourceRoot',
    );
    final resolvedReference = await _canonicalRoot(
      reference,
      parameterName: 'referenceSourceRoot',
    );
    final source = await _canonicalRoot(
      canonicalSourceRoot,
      parameterName: 'canonicalSourceRoot',
    );
    if (!_samePath(resolvedReference, source)) {
      throw ArgumentError.value(
        referenceSourceRoot,
        'referenceSourceRoot',
        'La ruta de referencia no corresponde al origen canónico.',
      );
    }
    return reference;
  }

  Future<DownloadDirectoryMigrationPaths> migrate({
    required String sourceRoot,
    required String targetRoot,
    required DownloadDirectoryReferenceUpdate commitReferences,
    required DownloadDirectoryReferenceUpdate rollbackReferences,
  }) async {
    final paths = await validatePaths(
      sourceRoot: sourceRoot,
      targetRoot: targetRoot,
    );
    final source = Directory(paths.sourceRoot);
    final target = Directory(paths.targetRoot);
    await target.create(recursive: true);
    await cleanupStaleArtifacts(target.path);

    final token =
        '${DateTime.now().microsecondsSinceEpoch}-${const Uuid().v4()}';
    final staging = Directory(p.join(target.path, '$_stagingPrefix$token'));
    await _createOwnedStagingDirectory(
      staging: staging,
      paths: paths,
      token: token,
    );

    final stagedFiles = <_DownloadDirectoryStagedFile>[];
    final activatedFiles = <_DownloadDirectoryActivatedFile>[];
    var commitStarted = false;
    try {
      for (final name in _managedDirectories) {
        final sourceDirectory = Directory(p.join(source.path, name));
        final sourceType = await FileSystemEntity.type(
          sourceDirectory.path,
          followLinks: false,
        );
        if (sourceType == FileSystemEntityType.notFound) {
          continue;
        }
        if (sourceType != FileSystemEntityType.directory) {
          throw StateError(
            'El subdirectorio administrado no es un directorio: '
            '${sourceDirectory.path}',
          );
        }
        final targetDirectory = Directory(p.join(target.path, name));
        await _ensureDirectoryWithoutLinks(
          directory: targetDirectory,
          boundary: target,
        );
        await _stageManagedTree(
          source: sourceDirectory,
          target: targetDirectory,
          staging: Directory(p.join(staging.path, name)),
          stagedFiles: stagedFiles,
        );
      }

      for (final staged in stagedFiles) {
        await _activateStagedFile(staged, activatedFiles: activatedFiles);
      }
      for (final name in _managedDirectories) {
        await _verifyTree(
          source: Directory(p.join(source.path, name)),
          target: Directory(p.join(target.path, name)),
        );
      }

      commitStarted = true;
      await commitReferences(paths);

      await _deleteBestEffort(staging);
      for (final name in _managedDirectories) {
        try {
          await _deleteVerifiedSourceTree(
            source: Directory(p.join(source.path, name)),
            target: Directory(p.join(target.path, name)),
          );
        } catch (_) {
          // References already point at the verified target. Source cleanup is
          // optional and must never roll a committed migration back after a
          // subset of duplicate source files may already have been removed.
        }
      }
      return paths;
    } catch (error, stackTrace) {
      final rollbackErrors = <Object>[];
      if (commitStarted) {
        try {
          await rollbackReferences(paths);
        } catch (rollbackError) {
          rollbackErrors.add(rollbackError);
        }
      }
      try {
        await _removeActivatedDuplicates(activatedFiles);
      } catch (rollbackError) {
        rollbackErrors.add(rollbackError);
      }
      try {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } catch (rollbackError) {
        rollbackErrors.add(rollbackError);
      }
      if (rollbackErrors.isNotEmpty) {
        throw DownloadDirectoryMigrationException(
          cause: error,
          rollbackErrors: List<Object>.unmodifiable(rollbackErrors),
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> cleanupStaleArtifacts(String rootPath) async {
    final root = Directory(normalizeAbsoluteRoot(rootPath));
    if (!await root.exists()) {
      return;
    }
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory &&
          p.basename(entity.path).startsWith(_stagingPrefix) &&
          await _isOwnedStagingDirectory(entity, root)) {
        await _deleteBestEffort(entity);
      }
    }
  }

  Future<void> _createOwnedStagingDirectory({
    required Directory staging,
    required DownloadDirectoryMigrationPaths paths,
    required String token,
  }) async {
    await staging.create();
    await File(p.join(staging.path, _stagingMarkerName)).writeAsString(
      jsonEncode(<String, Object?>{
        'version': 1,
        'kind': 'bstream.download-directory-migration',
        'token': token,
        'sourceRoot': paths.sourceRoot,
        'targetRoot': paths.targetRoot,
      }),
      flush: true,
    );
  }

  Future<bool> _isOwnedStagingDirectory(
    Directory staging,
    Directory targetRoot,
  ) async {
    final marker = File(p.join(staging.path, _stagingMarkerName));
    try {
      final markerType = await FileSystemEntity.type(
        marker.path,
        followLinks: false,
      );
      if (markerType != FileSystemEntityType.file ||
          await marker.length() > 4096) {
        return false;
      }
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['kind'] != 'bstream.download-directory-migration') {
        return false;
      }
      final token = decoded['token'];
      final encodedTarget = decoded['targetRoot'];
      return token is String &&
          token.isNotEmpty &&
          p.basename(staging.path) == '$_stagingPrefix$token' &&
          encodedTarget is String &&
          rootsEqual(encodedTarget, targetRoot.path);
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    } on TypeError {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  Future<String> _canonicalRoot(
    String value, {
    required String parameterName,
  }) async {
    final normalized = normalizeAbsoluteRoot(
      value,
      parameterName: parameterName,
    );
    final rootType = await FileSystemEntity.type(
      normalized,
      followLinks: false,
    );
    if (rootType == FileSystemEntityType.link) {
      throw ArgumentError.value(
        value,
        parameterName,
        'El directorio raíz no puede ser un enlace simbólico.',
      );
    }
    if (rootType != FileSystemEntityType.notFound &&
        rootType != FileSystemEntityType.directory) {
      throw ArgumentError.value(
        value,
        parameterName,
        'La ruta debe apuntar a un directorio.',
      );
    }

    var cursor = normalized;
    final missingSegments = <String>[];
    while (true) {
      final type = await FileSystemEntity.type(cursor, followLinks: false);
      if (type == FileSystemEntityType.directory ||
          type == FileSystemEntityType.link) {
        final resolved = p.normalize(
          await Directory(cursor).resolveSymbolicLinks(),
        );
        final canonical = missingSegments.isEmpty
            ? resolved
            : p.joinAll(<String>[resolved, ...missingSegments.reversed]);
        return normalizeAbsoluteRoot(canonical, parameterName: parameterName);
      }
      if (type != FileSystemEntityType.notFound) {
        throw ArgumentError.value(
          value,
          parameterName,
          'La ruta atraviesa una entidad que no es un directorio.',
        );
      }
      final parent = p.dirname(cursor);
      if (_samePath(parent, cursor)) {
        return normalized;
      }
      missingSegments.add(p.basename(cursor));
      cursor = parent;
    }
  }

  Future<void> _stageManagedTree({
    required Directory source,
    required Directory target,
    required Directory staging,
    required List<_DownloadDirectoryStagedFile> stagedFiles,
  }) async {
    await staging.create(recursive: true);
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw StateError(
          'No se pueden migrar enlaces simbólicos: ${entity.path}',
        );
      }
      final relative = p.relative(entity.path, from: source.path);
      final targetPath = p.join(target.path, relative);
      final stagedPath = p.join(staging.path, relative);
      if (entity is Directory) {
        await _ensureDirectoryWithoutLinks(
          directory: Directory(targetPath),
          boundary: target,
        );
        await Directory(stagedPath).create(recursive: true);
        continue;
      }
      if (entity is! File) {
        throw StateError('Tipo de archivo no compatible: ${entity.path}');
      }

      final targetFile = File(targetPath);
      await _ensureDirectoryWithoutLinks(
        directory: targetFile.parent,
        boundary: target,
      );
      final targetType = await FileSystemEntity.type(
        targetFile.path,
        followLinks: false,
      );
      if (targetType == FileSystemEntityType.file) {
        if (!await _filesMatch(entity, targetFile)) {
          throw StateError(
            'Ya existe un archivo diferente en el destino: $relative',
          );
        }
        continue;
      }
      if (targetType != FileSystemEntityType.notFound) {
        throw StateError('Conflicto de archivo durante la migración.');
      }

      final stagedFile = File(stagedPath);
      await stagedFile.parent.create(recursive: true);
      await entity.copy(stagedFile.path);
      if (!await _filesMatch(entity, stagedFile)) {
        throw StateError('La copia temporal no coincide: $relative');
      }
      stagedFiles.add(
        _DownloadDirectoryStagedFile(
          source: entity,
          staged: stagedFile,
          target: targetFile,
          targetBoundary: target,
        ),
      );
    }
  }

  Future<void> _activateStagedFile(
    _DownloadDirectoryStagedFile staged, {
    required List<_DownloadDirectoryActivatedFile> activatedFiles,
  }) async {
    await _ensureDirectoryWithoutLinks(
      directory: staged.target.parent,
      boundary: staged.targetBoundary,
    );
    final targetType = await FileSystemEntity.type(
      staged.target.path,
      followLinks: false,
    );
    if (targetType == FileSystemEntityType.file) {
      if (!await _filesMatch(staged.source, staged.target)) {
        throw StateError(
          'El destino cambió durante la migración: ${staged.target.path}',
        );
      }
      await staged.staged.delete();
      return;
    }
    if (targetType != FileSystemEntityType.notFound) {
      throw StateError(
        'Conflicto al activar el archivo: ${staged.target.path}',
      );
    }

    await staged.staged.rename(staged.target.path);
    activatedFiles.add(
      _DownloadDirectoryActivatedFile(
        source: staged.source,
        target: staged.target,
      ),
    );
    if (!await _filesMatch(staged.source, staged.target)) {
      throw StateError(
        'El archivo activado no coincide: ${staged.target.path}',
      );
    }
  }

  Future<void> _ensureDirectoryWithoutLinks({
    required Directory directory,
    required Directory boundary,
  }) async {
    final boundaryPath = p.normalize(boundary.absolute.path);
    final directoryPath = p.normalize(directory.absolute.path);
    if (!_samePath(boundaryPath, directoryPath) &&
        !_isWithin(child: directoryPath, parent: boundaryPath)) {
      throw StateError('La migración intentó salir del destino administrado.');
    }

    final boundaryType = await FileSystemEntity.type(
      boundaryPath,
      followLinks: false,
    );
    if (boundaryType != FileSystemEntityType.directory) {
      throw StateError('El destino administrado no es un directorio seguro.');
    }
    if (_samePath(boundaryPath, directoryPath)) {
      return;
    }

    var cursor = boundaryPath;
    final relative = p.relative(directoryPath, from: boundaryPath);
    for (final segment in p.split(relative)) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      cursor = p.join(cursor, segment);
      final type = await FileSystemEntity.type(cursor, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await Directory(cursor).create();
        continue;
      }
      if (type != FileSystemEntityType.directory) {
        throw StateError(
          'La ruta de destino contiene un enlace o archivo: $cursor',
        );
      }
    }
  }

  Future<void> _removeActivatedDuplicates(
    List<_DownloadDirectoryActivatedFile> files,
  ) async {
    for (final activated in files.reversed) {
      final sourceType = await FileSystemEntity.type(
        activated.source.path,
        followLinks: false,
      );
      final targetType = await FileSystemEntity.type(
        activated.target.path,
        followLinks: false,
      );
      if (sourceType != FileSystemEntityType.file ||
          targetType != FileSystemEntityType.file ||
          !await _filesMatch(activated.source, activated.target)) {
        continue;
      }
      await activated.target.delete();
    }
  }

  Future<void> _deleteVerifiedSourceTree({
    required Directory source,
    required Directory target,
  }) async {
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (sourceType != FileSystemEntityType.directory) {
      return;
    }

    final directories = <Directory>[source];
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Directory) {
        directories.add(entity);
        continue;
      }
      if (entity is! File) {
        continue;
      }
      final relative = p.relative(entity.path, from: source.path);
      final targetFile = File(p.join(target.path, relative));
      try {
        if (await FileSystemEntity.type(targetFile.path, followLinks: false) ==
            FileSystemEntityType.file) {
          final sourceBefore = await entity.stat();
          final targetBefore = await targetFile.stat();
          if (await _filesMatch(entity, targetFile)) {
            final sourceAfter = await entity.stat();
            final targetAfter = await targetFile.stat();
            if (_fileStatUnchanged(sourceBefore, sourceAfter) &&
                _fileStatUnchanged(targetBefore, targetAfter)) {
              await entity.delete();
            }
          }
        }
      } on FileSystemException {
        // Reference commit already succeeded. Leave any source whose state
        // cannot be proven instead of risking deletion after a concurrent
        // external write.
      }
    }

    directories.sort(
      (left, right) => right.path.length.compareTo(left.path.length),
    );
    for (final directory in directories) {
      try {
        await directory.delete();
      } on FileSystemException {
        // Non-empty or externally changed directories deliberately remain.
      }
    }
  }

  bool _fileStatUnchanged(FileStat before, FileStat after) {
    return before.type == FileSystemEntityType.file &&
        after.type == FileSystemEntityType.file &&
        before.size == after.size &&
        before.modified == after.modified &&
        before.changed == after.changed;
  }

  Future<void> _verifyTree({
    required Directory source,
    required Directory target,
  }) async {
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) {
      return;
    }
    if (sourceType != FileSystemEntityType.directory) {
      throw StateError('El origen administrado no es un directorio.');
    }
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        throw StateError(
          'No se pueden verificar enlaces simbólicos: ${entity.path}',
        );
      }
      final relative = p.relative(entity.path, from: source.path);
      final destinationPath = p.join(target.path, relative);
      final destinationType = await FileSystemEntity.type(
        destinationPath,
        followLinks: false,
      );
      if (entity is Directory) {
        if (destinationType != FileSystemEntityType.directory) {
          throw StateError(
            'Falta el directorio $relative en la copia verificada.',
          );
        }
        continue;
      }
      if (entity is! File || destinationType != FileSystemEntityType.file) {
        throw StateError('Falta el archivo $relative en la copia verificada.');
      }
      if (!await _filesMatch(entity, File(destinationPath))) {
        throw StateError('El archivo $relative no coincide con el original.');
      }
    }
  }

  Future<bool> _filesMatch(File source, File target) async {
    final sourceLength = await source.length();
    if (sourceLength != await target.length()) {
      return false;
    }
    final sourceDigest = await sha256.bind(source.openRead()).first;
    final targetDigest = await sha256.bind(target.openRead()).first;
    return sourceDigest == targetDigest;
  }

  static bool _samePath(String left, String right) {
    return _comparisonKey(p.normalize(left)) ==
        _comparisonKey(p.normalize(right));
  }

  static bool _isWithin({required String child, required String parent}) {
    final childKey = _comparisonKey(p.normalize(child));
    final parentKey = _comparisonKey(p.normalize(parent));
    final prefix = parentKey.endsWith(p.separator)
        ? parentKey
        : '$parentKey${p.separator}';
    return childKey.startsWith(prefix);
  }

  static String _comparisonKey(String path) {
    return Platform.isWindows ? path.toLowerCase() : path;
  }

  Future<void> _deleteBestEffort(Directory directory) async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // A verified duplicate is safer than turning a committed migration into
      // a failure after its references already point at the new directory.
    }
  }
}

class _DownloadDirectoryStagedFile {
  const _DownloadDirectoryStagedFile({
    required this.source,
    required this.staged,
    required this.target,
    required this.targetBoundary,
  });

  final File source;
  final File staged;
  final File target;
  final Directory targetBoundary;
}

class _DownloadDirectoryActivatedFile {
  const _DownloadDirectoryActivatedFile({
    required this.source,
    required this.target,
  });

  final File source;
  final File target;
}
