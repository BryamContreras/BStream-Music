part of 'music_providers.dart';

class SettingsState {
  const SettingsState({
    required this.downloadDirectory,
    required this.language,
    this.ytDlpPath,
    this.ffmpegPath,
    this.hasYtDlp,
    this.hasFfmpeg,
  });

  final String downloadDirectory;
  final AppLanguage language;
  final String? ytDlpPath;
  final String? ffmpegPath;
  final bool? hasYtDlp;
  final bool? hasFfmpeg;

  SettingsState copyWith({
    String? downloadDirectory,
    AppLanguage? language,
    String? ytDlpPath,
    String? ffmpegPath,
    bool? hasYtDlp,
    bool? hasFfmpeg,
  }) {
    return SettingsState(
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      language: language ?? this.language,
      ytDlpPath: ytDlpPath ?? this.ytDlpPath,
      ffmpegPath: ffmpegPath ?? this.ffmpegPath,
      hasYtDlp: hasYtDlp ?? this.hasYtDlp,
      hasFfmpeg: hasFfmpeg ?? this.hasFfmpeg,
    );
  }
}

class SettingsController extends AsyncNotifier<SettingsState> {
  static const _downloadDirectoryKey = 'settings.downloadDirectory';
  static const _languageKey = 'settings.language';
  static const _mediaRootDirectoryName = 'BStream-Music';

  @override
  Future<SettingsState> build() async {
    final prefs = await SharedPreferences.getInstance();
    final defaultDirectory = await _defaultDownloadDirectory();
    final language = AppLanguageLabel.fromCode(prefs.getString(_languageKey));
    final storedDirectory = prefs.getString(_downloadDirectoryKey);
    var downloadDirectory = _migrateLegacyDownloadDirectory(
      prefs.getString(_downloadDirectoryKey) ?? defaultDirectory,
      defaultDirectory: defaultDirectory,
    );
    if (AppPlatform.isAndroid &&
        storedDirectory != null &&
        storedDirectory != downloadDirectory) {
      await _copyMediaRootIfNeeded(storedDirectory, downloadDirectory);
      await ref
          .read(databaseServiceProvider)
          .rewriteLocalTrackMediaRoot(
            mediaRoot: downloadDirectory,
            oldMediaRoot: storedDirectory,
          );
    }
    if (AppPlatform.isAndroid &&
        !await _isAndroidWritableDownloadDirectory(downloadDirectory)) {
      downloadDirectory = defaultDirectory;
    }
    await _ensureMediaDirectories(downloadDirectory);
    await prefs.setString(_downloadDirectoryKey, downloadDirectory);
    final downloader = ref.read(downloaderServiceProvider);

    if (downloader is DesktopDownloaderService) {
      return SettingsState(
        downloadDirectory: downloadDirectory,
        language: language,
        ytDlpPath: await downloader.getYtDlpPath(),
        ffmpegPath: await downloader.getFfmpegPath(),
        hasYtDlp: await downloader.hasYtDlp(),
        hasFfmpeg: await downloader.hasFfmpeg(),
      );
    }

    return SettingsState(
      downloadDirectory: downloadDirectory,
      language: language,
    );
  }

  Future<void> setDownloadDirectory(String path) async {
    final prefs = await SharedPreferences.getInstance();
    final defaultDirectory = await _defaultDownloadDirectory();
    var normalized = _migrateLegacyDownloadDirectory(
      path.trim(),
      defaultDirectory: defaultDirectory,
    );
    if (AppPlatform.isAndroid &&
        !await _isAndroidWritableDownloadDirectory(normalized)) {
      normalized = defaultDirectory;
    }
    await _ensureMediaDirectories(normalized);
    await prefs.setString(_downloadDirectoryKey, normalized);
    final current = await future;
    state = AsyncData(current.copyWith(downloadDirectory: normalized));
  }

