import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
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

  test('iOS reconstructs its media root from the current app container', () {
    expect(
      downloadDirectoryForPlatform(
        platform: AppPlatformType.ios,
        candidateDirectory:
            '/var/mobile/Containers/Data/Application/OLD/Documents/BStream Music',
        defaultDirectory:
            '/var/mobile/Containers/Data/Application/NEW/Documents/BStream Music',
      ),
      '/var/mobile/Containers/Data/Application/NEW/Documents/BStream Music',
    );
    expect(
      downloadDirectoryForPlatform(
        platform: AppPlatformType.android,
        candidateDirectory: '/data/user/0/com.bstream/files/BStream Music',
        defaultDirectory: '/data/user/0/com.bstream/files/default',
      ),
      '/data/user/0/com.bstream/files/BStream Music',
    );
  });

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
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);

    expect(settings.surfaceBackgroundMode, SurfaceBackgroundMode.transparent);
    expect(settings.miniPlayerMode, MiniPlayerMode.capsule);
    expect(
      settings.miniPlayerBackgroundMode,
      MiniPlayerBackgroundMode.transparent,
    );
  });

  test('startup restores persisted Liquid Glass surface backgrounds', () async {
    SharedPreferences.setMockInitialValues({
      'settings.surfaceBackgroundMode': 'liquidGlass',
      'settings.miniPlayerMode': 'capsule',
      'settings.miniPlayerBackgroundMode': 'liquidGlass',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);

    expect(settings.surfaceBackgroundMode, SurfaceBackgroundMode.liquidGlass);
    expect(settings.miniPlayerMode, MiniPlayerMode.capsule);
    expect(
      settings.miniPlayerBackgroundMode,
      MiniPlayerBackgroundMode.liquidGlass,
    );
  });

  test('startup restores and persists the full player style', () async {
    SharedPreferences.setMockInitialValues({
      'settings.playerStyle': 'appleMusic',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);
    expect(settings.playerStyle, PlayerStyle.appleMusic);

    await container
        .read(settingsControllerProvider.notifier)
        .setPlayerStyle(PlayerStyle.bstreamMusic);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('settings.playerStyle'), 'bstreamMusic');
    expect(
      container.read(settingsControllerProvider).value?.playerStyle,
      PlayerStyle.bstreamMusic,
    );
  });

  test(
    'animated artwork defaults on and restores an explicit choice',
    () async {
      SharedPreferences.setMockInitialValues({});
      final freshContainer = ProviderContainer();
      await freshContainer.read(settingsControllerProvider.future);
      final freshPreferences = await SharedPreferences.getInstance();

      expect(
        freshContainer
            .read(settingsControllerProvider)
            .value
            ?.animatedArtworkEnabled,
        isTrue,
      );
      expect(
        freshPreferences.containsKey('settings.animatedArtworkEnabled'),
        isFalse,
      );
      freshContainer.dispose();

      SharedPreferences.setMockInitialValues({
        'settings.animatedArtworkEnabled': false,
      });
      final restoredContainer = ProviderContainer();
      addTearDown(restoredContainer.dispose);

      final restored = await restoredContainer.read(
        settingsControllerProvider.future,
      );
      expect(restored.animatedArtworkEnabled, isFalse);

      await restoredContainer
          .read(settingsControllerProvider.notifier)
          .setAnimatedArtworkEnabled(true);

      final restoredPreferences = await SharedPreferences.getInstance();
      expect(
        restoredPreferences.getBool('settings.animatedArtworkEnabled'),
        isTrue,
      );
      expect(
        restoredContainer
            .read(settingsControllerProvider)
            .value
            ?.animatedArtworkEnabled,
        isTrue,
      );
    },
  );

  test('fresh Android startup uses the accent capsule defaults', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);
    final preferences = await SharedPreferences.getInstance();

    expect(settings.surfaceBackgroundMode, SurfaceBackgroundMode.accent);
    expect(settings.playerStyle, PlayerStyle.bstreamMusic);
    expect(settings.animatedArtworkEnabled, isTrue);
    expect(settings.miniPlayerMode, MiniPlayerMode.capsule);
    expect(settings.miniPlayerBackgroundMode, MiniPlayerBackgroundMode.accent);
    expect(preferences.containsKey('settings.surfaceBackgroundMode'), isFalse);
    expect(preferences.containsKey('settings.playerStyle'), isFalse);
    expect(preferences.containsKey('settings.animatedArtworkEnabled'), isFalse);
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
    final container = ProviderContainer();
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
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final settings = await container.read(settingsControllerProvider.future);

    expect(settings.localMusicFilters, {
      LocalMusicFilter.hideWhatsAppAudio,
      LocalMusicFilter.hideTelegramAudio,
    });
  });

  test('an explicitly empty local music filter list stays empty', () async {
    SharedPreferences.setMockInitialValues({});
    final firstContainer = ProviderContainer();
    await firstContainer.read(settingsControllerProvider.future);
    await firstContainer
        .read(settingsControllerProvider.notifier)
        .setLocalMusicFilters(const <LocalMusicFilter>{});
    final preferences = await SharedPreferences.getInstance();

    expect(preferences.getStringList('settings.localMusicFilters'), isEmpty);
    firstContainer.dispose();

    final restoredContainer = ProviderContainer();
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
      final container = ProviderContainer();
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

      final container = ProviderContainer();
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
    'iOS rebases an unreachable journal instead of recreating its old sandbox',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final oldContainer = p.join(
        sandbox.path,
        '11111111-1111-1111-1111-111111111111',
      );
      final oldRoot = p.join(oldContainer, 'Documents', 'BStream-Music');
      final oldTarget = p.join(oldContainer, 'Documents', 'alternate-media');
      final currentRoot = p.normalize(p.join(documentsPath, 'BStream-Music'));
      final database = _RecordingLocalDatabaseService();
      SharedPreferences.setMockInitialValues({
        downloadDirectoryKey: oldRoot,
        journalKey: jsonEncode(<String, Object?>{
          'version': 1,
          'sourceRoot': oldRoot,
          'targetRoot': oldTarget,
          'referenceSourceRoot': oldRoot,
        }),
      });

      final container = ProviderContainer(
        overrides: [
          settingsControllerProvider.overrideWith(
            () => SettingsController.forPlatform(AppPlatformType.ios),
          ),
          databaseServiceProvider.overrideWithValue(database),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(database.dispose);

      final settings = await container.read(settingsControllerProvider.future);
      final prefs = await SharedPreferences.getInstance();

      expect(settings.downloadDirectory, currentRoot);
      expect(prefs.getString(downloadDirectoryKey), currentRoot);
      expect(prefs.containsKey(journalKey), isFalse);
      expect(database.rewrites, <(String, String?)>[(currentRoot, oldRoot)]);
      expect(await Directory(oldRoot).exists(), isFalse);
      expect(await Directory(oldTarget).exists(), isFalse);
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
        overrides: [databaseServiceProvider.overrideWithValue(database)],
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
        overrides: [databaseServiceProvider.overrideWithValue(database)],
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

class _RecordingLocalDatabaseService extends LocalDatabaseService {
  final rewrites = <(String, String?)>[];

  @override
  Future<void> rewriteLocalTrackMediaRoot({
    required String mediaRoot,
    String? oldMediaRoot,
  }) async {
    rewrites.add((mediaRoot, oldMediaRoot));
  }
}
