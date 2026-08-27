part of 'music_providers.dart';

final settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, SettingsState>(
      SettingsController.new,
    );

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

enum LocalMusicFilter {
  hideWhatsAppAudio,
  hideTelegramAudio,
  hideAudioRecordings,
  hideTracksUnder30Seconds;

  String get code => name;

  static Set<LocalMusicFilter> fromCodes(List<String>? codes) {
    if (codes == null) {
      return defaultLocalMusicFilters;
    }
    final storedCodes = codes.toSet();
    return Set<LocalMusicFilter>.unmodifiable(
      LocalMusicFilter.values.where(
        (filter) => storedCodes.contains(filter.code),
      ),
    );
  }
}

const defaultLocalMusicFilters = <LocalMusicFilter>{
  LocalMusicFilter.hideWhatsAppAudio,
  LocalMusicFilter.hideTelegramAudio,
  LocalMusicFilter.hideAudioRecordings,
  LocalMusicFilter.hideTracksUnder30Seconds,
};

class SettingsState {
  const SettingsState({
    required this.downloadDirectory,
    required this.language,
    this.themeMode = AppThemeMode.system,
    this.accent = AppAccent.white,
    this.surfaceBackgroundMode = SurfaceBackgroundMode.accent,
    this.miniPlayerMode = defaultMiniPlayerMode,
    this.miniPlayerBackgroundMode = defaultMiniPlayerBackgroundMode,
    this.lyricsTextAlignment = LyricsTextAlignment.normal,
    this.lyricsAnimationStyle = LyricsAnimationStyle.smooth,
    this.lyricsRomanizationEnabled = false,
    this.lyricsRomanizationLanguages = defaultLyricsRomanizationLanguages,
    this.recommendationHistoryEnabled = true,
    this.localMusicFilters = defaultLocalMusicFilters,
    this.crossfadeEnabled = false,
    this.crossfadeDuration = defaultCrossfadeDuration,
    this.ytDlpPath,
    this.hasYtDlp,
  });

  final String downloadDirectory;
  final AppLanguage language;
  final AppThemeMode themeMode;
  final AppAccent accent;
  final SurfaceBackgroundMode surfaceBackgroundMode;
  final MiniPlayerMode miniPlayerMode;
  final MiniPlayerBackgroundMode miniPlayerBackgroundMode;
  final LyricsTextAlignment lyricsTextAlignment;
  final LyricsAnimationStyle lyricsAnimationStyle;
  final bool lyricsRomanizationEnabled;
  final Set<LyricsRomanizationLanguage> lyricsRomanizationLanguages;
  final bool recommendationHistoryEnabled;
  final Set<LocalMusicFilter> localMusicFilters;
  final bool crossfadeEnabled;
  final Duration crossfadeDuration;
  final String? ytDlpPath;
  final bool? hasYtDlp;

  SettingsState copyWith({
    String? downloadDirectory,
    AppLanguage? language,
    AppThemeMode? themeMode,
    AppAccent? accent,
    SurfaceBackgroundMode? surfaceBackgroundMode,
    MiniPlayerMode? miniPlayerMode,
    MiniPlayerBackgroundMode? miniPlayerBackgroundMode,
    LyricsTextAlignment? lyricsTextAlignment,
    LyricsAnimationStyle? lyricsAnimationStyle,
    bool? lyricsRomanizationEnabled,
    Set<LyricsRomanizationLanguage>? lyricsRomanizationLanguages,
    bool? recommendationHistoryEnabled,
    Set<LocalMusicFilter>? localMusicFilters,
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
      surfaceBackgroundMode:
          surfaceBackgroundMode ?? this.surfaceBackgroundMode,
      miniPlayerMode: miniPlayerMode ?? this.miniPlayerMode,
      miniPlayerBackgroundMode:
          miniPlayerBackgroundMode ?? this.miniPlayerBackgroundMode,
      lyricsTextAlignment: lyricsTextAlignment ?? this.lyricsTextAlignment,
      lyricsAnimationStyle: lyricsAnimationStyle ?? this.lyricsAnimationStyle,
      lyricsRomanizationEnabled:
          lyricsRomanizationEnabled ?? this.lyricsRomanizationEnabled,
      lyricsRomanizationLanguages:
          lyricsRomanizationLanguages ?? this.lyricsRomanizationLanguages,
      recommendationHistoryEnabled:
          recommendationHistoryEnabled ?? this.recommendationHistoryEnabled,
      localMusicFilters: localMusicFilters ?? this.localMusicFilters,
      crossfadeEnabled: crossfadeEnabled ?? this.crossfadeEnabled,
      crossfadeDuration: crossfadeDuration ?? this.crossfadeDuration,
      ytDlpPath: ytDlpPath ?? this.ytDlpPath,
      hasYtDlp: hasYtDlp ?? this.hasYtDlp,
    );
  }
}

