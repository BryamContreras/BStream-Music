import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/download_options.dart';
import 'package:bstream_music/features/music/domain/entities/download_result.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/services/downloader/desktop_downloader_service.dart';
import 'package:bstream_music/services/downloader/downloader_service.dart';
import 'package:bstream_music/services/storage/local_database_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const journalKey = 'settings.downloadDirectoryMigration.v1';
  const downloadDirectoryKey = 'settings.downloadDirectory';

  late Directory sandbox;
  late String documentsPath;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sandbox = await Directory.systemTemp.createTemp(
      'bstream-settings-startup-',
    );
    documentsPath = p.join(sandbox.path, 'documents');
    await Directory(documentsPath).create(recursive: true);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          return switch (call.method) {
            'getDownloadsDirectory' => null,
            'getApplicationDocumentsDirectory' => documentsPath,
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

  test('startup restores the persisted capsule mini player mode', () async {
    SharedPreferences.setMockInitialValues({
      'settings.surfaceBackgroundMode': 'transparent',
      'settings.miniPlayerMode': 'capsule',
      'settings.miniPlayerBackgroundMode': 'transparent',
    });
    final container = ProviderContainer(
      overrides: [
        ytDlpDownloaderServiceProvider.overrideWithValue(
          const _NoopDownloaderService(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);

    expect(settings.surfaceBackgroundMode, SurfaceBackgroundMode.transparent);
    expect(settings.miniPlayerMode, MiniPlayerMode.capsule);
    expect(
      settings.miniPlayerBackgroundMode,
      MiniPlayerBackgroundMode.transparent,
    );
  });

  test('fresh Android startup uses the accent capsule defaults', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        ytDlpDownloaderServiceProvider.overrideWithValue(
          const _NoopDownloaderService(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);
    final preferences = await SharedPreferences.getInstance();

    expect(settings.surfaceBackgroundMode, SurfaceBackgroundMode.accent);
    expect(settings.miniPlayerMode, MiniPlayerMode.capsule);
    expect(settings.miniPlayerBackgroundMode, MiniPlayerBackgroundMode.accent);
    expect(preferences.containsKey('settings.surfaceBackgroundMode'), isFalse);
    expect(preferences.containsKey('settings.miniPlayerMode'), isFalse);
    expect(
      preferences.containsKey('settings.miniPlayerBackgroundMode'),
      isFalse,
    );
    expect(settings.localMusicFilters, defaultLocalMusicFilters);
    expect(settings.localMusicFilters, {
      LocalMusicFilter.hideWhatsAppAudio,
      LocalMusicFilter.hideTelegramAudio,
      LocalMusicFilter.hideAudioRecordings,
      LocalMusicFilter.hideTracksUnder30Seconds,
    });
    expect(preferences.containsKey('settings.localMusicFilters'), isFalse);
  });

  test('fresh Linux startup uses the classic mini player default', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        ytDlpDownloaderServiceProvider.overrideWithValue(
          const _NoopDownloaderService(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);
    final preferences = await SharedPreferences.getInstance();

    expect(settings.miniPlayerMode, MiniPlayerMode.standard);
    expect(preferences.containsKey('settings.miniPlayerMode'), isFalse);
  });

  test('startup restores the selected local music filters', () async {
    SharedPreferences.setMockInitialValues({
      'settings.localMusicFilters': [
        LocalMusicFilter.hideWhatsAppAudio.code,
        LocalMusicFilter.hideTelegramAudio.code,
        'futureFilter',
      ],
    });
    final container = ProviderContainer(
      overrides: [
        ytDlpDownloaderServiceProvider.overrideWithValue(
          const _NoopDownloaderService(),
        ),
      ],
    );
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);

    expect(settings.localMusicFilters, {
      LocalMusicFilter.hideWhatsAppAudio,
      LocalMusicFilter.hideTelegramAudio,
    });
  });

  test('an explicitly empty local music filter list stays empty', () async {
    SharedPreferences.setMockInitialValues({});
    final firstContainer = ProviderContainer(
      overrides: [
        ytDlpDownloaderServiceProvider.overrideWithValue(
          const _NoopDownloaderService(),
        ),
      ],
    );
    await firstContainer.read(settingsControllerProvider.future);
    await firstContainer
        .read(settingsControllerProvider.notifier)
        .setLocalMusicFilters(const <LocalMusicFilter>{});
    final preferences = await SharedPreferences.getInstance();

    expect(preferences.getStringList('settings.localMusicFilters'), isEmpty);
    firstContainer.dispose();

    final restoredContainer = ProviderContainer(
      overrides: [
        ytDlpDownloaderServiceProvider.overrideWithValue(
          const _NoopDownloaderService(),
        ),
      ],
    );
    addTearDown(restoredContainer.dispose);

    final restored = await restoredContainer.read(
      settingsControllerProvider.future,
    );
    expect(restored.localMusicFilters, isEmpty);
  });

  test(
    'startup preserves an explicitly persisted classic artwork style',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings.surfaceBackgroundMode': 'transparent',
        'settings.miniPlayerMode': 'default',
        'settings.miniPlayerBackgroundMode': 'artwork',
      });
      final container = ProviderContainer(
        overrides: [
          ytDlpDownloaderServiceProvider.overrideWithValue(
            const _NoopDownloaderService(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final settings = await container.read(settingsControllerProvider.future);

      expect(settings.surfaceBackgroundMode, SurfaceBackgroundMode.transparent);
      expect(settings.miniPlayerMode, MiniPlayerMode.standard);
      expect(
        settings.miniPlayerBackgroundMode,
        MiniPlayerBackgroundMode.artwork,
      );
    },
  );

  test(
    'startup quarantines a semantically invalid migration journal',
    () async {
      final currentRoot = p.join(documentsPath, 'BStream-Music');
      final sourceRoot = p.join(sandbox.path, 'migration-source');
      final targetRoot = p.join(sandbox.path, 'migration-target');
      final unrelatedReference = p.join(sandbox.path, 'unrelated-reference');
      for (final path in [sourceRoot, targetRoot, unrelatedReference]) {
        await Directory(path).create(recursive: true);
      }
      SharedPreferences.setMockInitialValues({
        downloadDirectoryKey: currentRoot,
        journalKey: jsonEncode(<String, Object?>{
          'version': 1,
          'sourceRoot': sourceRoot,
          'targetRoot': targetRoot,
          // This is structurally valid but must never be allowed to rewrite
          // database rows belonging to a root other than the source.
          'referenceSourceRoot': unrelatedReference,
        }),
      });

      final container = ProviderContainer(
        overrides: [
          ytDlpDownloaderServiceProvider.overrideWithValue(
            const _NoopDownloaderService(),
          ),
        ],
      );
      addTearDown(container.dispose);

      final settings = await container.read(settingsControllerProvider.future);
      final prefs = await SharedPreferences.getInstance();

      expect(settings.downloadDirectory, p.normalize(currentRoot));
      expect(prefs.containsKey(journalKey), isFalse);
      expect(prefs.getString(downloadDirectoryKey), p.normalize(currentRoot));
      expect(await Directory(p.join(currentRoot, 'audio')).exists(), isTrue);
      expect(
        await Directory(p.join(currentRoot, 'thumbnails')).exists(),
        isTrue,
      );
    },
  );

  test(
    'startup replaces a persisted filesystem root without migrating it',
    () async {
      final filesystemRoot = p.rootPrefix(sandbox.path);
      final expectedRoot = p.normalize(p.join(documentsPath, 'BStream-Music'));
      final database = _BlockingLocalDatabaseService();
      SharedPreferences.setMockInitialValues({
        downloadDirectoryKey: filesystemRoot,
      });

      final container = ProviderContainer(
        overrides: [
          ytDlpDownloaderServiceProvider.overrideWithValue(
            const _NoopDownloaderService(),
          ),
          databaseServiceProvider.overrideWithValue(database),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(database.dispose);

      final settings = await container.read(settingsControllerProvider.future);
      final prefs = await SharedPreferences.getInstance();

      expect(settings.downloadDirectory, expectedRoot);
      expect(prefs.getString(downloadDirectoryKey), expectedRoot);
      expect(prefs.containsKey(journalKey), isFalse);
      expect(database.rewriteCalls, 0);
      expect(await Directory(p.join(expectedRoot, 'audio')).exists(), isTrue);
      expect(
        await Directory(p.join(expectedRoot, 'thumbnails')).exists(),
        isTrue,
      );
    },
  );

  test(
    'directory migration merges its result into the latest settings state',
    () async {
      final currentRoot = p.join(documentsPath, 'BStream-Music');
      final targetRoot = p.join(sandbox.path, 'new-download-root');
      final database = _BlockingLocalDatabaseService();
      SharedPreferences.setMockInitialValues({
        downloadDirectoryKey: currentRoot,
      });

      final container = ProviderContainer(
        overrides: [
          ytDlpDownloaderServiceProvider.overrideWithValue(
            const _NoopDownloaderService(),
          ),
          databaseServiceProvider.overrideWithValue(database),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(database.dispose);
      await container.read(settingsControllerProvider.future);
      final controller = container.read(settingsControllerProvider.notifier);

      final migration = controller.setDownloadDirectory(targetRoot);
      await database.rewriteStarted.future;
      await controller.setThemeMode(AppThemeMode.dark);
      database.allowRewrite.complete();
      await migration;

      final settings = container.read(settingsControllerProvider).requireValue;
      expect(settings.downloadDirectory, p.normalize(targetRoot));
      expect(settings.themeMode, AppThemeMode.dark);
    },
  );

  test('yt-dlp refresh merges into the latest settings state', () async {
    SharedPreferences.setMockInitialValues({});
    final downloader = _BlockingDesktopDownloaderService();
    final container = ProviderContainer(
      overrides: [ytDlpDownloaderServiceProvider.overrideWithValue(downloader)],
    );
    addTearDown(container.dispose);
    addTearDown(downloader.dispose);
    await container.read(settingsControllerProvider.future);
    final controller = container.read(settingsControllerProvider.notifier);

    downloader.blockAvailabilityCheck = true;
    final refresh = controller.refreshToolStatus();
    await downloader.availabilityCheckStarted.future;
    await controller.setThemeMode(AppThemeMode.light);
    downloader.allowAvailabilityCheck.complete();
    await refresh;

    final settings = container.read(settingsControllerProvider).requireValue;
    expect(settings.themeMode, AppThemeMode.light);
    expect(settings.ytDlpPath, 'test-yt-dlp');
    expect(settings.hasYtDlp, isTrue);
  });

  test('yt-dlp path update merges into the latest settings state', () async {
    SharedPreferences.setMockInitialValues({});
    final downloader = _BlockingDesktopDownloaderService();
    final container = ProviderContainer(
      overrides: [ytDlpDownloaderServiceProvider.overrideWithValue(downloader)],
    );
    addTearDown(container.dispose);
    addTearDown(downloader.dispose);
    await container.read(settingsControllerProvider.future);
    final controller = container.read(settingsControllerProvider.notifier);

    downloader.blockAvailabilityCheck = true;
    final update = controller.setYtDlpPath('selected-yt-dlp');
    await downloader.availabilityCheckStarted.future;
    await controller.setThemeMode(AppThemeMode.dark);
    downloader.allowAvailabilityCheck.complete();
    await update;

    final settings = container.read(settingsControllerProvider).requireValue;
    expect(settings.themeMode, AppThemeMode.dark);
    expect(settings.ytDlpPath, 'test-yt-dlp');
    expect(settings.hasYtDlp, isTrue);
  });
}

class _BlockingLocalDatabaseService extends LocalDatabaseService {
  final rewriteStarted = Completer<void>();
  final allowRewrite = Completer<void>();
  int rewriteCalls = 0;

  @override
  Future<LocalTrackMediaRootRewrite> rewriteLocalTrackMediaRootWithSnapshot({
    required String mediaRoot,
    String? oldMediaRoot,
    String? canonicalOldMediaRoot,
  }) async {
    rewriteCalls++;
    if (!rewriteStarted.isCompleted) {
      rewriteStarted.complete();
    }
    await allowRewrite.future;
    return LocalTrackMediaRootRewrite(const <LocalTrackMediaPathSnapshot>[]);
  }
}

class _BlockingDesktopDownloaderService extends DesktopDownloaderService {
  bool blockAvailabilityCheck = false;
  final availabilityCheckStarted = Completer<void>();
  final allowAvailabilityCheck = Completer<void>();

  @override
  Future<String> getYtDlpPath() async => 'test-yt-dlp';

  @override
  Future<void> setYtDlpPath(String? path) async {}

  @override
  Future<bool> hasYtDlp() async {
    if (!blockAvailabilityCheck) {
      return false;
    }
    if (!availabilityCheckStarted.isCompleted) {
      availabilityCheckStarted.complete();
    }
    await allowAvailabilityCheck.future;
    return true;
  }
}

class _NoopDownloaderService implements DownloaderService {
  const _NoopDownloaderService();

  @override
  Stream<DownloadProgress> get progressStream => const Stream.empty();

  @override
  Future<DownloadResult> downloadAudio(String url, DownloadOptions options) =>
      throw UnimplementedError();

  @override
  Future<TrackInfo> getInfo(String url) => throw UnimplementedError();

  @override
  Future<TrackInfo> getPlaybackInfo(String url) => throw UnimplementedError();

  @override
  Future<void> initialize() async {}

  @override
  Future<List<TrackInfo>> search(String query) => throw UnimplementedError();
}