  Future<void> setLanguage(AppLanguage language) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, language.code);
    final current = await future;
    state = AsyncData(current.copyWith(language: language));
  }

  Future<File> createBackupFile() async {
    final current = await future;
    return ref
        .read(backupServiceProvider)
        .createBackupFile(mediaRoot: current.downloadDirectory);
  }

  Future<void> restoreBackupFile(String backupPath) async {
    final current = await future;
    await ref
        .read(backupServiceProvider)
        .restoreBackupFile(
          backupPath: backupPath,
          mediaRoot: current.downloadDirectory,
        );
    ref
      ..invalidate(libraryTracksProvider)
      ..invalidate(historyProvider)
      ..invalidate(playlistsControllerProvider);
  }

  Future<void> setYtDlpPath(String path) async {
    final downloader = ref.read(downloaderServiceProvider);
    if (downloader is! DesktopDownloaderService) {
      return;
    }
    await downloader.setYtDlpPath(path);
    final current = await future;
    state = AsyncData(
      current.copyWith(
        ytDlpPath: await downloader.getYtDlpPath(),
        hasYtDlp: await downloader.hasYtDlp(),
      ),
    );
  }

  Future<void> setFfmpegPath(String path) async {
    final downloader = ref.read(downloaderServiceProvider);
    if (downloader is! DesktopDownloaderService) {
      return;
    }
    await downloader.setFfmpegPath(path);
    final current = await future;
    state = AsyncData(
      current.copyWith(
        ffmpegPath: await downloader.getFfmpegPath(),
        hasFfmpeg: await downloader.hasFfmpeg(),
      ),
    );
  }

  Future<void> refreshToolStatus() async {
    final downloader = ref.read(downloaderServiceProvider);
    if (downloader is! DesktopDownloaderService) {
      return;
    }
    final ytDlpPath = await downloader.getYtDlpPath();
    final ffmpegPath = await downloader.getFfmpegPath();
    await downloader.setYtDlpPath(ytDlpPath);
    await downloader.setFfmpegPath(ffmpegPath);

    final current = await future;
    state = AsyncData(
      current.copyWith(
        ytDlpPath: ytDlpPath,
        ffmpegPath: ffmpegPath,
        hasYtDlp: await downloader.hasYtDlp(),
        hasFfmpeg: await downloader.hasFfmpeg(),
      ),
    );
  }

  Future<String> _defaultDownloadDirectory() async {
    if (AppPlatform.isAndroid) {
      final appRoot = await _androidAppDataRootDirectory();
      return p.join(appRoot.path, _mediaRootDirectoryName);
    }

    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return p.join(downloads.path, _mediaRootDirectoryName);
      }
    } catch (_) {
      // Some platforms do not expose a downloads directory through path_provider.
    }
    final documents = await getApplicationDocumentsDirectory();
    return p.join(documents.path, _mediaRootDirectoryName);
  }

  Future<bool> _isAndroidWritableDownloadDirectory(String path) async {
    if (!AppPlatform.isAndroid || path.trim().isEmpty) {
      return path.trim().isNotEmpty;
    }

    final appRoot = await _androidAppDataRootDirectory();
    final normalizedBase = appRoot.absolute.path;
    final normalizedPath = Directory(path).absolute.path;
    return normalizedPath == normalizedBase ||
        normalizedPath.startsWith('$normalizedBase${Platform.pathSeparator}');
  }

  Future<Directory> _androidAppDataRootDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(documents.path);
    if (p.basename(directory.path) == 'app_flutter') {
      return directory.parent;
    }
    return directory;
  }

  String _migrateLegacyDownloadDirectory(
    String path, {
    required String defaultDirectory,
  }) {
    if (path.isEmpty) {
      return path;
    }

    var normalized = path;
    if (p.basename(normalized) == 'BStream') {
      normalized = p.join(p.dirname(normalized), _mediaRootDirectoryName);
    }

    if (AppPlatform.isAndroid &&
        p.basename(normalized) == _mediaRootDirectoryName &&
        p.basename(p.dirname(normalized)) == 'app_flutter') {
      final appRootCandidate = p.dirname(p.dirname(normalized));
      final defaultParent = p.dirname(defaultDirectory);
      if (appRootCandidate == defaultParent) {
        return defaultDirectory;
      }
      return p.join(appRootCandidate, _mediaRootDirectoryName);
    }

    return normalized;
  }

  Future<void> _ensureMediaDirectories(String rootPath) async {
    if (rootPath.trim().isEmpty) {
      return;
    }
    await Directory(p.join(rootPath, 'audio')).create(recursive: true);
    await Directory(p.join(rootPath, 'thumbnails')).create(recursive: true);
  }

  Future<void> _copyMediaRootIfNeeded(
    String sourceRoot,
    String targetRoot,
  ) async {
    if (sourceRoot.trim().isEmpty ||
        targetRoot.trim().isEmpty ||
        sourceRoot == targetRoot) {
      return;
    }

    for (final folder in const ['audio', 'thumbnails']) {
      await _copyDirectoryContents(
        source: Directory(p.join(sourceRoot, folder)),
        target: Directory(p.join(targetRoot, folder)),
      );
    }
  }

  Future<void> _copyDirectoryContents({
    required Directory source,
    required Directory target,
  }) async {
    if (!await source.exists()) {
      return;
    }

    await target.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final relative = p.relative(entity.path, from: source.path);
      final destination = File(p.join(target.path, relative));
      await destination.parent.create(recursive: true);
      if (!await destination.exists()) {
        await entity.copy(destination.path);
      }
    }
  }
}