class SettingsController extends AsyncNotifier<SettingsState> {
  static const _downloadDirectoryKey = 'settings.downloadDirectory';
  static const _downloadDirectoryMigrationJournalKey =
      'settings.downloadDirectoryMigration.v1';
  static const _languageKey = 'settings.language';
  static const _themeModeKey = 'settings.themeMode';
  static const _accentKey = 'settings.accent';
  static const _surfaceBackgroundModeKey = 'settings.surfaceBackgroundMode';
  static const _miniPlayerModeKey = 'settings.miniPlayerMode';
  static const _miniPlayerBackgroundModeKey =
      'settings.miniPlayerBackgroundMode';
  static const _lyricsTextAlignmentKey = 'settings.lyricsAlignment';
  static const _lyricsAnimationStyleKey = 'settings.lyricsAnimation';
  static const _lyricsRomanizationEnabledKey =
      'settings.lyricsRomanizationEnabled';
  static const _lyricsRomanizationLanguagesKey =
      'settings.lyricsRomanizationLanguages';
  static const _recommendationHistoryEnabledKey =
      'settings.recommendationHistoryEnabled';
  static const _localMusicFiltersKey = 'settings.localMusicFilters';
  static const _crossfadeEnabledKey = 'settings.crossfadeEnabled';
  static const _crossfadeSecondsKey = 'settings.crossfadeSeconds';
  static const _mediaRootDirectoryName = 'BStream-Music';
  Future<void> _lyricsTextAlignmentWriteTail = Future<void>.value();
  Future<void> _lyricsAnimationStyleWriteTail = Future<void>.value();
  Future<void> _lyricsRomanizationWriteTail = Future<void>.value();
  Future<void> _recommendationHistoryWriteTail = Future<void>.value();
  Future<void> _localMusicFiltersWriteTail = Future<void>.value();
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
    final surfaceBackgroundMode = SurfaceBackgroundMode.fromCode(
      prefs.getString(_surfaceBackgroundModeKey),
    );
    final miniPlayerMode = MiniPlayerMode.fromCode(
      prefs.getString(_miniPlayerModeKey),
      platform: defaultTargetPlatform,
    );
    final miniPlayerBackgroundMode = MiniPlayerBackgroundMode.fromCode(
      prefs.getString(_miniPlayerBackgroundModeKey),
    );
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
    final recommendationHistoryEnabled =
        prefs.getBool(_recommendationHistoryEnabledKey) ?? true;
    final localMusicFilters = LocalMusicFilter.fromCodes(
      prefs.getStringList(_localMusicFiltersKey),
    );
    final crossfadeSeconds = prefs.getInt(_crossfadeSecondsKey);
    final crossfadeDuration = crossfadeDurationFromStoredSeconds(
      crossfadeSeconds,
    );
    final crossfadeEnabled = prefs.getBool(_crossfadeEnabledKey) ?? false;
    final storedDirectory = prefs.getString(_downloadDirectoryKey);
    final encodedMigrationJournal = prefs.getString(
      _downloadDirectoryMigrationJournalKey,
    );
    var pendingMigration = DownloadDirectoryMigrationJournal.tryDecode(
      encodedMigrationJournal,
    );
    if (encodedMigrationJournal != null && pendingMigration == null) {
      await prefs.remove(_downloadDirectoryMigrationJournalKey);
    }

