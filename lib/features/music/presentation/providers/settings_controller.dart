part of 'music_providers.dart';

const supportedCrossfadeDurations = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 3),
  Duration(seconds: 4),
  Duration(seconds: 5),
  Duration(seconds: 6),
  Duration(seconds: 7),
  Duration(seconds: 8),
  Duration(seconds: 9),
  Duration(seconds: 10),
  Duration(seconds: 11),
  Duration(seconds: 12),
  Duration(seconds: 13),
  Duration(seconds: 14),
  Duration(seconds: 15),
];

const defaultCrossfadeDuration = Duration(seconds: 5);

Duration crossfadeDurationFromStoredSeconds(int? seconds) {
  return supportedCrossfadeDurations.firstWhere(
    (duration) => duration.inSeconds == seconds,
    orElse: () => defaultCrossfadeDuration,
  );
}

enum LyricsTextAlignment {
  normal,
  centered;

  String get code => name;

  static LyricsTextAlignment fromCode(String? code) {
    return switch (code) {
      'centered' => LyricsTextAlignment.centered,
      _ => LyricsTextAlignment.normal,
    };
  }
}

class SettingsState {
  const SettingsState({
    required this.downloadDirectory,
    required this.language,
    this.themeMode = AppThemeMode.system,
    this.accent = AppAccent.white,
    this.lyricsTextAlignment = LyricsTextAlignment.normal,
    this.lyricsAnimationStyle = LyricsAnimationStyle.smooth,
    this.lyricsRomanizationEnabled = false,
    this.lyricsRomanizationLanguages = defaultLyricsRomanizationLanguages,
    this.crossfadeEnabled = false,
    this.crossfadeDuration = defaultCrossfadeDuration,
    this.ytDlpPath,
    this.hasYtDlp,
  });

  final String downloadDirectory;
  final AppLanguage language;
  final AppThemeMode themeMode;
  final AppAccent accent;
  final LyricsTextAlignment lyricsTextAlignment;
  final LyricsAnimationStyle lyricsAnimationStyle;
  final bool lyricsRomanizationEnabled;
  final Set<LyricsRomanizationLanguage> lyricsRomanizationLanguages;
  final bool crossfadeEnabled;
  final Duration crossfadeDuration;
  final String? ytDlpPath;
  final bool? hasYtDlp;

  SettingsState copyWith({
    String? downloadDirectory,
    AppLanguage? language,
    AppThemeMode? themeMode,
    AppAccent? accent,
    LyricsTextAlignment? lyricsTextAlignment,
    LyricsAnimationStyle? lyricsAnimationStyle,
    bool? lyricsRomanizationEnabled,
    Set<LyricsRomanizationLanguage>? lyricsRomanizationLanguages,
    bool? crossfadeEnabled,
    Duration? crossfadeDuration,
    String? ytDlpPath,
    bool? hasYtDlp,
  }) {
    return SettingsState(
      downloadDirectory: downloadDirectory ?? this.downloadDirectory,
      language: language ?? this.language,
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
      lyricsTextAlignment: lyricsTextAlignment ?? this.lyricsTextAlignment,
      lyricsAnimationStyle: lyricsAnimationStyle ?? this.lyricsAnimationStyle,
      lyricsRomanizationEnabled:
          lyricsRomanizationEnabled ?? this.lyricsRomanizationEnabled,
      lyricsRomanizationLanguages:
          lyricsRomanizationLanguages ?? this.lyricsRomanizationLanguages,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDuration: crossfadeDuration ?? this.crossfadeDuration,
      ytDlpPath: ytDlpPath ?? this.ytDlpPath,
      hasYtDlp: hasYtDlp ?? this.hasYtDlp,
    );
  }
}

class SettingsController extends AsyncNotifier<SettingsState> {
  static const _downloadDirectoryKey = 'settings.downloadDirectory';
  static const _languageKey = 'settings.language';
  static const _themeModeKey = 'settings.themeMode';
  static const _accentKey = 'settings.accent';
  static const _lyricsTextAlignmentKey = 'settings.lyricsAlignment';
  static const _lyricsAnimationStyleKey = 'settings.lyricsAnimation';
  static const _lyricsRomanizationEnabledKey =
      'settings.lyricsRomanizationEnabled';
  static const _lyricsRomanizationLanguagesKey =
      'settings.lyricsRomanizationLanguages';
  static const _crossfadeEnabledKey = 'settings.crossfadeEnabled';
  static const _crossfadeSecondsKey = 'settings.crossfadeSeconds';
  static const _mediaRootDirectoryName = 'BStream-Music';
  Future<void> _lyricsTextAlignmentWriteTail = Future<void>.value();
  Future<void> _lyricsAnimationStyleWriteTail = Future<void>.value();
  Future<void> _lyricsRomanizationWriteTail = Future<void>.value();
  Future<void> _crossfadeWriteTail = Future<void>.value();

