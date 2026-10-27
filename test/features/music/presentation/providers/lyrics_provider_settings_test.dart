import 'dart:async';
import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  const key = 'settings.enabledLyricsProviders';
  late Directory sandbox;

  ProviderContainer container() {
    final result = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(
          () => SettingsController.forPlatform(AppPlatformType.ios),
        ),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp(
      'bstream-lyrics-provider-settings-',
    );
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'getApplicationDocumentsDirectory' => sandbox.path,
            _ => null,
          };
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await sandbox.delete(recursive: true);
  });

  test('provider identities and priority are stable', () {
    expect(LyricsProvider.values.map((provider) => provider.code), [
      'betterLyrics',
      'youLyPlus',
      'lrclib',
    ]);
    expect(LyricsProvider.values.map((provider) => provider.label), [
      'Better Lyrics',
      'LyricsPlus',
      'LRCLIB',
    ]);
    expect(LyricsProvider.fromCodes(null), defaultLyricsProviders);
    expect(LyricsProvider.fromCodes(['betterLyrics', 'lrclib']).toList(), [
      LyricsProvider.betterLyrics,
      LyricsProvider.lrclib,
    ]);
  });

  test(
    'existing installs default to all providers without overwriting prefs',
    () async {
      final initial = await container().read(settingsControllerProvider.future);
      expect(initial.enabledLyricsProviders, defaultLyricsProviders);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(key), isFalse);
    },
  );

  test(
    'selected providers persist in priority order and survive restart',
    () async {
      final first = container();
      await first.read(settingsControllerProvider.future);
      final selected = <LyricsProvider>{
        LyricsProvider.betterLyrics,
        LyricsProvider.lrclib,
      };
      final write = first
          .read(settingsControllerProvider.notifier)
          .setEnabledLyricsProviders(selected);
      // Selection is published immediately, before disk preferences complete.
      expect(
        first
            .read(settingsControllerProvider)
            .requireValue
            .enabledLyricsProviders,
        selected,
      );
      selected.clear();
      await write;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(key), ['betterLyrics', 'lrclib']);
      final restarted = await container().read(
        settingsControllerProvider.future,
      );
      expect(restarted.enabledLyricsProviders, {
        LyricsProvider.lrclib,
        LyricsProvider.betterLyrics,
      });
      expect(
        () => restarted.enabledLyricsProviders.add(LyricsProvider.youLyPlus),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'unknown and duplicate stored codes do not enable extra providers',
    () async {
      SharedPreferences.setMockInitialValues({
        key: ['unknown-provider', 'youLyPlus', 'youLyPlus'],
      });
      final selected = await container().read(
        settingsControllerProvider.future,
      );
      expect(selected.enabledLyricsProviders, {LyricsProvider.youLyPlus});
      expect(LyricsProvider.fromCodes(['removed-provider']), isEmpty);
    },
  );

  test(
    'previous provider codes retain exact choices under the new priority',
    () async {
      const previousCodes = ['lrclib', 'youLyPlus'];
      SharedPreferences.setMockInitialValues({key: previousCodes});
      final selected = await container().read(
        settingsControllerProvider.future,
      );
      expect(selected.enabledLyricsProviders.toList(), [
        LyricsProvider.youLyPlus,
        LyricsProvider.lrclib,
      ]);
      expect(
        selected.enabledLyricsProviders.contains(LyricsProvider.betterLyrics),
        isFalse,
      );
      expect(LyricsProvider.youLyPlus.label, 'LyricsPlus');
      // A display-name/priority change must not rewrite users' preferences.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(key), previousCodes);
    },
  );

  test(
    'all providers can be disabled and stay disabled after restart',
    () async {
      final first = container();
      await first.read(settingsControllerProvider.future);
      await first
          .read(settingsControllerProvider.notifier)
          .setEnabledLyricsProviders({});
      expect(
        first
            .read(settingsControllerProvider)
            .requireValue
            .enabledLyricsProviders,
        isEmpty,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(key), isEmpty);
      expect(
        (await container().read(
          settingsControllerProvider.future,
        )).enabledLyricsProviders,
        isEmpty,
      );
    },
  );

  test(
    'rapid toggles preserve the latest state and persisted selection',
    () async {
      final first = container();
      await first.read(settingsControllerProvider.future);
      final controller = first.read(settingsControllerProvider.notifier);
      await Future.wait([
        controller.toggleLyricsProvider(LyricsProvider.lrclib, false),
        controller.toggleLyricsProvider(LyricsProvider.youLyPlus, false),
        controller.toggleLyricsProvider(LyricsProvider.betterLyrics, false),
        controller.toggleLyricsProvider(LyricsProvider.youLyPlus, true),
        controller.toggleLyricsProvider(LyricsProvider.lrclib, true),
        controller.toggleLyricsProvider(LyricsProvider.youLyPlus, false),
      ]);
      expect(
        first
            .read(settingsControllerProvider)
            .requireValue
            .enabledLyricsProviders,
        {LyricsProvider.lrclib},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(key), ['lrclib']);
      expect(
        (await container().read(
          settingsControllerProvider.future,
        )).enabledLyricsProviders,
        {LyricsProvider.lrclib},
      );
    },
  );

  test(
    'toggles awaiting initial load merge instead of restoring stale state',
    () async {
      final pathRequested = Completer<void>();
      final pathReady = Completer<String>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getApplicationDocumentsDirectory') {
              if (!pathRequested.isCompleted) pathRequested.complete();
              return pathReady.future;
            }
            return null;
          });
      final first = container();
      final controller = first.read(settingsControllerProvider.notifier);
      await pathRequested.future;
      final writes = [
        controller.toggleLyricsProvider(LyricsProvider.lrclib, false),
        controller.toggleLyricsProvider(LyricsProvider.youLyPlus, false),
      ];
      pathReady.complete(sandbox.path);
      await Future.wait(writes);
      expect(
        first
            .read(settingsControllerProvider)
            .requireValue
            .enabledLyricsProviders,
        {LyricsProvider.betterLyrics},
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(key), ['betterLyrics']);
    },
  );

  test(
    'provider changes preserve unrelated appearance and lyric settings',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings.themeMode': 'dark',
        'settings.surfaceBackgroundMode': 'liquidGlass',
        'settings.lyricsAlignment': 'centered',
        'settings.lyricsTranslationEnabled': true,
        'settings.showAudioQuality': true,
      });
      final first = container();
      final before = await first.read(settingsControllerProvider.future);
      await first
          .read(settingsControllerProvider.notifier)
          .setEnabledLyricsProviders({LyricsProvider.youLyPlus});
      final after = first.read(settingsControllerProvider).requireValue;
      expect(after.themeMode, AppThemeMode.dark);
      expect(after.surfaceBackgroundMode, SurfaceBackgroundMode.liquidGlass);
      expect(after.lyricsTextAlignment, LyricsTextAlignment.centered);
      expect(after.lyricsTranslationEnabled, isTrue);
      expect(after.showAudioQuality, isTrue);
      expect(after.downloadDirectory, before.downloadDirectory);
      expect(after.lyricsAnimationStyle, before.lyricsAnimationStyle);
      expect(
        after.lyricsRomanizationLanguages,
        before.lyricsRomanizationLanguages,
      );
      expect(after.copyWith(showAudioQuality: false).enabledLyricsProviders, {
        LyricsProvider.youLyPlus,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('settings.themeMode'), 'dark');
      expect(prefs.getString('settings.surfaceBackgroundMode'), 'liquidGlass');
      expect(prefs.getString('settings.lyricsAlignment'), 'centered');
      expect(prefs.getBool('settings.lyricsTranslationEnabled'), isTrue);
      expect(prefs.getBool('settings.showAudioQuality'), isTrue);
    },
  );
}