    // A journal is untrusted persisted input. Validate its canonical source
    // relationship before entering the exclusive migration phase so a stale,
    // hand-edited, or corrupted journal cannot brick Settings on every start.
    // Recoverable I/O failures after a valid migration starts still keep the
    // journal and are handled by the migrator's idempotent resume path.
    final journalToValidate = pendingMigration;
    if (journalToValidate != null) {
      try {
        final migrator = const DownloadDirectoryMigrator();
        final paths = await migrator.validatePaths(
          sourceRoot: journalToValidate.sourceRoot,
          targetRoot: journalToValidate.targetRoot,
        );
        await migrator.validateReferenceSourceRoot(
          referenceSourceRoot: journalToValidate.referenceSourceRoot,
          canonicalSourceRoot: paths.sourceRoot,
        );
      } on ArgumentError catch (error) {
        debugPrint('Discarding an invalid download migration journal: $error');
        await prefs.remove(_downloadDirectoryMigrationJournalKey);
        pendingMigration = null;
      }
    }

    late String downloadDirectory;
    final migrationToRecover = pendingMigration;
    if (migrationToRecover != null) {
      final coordinator = ref.read(libraryOperationCoordinatorProvider);
      downloadDirectory = await coordinator.runExclusive(
        LibraryMaintenancePhase.migratingDirectory,
        () => _migrateDownloadDirectory(
          prefs: prefs,
          oldDirectory: migrationToRecover.sourceRoot,
          newDirectory: migrationToRecover.targetRoot,
          stopPlayer: false,
          recoveringJournal: true,
          referenceSourceDirectory: migrationToRecover.referenceSourceRoot,
        ),
      );
    } else {
      final candidateDirectory = _migrateLegacyDownloadDirectory(
        storedDirectory ?? defaultDirectory,
        defaultDirectory: defaultDirectory,
      );
      var canMigrateStoredDirectory = storedDirectory != null;
      try {
        downloadDirectory = DownloadDirectoryMigrator.normalizeAbsoluteRoot(
          candidateDirectory,
          parameterName: 'downloadDirectory',
        );
      } on ArgumentError catch (error) {
        // A download root persisted by an older or hand-edited installation is
        // untrusted input. In particular, never pass a filesystem root into
        // migration: falling back must only create BStream's default folders.
        debugPrint(
          'Discarding an invalid persisted download directory: $error',
        );
        downloadDirectory = DownloadDirectoryMigrator.normalizeAbsoluteRoot(
          defaultDirectory,
          parameterName: 'defaultDownloadDirectory',
        );
        canMigrateStoredDirectory = false;
      }
      if (AppPlatform.isAndroid &&
          !await _isAndroidWritableDownloadDirectory(downloadDirectory)) {
        downloadDirectory = DownloadDirectoryMigrator.normalizeAbsoluteRoot(
          defaultDirectory,
          parameterName: 'defaultDownloadDirectory',
        );
      }
      if (canMigrateStoredDirectory &&
          !DownloadDirectoryMigrator.rootsEqual(
            storedDirectory!,
            downloadDirectory,
          )) {
        final coordinator = ref.read(libraryOperationCoordinatorProvider);
        downloadDirectory = await coordinator.runExclusive(
          LibraryMaintenancePhase.migratingDirectory,
          () => _migrateDownloadDirectory(
            prefs: prefs,
            oldDirectory: storedDirectory,
            newDirectory: downloadDirectory,
            stopPlayer: false,
          ),
        );
      }
    }
    await _ensureMediaDirectories(downloadDirectory);
    await const DownloadDirectoryMigrator().cleanupStaleArtifacts(
      downloadDirectory,
    );
    await _writeDownloadDirectoryPreference(prefs, downloadDirectory);
    final downloader = ref.read(ytDlpDownloaderServiceProvider);