  @override
  Future<SettingsState> build() async {
    final prefs = await SharedPreferences.getInstance();
    final defaultDirectory = await _defaultDownloadDirectory();
    final language = AppLanguageLabel.fromCode(prefs.getString(_languageKey));
    final themeMode = AppThemeMode.fromCode(prefs.getString(_themeModeKey));
    final storedAccentCode = prefs.getString(_accentKey);
    final accent = AppAccent.fromCode(storedAccentCode);
    if (storedAccentCode == 'amber') {
      await prefs.setString(_accentKey, accent.code);
    }
    final lyricsTextAlignment = LyricsTextAlignment.fromCode(
      prefs.getString(_lyricsTextAlignmentKey),
    );
    final storedLyricsAnimationStyle = prefs.getString(
      _lyricsAnimationStyleKey,
    );
    final lyricsAnimationStyle = LyricsAnimationStyle.fromCode(
      storedLyricsAnimationStyle,
    );
    if (storedLyricsAnimationStyle == 'none') {
      await prefs.setString(
        _lyricsAnimationStyleKey,
        lyricsAnimationStyle.code,
      );
    }
    final lyricsRomanizationEnabled =
        prefs.getBool(_lyricsRomanizationEnabledKey) ?? false;
    final lyricsRomanizationLanguages = LyricsRomanizationLanguage.fromCodes(
      prefs.getStringList(_lyricsRomanizationLanguagesKey),
    );
    final crossfadeSeconds = prefs.getInt(_crossfadeSecondsKey);
    final crossfadeDuration = crossfadeDurationFromStoredSeconds(
      crossfadeSeconds,
    );
    final crossfadeEnabled = prefs.getBool(_crossfadeEnabledKey) ?? false;
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
    final downloader = ref.read(ytDlpDownloaderServiceProvider);

    if (downloader is DesktopDownloaderService) {
      return SettingsState(
        downloadDirectory: downloadDirectory,
        language: language,
        themeMode: themeMode,
        accent: accent,
        lyricsTextAlignment: lyricsTextAlignment,
        lyricsAnimationStyle: lyricsAnimationStyle,
        lyricsRomanizationEnabled: lyricsRomanizationEnabled,
        lyricsRomanizationLanguages: lyricsRomanizationLanguages,
        crossfadeEnabled: crossfadeEnabled,
        crossfadeDuration: crossfadeDuration,
        ytDlpPath: await downloader.getYtDlpPath(),
        hasYtDlp: await downloader.hasYtDlp(),
      );
    }

    return SettingsState(
      downloadDirectory: downloadDirectory,
      language: language,
      themeMode: themeMode,
      accent: accent,
      lyricsTextAlignment: lyricsTextAlignment,
      lyricsAnimationStyle: lyricsAnimationStyle,
      lyricsRomanizationEnabled: lyricsRomanizationEnabled,
      lyricsRomanizationLanguages: lyricsRomanizationLanguages,
      crossfadeEnabled: crossfadeEnabled,
      crossfadeDuration: crossfadeDuration,
    );
  }

  Future<void> setDownloadDirectory(String path) async {
    final coordinator = ref.read(libraryOperationCoordinatorProvider);
    return coordinator.runExclusive(
      LibraryMaintenancePhase.migratingDirectory,
      () => _setDownloadDirectoryInternal(path),
    );
  }

