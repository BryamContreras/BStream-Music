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
            EqualizerSettings(
              enabled: true,
              gainsDb: [i / 2, 4, 0, -1, -2, 2, 1, 0, -3, -4],
            ),
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
        4,
        0,
        -1,
        -2,
        2,
        1,
        0,
        -3,
        -4,
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
    'custom curve survives factory presets and an application restart',
    () async {
      final scope = container();
      await scope.read(settingsControllerProvider.future);
      final controller = scope.read(settingsControllerProvider.notifier);
      await Future.wait([
        controller.setEqualizerBand(0, 4.5),
        controller.setEqualizerBand(3, -2),
        controller.setEqualizerBand(8, 1.5),
      ]);
      final custom = List<double>.of(
        scope.read(settingsControllerProvider).requireValue.equalizer.gainsDb,
      );
      await controller.selectEqualizerPreset(EqualizerPreset.rock);
      await controller.selectEqualizerPreset(EqualizerPreset.bassBoost);
      final encoded =
          jsonDecode(
                (await SharedPreferences.getInstance()).getString(
                  'settings.equalizer',
                )!,
              )
              as Map;
      expect(encoded['gainsDb'], EqualizerPreset.bassBoost.gainsDb);
      expect(encoded['customGainsDb'], custom);

      final restarted = container();
      final restored = await restarted.read(settingsControllerProvider.future);
      expect(restored.equalizerProfiles.customCurve!.gainsDb, custom);
      expect(
        restored.equalizerProfiles.selectedFor(restored.equalizer),
        EqualizerPreset.bassBoost,
      );
      await restarted
          .read(settingsControllerProvider.notifier)
          .selectEqualizerPreset(EqualizerPreset.custom);
      final selected = restarted.read(settingsControllerProvider).requireValue;
      expect(selected.equalizer.gainsDb, custom);
      expect(selected.equalizer.enabled, isTrue);
      expect(
        selected.equalizerProfiles.selectedFor(selected.equalizer),
        EqualizerPreset.custom,
      );
      expect(
        selected.copyWith(showAudioQuality: true).equalizerProfiles,
        selected.equalizerProfiles,
      );
    },
  );

  test(
    'custom selection persists even when its gains match the flat preset',
    () async {
      final scope = container();
      await scope.read(settingsControllerProvider.future);
      final controller = scope.read(settingsControllerProvider.notifier);
      await controller.setEqualizerBand(0, 0);
      await controller.selectEqualizerPreset(EqualizerPreset.custom);
      final active = scope
          .read(settingsControllerProvider)
          .requireValue
          .equalizer;
      final saved = await container().read(settingsControllerProvider.future);
      expect(saved.equalizer, active);
      expect(
        saved.equalizerProfiles.selectedFor(saved.equalizer),
        EqualizerPreset.custom,
      );
      await controller.selectEqualizerPreset(EqualizerPreset.flat);
      final flat = await container().read(settingsControllerProvider.future);
      expect(
        flat.equalizer,
        active,
        reason:
            'Changing only profile selection does not change the DSP settings',
      );
      expect(
        flat.equalizerProfiles.selectedFor(flat.equalizer),
        EqualizerPreset.flat,
      );
    },
  );

  test(
    'legacy custom curves are remembered before switching to a factory preset',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings.equalizer': jsonEncode({
          'enabled': true,
          'gainsDb': [6, -2, 1, 5, -3],
        }),
      });
      final scope = container();
      final initial = await scope.read(settingsControllerProvider.future);
      final original = initial.equalizer.gainsDb;
      final controller = scope.read(settingsControllerProvider.notifier);
      await controller.selectEqualizerPreset(EqualizerPreset.jazz);
      final restarted = container();
      await restarted.read(settingsControllerProvider.future);
      await restarted
          .read(settingsControllerProvider.notifier)
          .selectEqualizerPreset(EqualizerPreset.custom);
      expect(
        restarted
            .read(settingsControllerProvider)
            .requireValue
            .equalizer
            .gainsDb,
        original,
      );
    },
  );

  test(
    'rapid preset changes save the latest manual curve atomically',
    () async {
      final scope = container();
      await scope.read(settingsControllerProvider.future);
      final controller = scope.read(settingsControllerProvider.notifier);
      await Future.wait([
        controller.setEqualizerBand(0, 4),
        controller.selectEqualizerPreset(EqualizerPreset.rock),
        controller.setEqualizerBand(1, -2.5),
        controller.selectEqualizerPreset(EqualizerPreset.bassBoost),
        controller.selectEqualizerPreset(EqualizerPreset.custom),
      ]);
      final expected = List<double>.of(EqualizerPreset.rock.gainsDb)
        ..[1] = -2.5;
      final saved = await container().read(settingsControllerProvider.future);
      expect(saved.equalizer.gainsDb, expected);
      expect(saved.equalizerProfiles.customCurve!.gainsDb, expected);
      expect(
        saved.equalizerProfiles.selectedFor(saved.equalizer),
        EqualizerPreset.custom,
      );
    },
  );

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
      const curve = EqualizerSettings(
        enabled: true,
        gainsDb: [4, 4, 3, 3, 2, 2, 1, 1, 0, -1],
      );
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
      expect(strings.equalizerActive, isNotEmpty);
      expect(strings.equalizerInactive, isNotEmpty);
      expect(strings.equalizerActive, isNot(strings.equalizerInactive));
      expect(
        [for (var band = 0; band < 10; band++) strings.equalizerBandName(band)],
        [
          '31 Hz',
          '62 Hz',
          '125 Hz',
          '250 Hz',
          '500 Hz',
          '1 kHz',
          '2 kHz',
          '4 kHz',
          '8 kHz',
          '16 kHz',
        ],
      );
      for (final preset in EqualizerPreset.values) {
        expect(strings.equalizerPresetName(preset), isNotEmpty);
      }
      if (language != AppLanguage.english) {
        expect(strings.equalizer, isNot('Equalizer'));
        expect(strings.equalizerActive, isNot('Enabled'));
        expect(strings.equalizerInactive, isNot('Disabled'));
        expect(
          strings.equalizerSummary,
          isNot(AppStrings(AppLanguage.english).equalizerSummary),
        );
      }
    }
  });
}
