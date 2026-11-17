import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('bstream-eq-settings-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => sandbox.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await sandbox.delete(recursive: true);
  });

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

  test(
    'rapid live changes persist only the final curve and restore on restart',
    () async {
      final first = container();
      await first.read(settingsControllerProvider.future);
      final controller = first.read(settingsControllerProvider.notifier);
      final writes = <Future<void>>[];
      for (var i = 0; i < 25; i++) {
        writes.add(
          controller.setEqualizer(
            EqualizerSettings(enabled: true, gainsDb: [i / 2, 0, -1, 2, 0]),
          ),
        );
      }
      expect(
        first
            .read(settingsControllerProvider)
            .requireValue
            .equalizer
            .gainsDb
            .first,
        12,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('settings.equalizer'), isNull);
      await Future.wait(writes);
      expect(jsonDecode(prefs.getString('settings.equalizer')!)['gainsDb'], [
        12,
        0,
        -1,
        2,
        0,
      ]);
      final restored = await container().read(
        settingsControllerProvider.future,
      );
      expect(
        restored.equalizer,
        first.read(settingsControllerProvider).requireValue.equalizer,
      );
    },
  );

  test('corrupt optional EQ preference cannot block startup', () async {
    SharedPreferences.setMockInitialValues({'settings.equalizer': '{broken'});
    expect(
      (await container().read(
        settingsControllerProvider.future,
      )).equalizer.enabled,
      isFalse,
    );
  });

  test(
    'disposing settings flushes a slider value before its debounce expires',
    () async {
      final scope = ProviderContainer(
        overrides: [
          settingsControllerProvider.overrideWith(
            () => SettingsController.forPlatform(AppPlatformType.ios),
          ),
        ],
      );
      await scope.read(settingsControllerProvider.future);
      const curve = EqualizerSettings(enabled: true, gainsDb: [4, 3, 2, 1, 0]);
      final pending = scope
          .read(settingsControllerProvider.notifier)
          .setEqualizer(curve);
      scope.dispose();
      await pending;
      expect(
        EqualizerSettings.fromMap(
          jsonDecode(
            (await SharedPreferences.getInstance()).getString(
              'settings.equalizer',
            )!,
          ),
        ),
        curve,
      );
    },
  );

  test('equalizer controls and presets cover all app languages', () {
    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      expect(strings.equalizer, isNotEmpty);
      for (final preset in EqualizerPreset.values) {
        expect(strings.equalizerPresetName(preset), isNotEmpty);
      }
      if (language != AppLanguage.english) {
        expect(strings.equalizer, isNot('Equalizer'));
        expect(
          strings.equalizerSummary,
          isNot(AppStrings(AppLanguage.english).equalizerSummary),
        );
      }
    }
  });
}