  Future<void> _setDownloadDirectoryInternal(String path) async {
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

    final current = await future;
    final oldDirectory = current.downloadDirectory.trim();
    if (oldDirectory.isEmpty || oldDirectory == normalized) {
      await _ensureMediaDirectories(normalized);
      await prefs.setString(_downloadDirectoryKey, normalized);
      state = AsyncData(current.copyWith(downloadDirectory: normalized));
      return;
    }

    final oldAudioDir = Directory(p.join(oldDirectory, 'audio'));
    final oldThumbDir = Directory(p.join(oldDirectory, 'thumbnails'));
    final newAudioDir = Directory(p.join(normalized, 'audio'));
    final newThumbDir = Directory(p.join(normalized, 'thumbnails'));

    await _ensureMediaDirectories(normalized);

    final hasOldAudio = await oldAudioDir.exists();
    final hasOldThumbs = await oldThumbDir.exists();

    if (hasOldAudio || hasOldThumbs) {
      final player = ref.read(playerControllerProvider.notifier);
      await player.stop();

      final stagingRoot = Directory(
        p.join(
          (await getTemporaryDirectory()).path,
          'bstream_migrate_${DateTime.now().millisecondsSinceEpoch}',
        ),
      );
      await stagingRoot.create(recursive: true);

      try {
        if (hasOldAudio) {
          await _copyDirectoryContents(
            source: oldAudioDir,
            target: Directory(p.join(stagingRoot.path, 'audio')),
          );
        }
        if (hasOldThumbs) {
          await _copyDirectoryContents(
            source: oldThumbDir,
            target: Directory(p.join(stagingRoot.path, 'thumbnails')),
          );
        }

        final db = ref.read(databaseServiceProvider);
        await db.withDatabase((database) async {
          if (hasOldAudio) {
            final stagingAudio = Directory(p.join(stagingRoot.path, 'audio'));
            await _verifyCopiedFiles(oldAudioDir, stagingAudio);
            await stagingAudio.rename(newAudioDir.path);
          }
          if (hasOldThumbs) {
            final stagingThumbs = Directory(
              p.join(stagingRoot.path, 'thumbnails'),
            );
            await _verifyCopiedFiles(oldThumbDir, stagingThumbs);
            await stagingThumbs.rename(newThumbDir.path);
          }

          await db.rewriteLocalTrackMediaRoot(
            mediaRoot: normalized,
            oldMediaRoot: oldDirectory,
          );
        });

        if (hasOldAudio && await oldAudioDir.exists()) {
          await oldAudioDir.delete(recursive: true);
        }
        if (hasOldThumbs && await oldThumbDir.exists()) {
          await oldThumbDir.delete(recursive: true);
        }
      } catch (error) {
        if (await stagingRoot.exists()) {
          await stagingRoot.delete(recursive: true);
        }
        rethrow;
      }
    }

    await prefs.setString(_downloadDirectoryKey, normalized);
    ref
      ..invalidate(libraryTracksProvider)
      ..invalidate(historyProvider)
      ..invalidate(playlistsControllerProvider);
    state = AsyncData(current.copyWith(downloadDirectory: normalized));
  }

  Future<void> _verifyCopiedFiles(
    Directory source,
    Directory destination,
  ) async {
    final sourceFiles = <String>{};
    await for (final entity in source.list(recursive: true)) {
      if (entity is File) {
        sourceFiles.add(p.relative(entity.path, from: source.path));
      }
    }
    for (final relative in sourceFiles) {
      final destFile = File(p.join(destination.path, relative));
      if (!await destFile.exists()) {
        throw StateError(
          'La migración falló: falta el archivo $relative en el destino.',
        );
      }
    }
  }