    if (downloader is DesktopDownloaderService) {
      return SettingsState(
        downloadDirectory: downloadDirectory,
        language: language,
        themeMode: themeMode,
        accent: accent,
        surfaceBackgroundMode: surfaceBackgroundMode,
        miniPlayerMode: miniPlayerMode,
        miniPlayerBackgroundMode: miniPlayerBackgroundMode,
        lyricsTextAlignment: lyricsTextAlignment,
        lyricsAnimationStyle: lyricsAnimationStyle,
        lyricsRomanizationEnabled: lyricsRomanizationEnabled,
        lyricsRomanizationLanguages: lyricsRomanizationLanguages,
        recommendationHistoryEnabled: recommendationHistoryEnabled,
        localMusicFilters: localMusicFilters,
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
      surfaceBackgroundMode: surfaceBackgroundMode,
      miniPlayerMode: miniPlayerMode,
      miniPlayerBackgroundMode: miniPlayerBackgroundMode,
      lyricsTextAlignment: lyricsTextAlignment,
      lyricsAnimationStyle: lyricsAnimationStyle,
      lyricsRomanizationEnabled: lyricsRomanizationEnabled,
      lyricsRomanizationLanguages: lyricsRomanizationLanguages,
      recommendationHistoryEnabled: recommendationHistoryEnabled,
      localMusicFilters: localMusicFilters,
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
    normalized = DownloadDirectoryMigrator.normalizeAbsoluteRoot(
      normalized,
      parameterName: 'path',
    );

    final current = await future;
    final oldDirectory = current.downloadDirectory.trim();
    if (oldDirectory.isEmpty ||
        DownloadDirectoryMigrator.rootsEqual(oldDirectory, normalized)) {
      await _ensureMediaDirectories(normalized);
      await _writeDownloadDirectoryPreference(prefs, normalized);
      final latest = state.asData?.value ?? await future;
      state = AsyncData(latest.copyWith(downloadDirectory: normalized));
      return;
    }

    normalized = await _migrateDownloadDirectory(
      prefs: prefs,
      oldDirectory: oldDirectory,
      newDirectory: normalized,
      stopPlayer: true,
    );
    ref
      ..invalidate(libraryTracksProvider)
      ..invalidate(historyProvider)
      ..invalidate(playlistsControllerProvider);
    final latest = state.asData?.value ?? await future;
    state = AsyncData(latest.copyWith(downloadDirectory: normalized));
  }

  Future<String> _migrateDownloadDirectory({
    required SharedPreferences prefs,
    required String oldDirectory,
    required String newDirectory,
    required bool stopPlayer,
    bool recoveringJournal = false,
    String? referenceSourceDirectory,
  }) async {
    final migrator = const DownloadDirectoryMigrator();
    final paths = await migrator.validatePaths(
      sourceRoot: oldDirectory,
      targetRoot: newDirectory,
    );
    final referenceSourceRoot = await migrator.validateReferenceSourceRoot(
      referenceSourceRoot: referenceSourceDirectory ?? oldDirectory,
      canonicalSourceRoot: paths.sourceRoot,
    );
    await _writeDownloadDirectoryMigrationJournal(
      prefs,
      paths,
      referenceSourceRoot: referenceSourceRoot,
    );

    try {
      if (stopPlayer && await migrator.hasManagedContent(paths.sourceRoot)) {
        await ref.read(playerControllerProvider.notifier).stop();
      }

      final database = ref.read(databaseServiceProvider);
      LocalTrackMediaRootRewrite? databaseRewrite;
      final result = await migrator.migrate(
        sourceRoot: paths.sourceRoot,
        targetRoot: paths.targetRoot,
        commitReferences: (committedPaths) async {
          // The durable journal records an arbitrary user-selected target.
          // Database paths commit first and the visible preference commits
          // last; startup can therefore resume every interruption point.
          databaseRewrite = await database
              .rewriteLocalTrackMediaRootWithSnapshot(
                mediaRoot: committedPaths.targetRoot,
                oldMediaRoot: referenceSourceRoot,
                canonicalOldMediaRoot: committedPaths.sourceRoot,
              );
          await _writeDownloadDirectoryPreference(
            prefs,
            committedPaths.targetRoot,
          );
        },
        rollbackReferences: (_) async {
          Object? firstError;
          StackTrace? firstStackTrace;
          final rewrite = databaseRewrite;
          if (rewrite != null) {
            try {
              // Restore only rows changed by this operation. A broad target to
              // source rewrite could corrupt tracks that already belonged to
              // the destination before migration started.
              await database.restoreLocalTrackMediaPaths(rewrite);
            } catch (error, stackTrace) {
              firstError = error;
              firstStackTrace = stackTrace;
            }
          }
          try {
            await _writeDownloadDirectoryPreference(prefs, referenceSourceRoot);
          } catch (error, stackTrace) {
            firstError ??= error;
            firstStackTrace ??= stackTrace;
          }
          if (firstError != null) {
            Error.throwWithStackTrace(firstError, firstStackTrace!);
          }
        },
      );
      await _clearDownloadDirectoryMigrationJournal(prefs);
      return result.targetRoot;
    } catch (error, stackTrace) {
      // A regular failure with a complete rollback has no work to resume. A
      // failed rollback, or any failure while recovering an earlier crash,
      // keeps the journal so startup cannot forget the selected target.
      if (!recoveringJournal && error is! DownloadDirectoryMigrationException) {
        try {
          await _removeDownloadDirectoryMigrationJournal(prefs);
        } catch (journalError) {
          throw DownloadDirectoryMigrationException(
            cause: error,
            rollbackErrors: <Object>[journalError],
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _writeDownloadDirectoryMigrationJournal(
    SharedPreferences prefs,
    DownloadDirectoryMigrationPaths paths, {
    required String referenceSourceRoot,
  }) async {
    final journal = DownloadDirectoryMigrationJournal(
      sourceRoot: paths.sourceRoot,
      targetRoot: paths.targetRoot,
      referenceSourceRoot: referenceSourceRoot,
    );
    if (!await prefs.setString(
      _downloadDirectoryMigrationJournalKey,
      journal.encode(),
    )) {
      throw StateError('No se pudo preparar la migración de descargas.');
    }
  }

  Future<void> _removeDownloadDirectoryMigrationJournal(
    SharedPreferences prefs,
  ) async {
    if (!await prefs.remove(_downloadDirectoryMigrationJournalKey)) {
      throw StateError('No se pudo cerrar la migración de descargas.');
    }
  }

  Future<void> _clearDownloadDirectoryMigrationJournal(
    SharedPreferences prefs,
  ) async {
    try {
      await prefs.remove(_downloadDirectoryMigrationJournalKey);
    } catch (_) {
      // A stale success journal is safe: recovery is idempotent and simply
      // reaffirms the already committed target on the next startup.
    }
  }

  Future<void> _writeDownloadDirectoryPreference(
    SharedPreferences prefs,
    String path,
  ) async {
    if (!await prefs.setString(_downloadDirectoryKey, path)) {
      throw StateError('No se pudo guardar el directorio de descargas.');
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

  Future<void> setSurfaceBackgroundMode(SurfaceBackgroundMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_surfaceBackgroundModeKey, mode.code);
    final current = await future;
    state = AsyncData(current.copyWith(surfaceBackgroundMode: mode));
  }

  Future<void> setMiniPlayerMode(MiniPlayerMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_miniPlayerModeKey, mode.code);
    final current = await future;
    state = AsyncData(current.copyWith(miniPlayerMode: mode));
  }

  Future<void> setMiniPlayerBackgroundMode(
    MiniPlayerBackgroundMode mode,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_miniPlayerBackgroundModeKey, mode.code);
    final current = await future;
    state = AsyncData(current.copyWith(miniPlayerBackgroundMode: mode));
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

  Future<void> setRecommendationHistoryEnabled(bool enabled) async {
    final current = state.asData?.value ?? await future;
    if (current.recommendationHistoryEnabled == enabled) {
      return;
    }
    state = AsyncData(current.copyWith(recommendationHistoryEnabled: enabled));
    final write = _recommendationHistoryWriteTail.catchError((_) {}).then((
      _,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_recommendationHistoryEnabledKey, enabled);
    });
    _recommendationHistoryWriteTail = write.catchError((_) {});
    await write;
  }

  Future<void> clearRecommendationHistory() async {
    final player = ref.read(playerControllerProvider.notifier);
    final database = ref.read(databaseServiceProvider);
    final coordinator = ref.read(libraryOperationCoordinatorProvider);
    await coordinator.runWithGate(() async {
      await player.resetRecommendationHistoryTracking();
      await database.clearRecommendationHistory();
    });
    ref
      ..invalidate(historyProvider)
      // Drop the in-memory artist-release cache together with SQLite data.
      // A later qualifying listen creates a completely fresh engine.
      ..invalidate(personalizedHomeFeedSourceProvider)
      ..invalidate(homeRecommendationsProvider);
  }

  Future<void> setLocalMusicFilters(Set<LocalMusicFilter> filters) async {
    final selected = Set<LocalMusicFilter>.unmodifiable(filters);
    final current = state.asData?.value ?? await future;
    if (current.localMusicFilters.length == selected.length &&
        current.localMusicFilters.containsAll(selected)) {
      return;
    }
    state = AsyncData(current.copyWith(localMusicFilters: selected));
    final write = _localMusicFiltersWriteTail.catchError((_) {}).then((
      _,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_localMusicFiltersKey, [
        for (final filter in LocalMusicFilter.values)
          if (selected.contains(filter)) filter.code,
      ]);
    });
    _localMusicFiltersWriteTail = write.catchError((_) {});
    await write;
  }

  Future<void> toggleLocalMusicFilter(LocalMusicFilter filter) async {
    final current = state.asData?.value ?? await future;
    final selected = current.localMusicFilters.toSet();
    if (!selected.add(filter)) {
      selected.remove(filter);
    }
    await setLocalMusicFilters(selected);
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
    final player = ref.read(playerControllerProvider.notifier);
    await player.suspendRecommendationHistoryTracking();
    try {
      return await ref
          .read(backupServiceProvider)
          .createBackupFile(mediaRoot: current.downloadDirectory);
    } finally {
      await player.resumeRecommendationHistoryTracking();
    }
  }

  Future<void> restoreBackupFile(String backupPath) async {
    final current = await future;
    final player = ref.read(playerControllerProvider.notifier);
    final database = ref.read(databaseServiceProvider);
    await player.suspendRecommendationHistoryTracking();
    database.advanceRecommendationGeneration();
    try {
      await ref
          .read(backupServiceProvider)
          .restoreBackupFile(
            backupPath: backupPath,
            mediaRoot: current.downloadDirectory,
          );
    } finally {
      // The restore operation advances the epoch while it still owns the
      // maintenance barrier. Advance it once more before rebuilding providers
      // so work from the previous source can never publish into the restored
      // database during the hand-off.
      database.advanceRecommendationGeneration();
      await player.resumeRecommendationHistoryTracking();
      ref
        ..invalidate(libraryTracksProvider)
        ..invalidate(historyProvider)
        ..invalidate(playlistsControllerProvider)
        ..invalidate(personalizedHomeFeedSourceProvider)
        ..invalidate(homeRecommendationsProvider);
    }
  }

  Future<void> setYtDlpPath(String path) async {
    final downloader = ref.read(ytDlpDownloaderServiceProvider);
    if (downloader is! DesktopDownloaderService) {
      return;
    }
    await downloader.setYtDlpPath(path);
    final ytDlpPath = await downloader.getYtDlpPath();
    final hasYtDlp = await downloader.hasYtDlp();
    final latest = state.asData?.value ?? await future;
    state = AsyncData(
      latest.copyWith(ytDlpPath: ytDlpPath, hasYtDlp: hasYtDlp),
    );
  }

  Future<void> refreshToolStatus() async {
    final downloader = ref.read(ytDlpDownloaderServiceProvider);
    if (downloader is! DesktopDownloaderService) {
      return;
    }
    final ytDlpPath = await downloader.getYtDlpPath();
    await downloader.setYtDlpPath(ytDlpPath);
    final hasYtDlp = await downloader.hasYtDlp();
    final latest = state.asData?.value ?? await future;
    state = AsyncData(
      latest.copyWith(ytDlpPath: ytDlpPath, hasYtDlp: hasYtDlp),
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
}