  Future<void> setLanguage(AppLanguage language) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, language.code);
    final current = await future;
    state = AsyncData(current.copyWith(language: language));
  }

  Future<void> setThemeMode(AppThemeMode themeMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, themeMode.code);
    final current = await future;
    state = AsyncData(current.copyWith(themeMode: themeMode));
  }

  Future<void> setAccent(AppAccent accent) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentKey, accent.code);
    final current = await future;
    state = AsyncData(current.copyWith(accent: accent));
  }

  Future<void> setLyricsTextAlignment(
    LyricsTextAlignment lyricsTextAlignment,
  ) async {
    final current = state.asData?.value ?? await future;
    if (current.lyricsTextAlignment == lyricsTextAlignment) {
      return;
    }
    state = AsyncData(
      current.copyWith(lyricsTextAlignment: lyricsTextAlignment),
    );
    final write = _lyricsTextAlignmentWriteTail.catchError((_) {}).then((
      _,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lyricsTextAlignmentKey, lyricsTextAlignment.code);
    });
    _lyricsTextAlignmentWriteTail = write.catchError((_) {});
    await write;
  }

  Future<void> toggleLyricsTextAlignment() async {
    final current = state.asData?.value ?? await future;
    final next = current.lyricsTextAlignment == LyricsTextAlignment.centered
        ? LyricsTextAlignment.normal
        : LyricsTextAlignment.centered;
    await setLyricsTextAlignment(next);
  }

  Future<void> setLyricsAnimationStyle(
    LyricsAnimationStyle lyricsAnimationStyle,
  ) async {
    final current = state.asData?.value ?? await future;
    if (current.lyricsAnimationStyle == lyricsAnimationStyle) {
      return;
    }
    state = AsyncData(
      current.copyWith(lyricsAnimationStyle: lyricsAnimationStyle),
    );
    final write = _lyricsAnimationStyleWriteTail.catchError((_) {}).then((
      _,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _lyricsAnimationStyleKey,
        lyricsAnimationStyle.code,
      );
    });
    _lyricsAnimationStyleWriteTail = write.catchError((_) {});
    await write;
  }

  Future<void> setLyricsRomanizationEnabled(bool enabled) async {
    final current = state.asData?.value ?? await future;
    if (current.lyricsRomanizationEnabled == enabled) {
      return;
    }
    state = AsyncData(current.copyWith(lyricsRomanizationEnabled: enabled));
    final write = _lyricsRomanizationWriteTail.catchError((_) {}).then((
      _,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_lyricsRomanizationEnabledKey, enabled);
    });
    _lyricsRomanizationWriteTail = write.catchError((_) {});
    await write;
  }

  Future<void> setLyricsRomanizationLanguages(
    Set<LyricsRomanizationLanguage> languages,
  ) async {
    if (languages.isEmpty) {
      return;
    }
    final selected = Set<LyricsRomanizationLanguage>.unmodifiable(languages);
    final current = state.asData?.value ?? await future;
    if (current.lyricsRomanizationLanguages.length == selected.length &&
        current.lyricsRomanizationLanguages.containsAll(selected)) {
      return;
    }
    state = AsyncData(current.copyWith(lyricsRomanizationLanguages: selected));
    final write = _lyricsRomanizationWriteTail.catchError((_) {}).then((
      _,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_lyricsRomanizationLanguagesKey, [
        for (final language in LyricsRomanizationLanguage.values)
          if (selected.contains(language)) language.code,
      ]);
    });
    _lyricsRomanizationWriteTail = write.catchError((_) {});
    await write;
  }

  Future<void> toggleLyricsRomanizationLanguage(
    LyricsRomanizationLanguage language,
  ) async {
    final current = state.asData?.value ?? await future;
    final selected = current.lyricsRomanizationLanguages.toSet();
    if (!selected.add(language) && selected.length > 1) {
      selected.remove(language);
    }
    await setLyricsRomanizationLanguages(selected);
  }

  Future<void> setCrossfadeEnabled(bool enabled) async {
    final current = state.asData?.value ?? await future;
    if (current.crossfadeEnabled == enabled) {
      return;
    }
    state = AsyncData(current.copyWith(crossfadeEnabled: enabled));
    final write = _crossfadeWriteTail.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_crossfadeEnabledKey, enabled);
    });
    _crossfadeWriteTail = write.catchError((_) {});
    await write;
  }

  Future<void> setCrossfadeDuration(Duration duration) async {
    if (!supportedCrossfadeDurations.contains(duration)) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Crossfade must be a whole number of seconds from 1 through 15.',
      );
    }
    final current = state.asData?.value ?? await future;
    if (current.crossfadeDuration == duration) {
      return;
    }
    state = AsyncData(current.copyWith(crossfadeDuration: duration));
    final write = _crossfadeWriteTail.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_crossfadeSecondsKey, duration.inSeconds);
    });
    _crossfadeWriteTail = write.catchError((_) {});
    await write;
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
    final downloader = ref.read(ytDlpDownloaderServiceProvider);
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

  Future<void> refreshToolStatus() async {
    final downloader = ref.read(ytDlpDownloaderServiceProvider);
    if (downloader is! DesktopDownloaderService) {
      return;
    }
    final ytDlpPath = await downloader.getYtDlpPath();
    await downloader.setYtDlpPath(ytDlpPath);

    final current = await future;
    state = AsyncData(
      current.copyWith(
        ytDlpPath: ytDlpPath,
        hasYtDlp: await downloader.hasYtDlp(),
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
