import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/audio_sources/audio_source_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
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
    sandbox = await Directory.systemTemp.createTemp('bstream-audio-settings-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return call.method == 'getApplicationDocumentsDirectory'
              ? sandbox.path
              : null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await sandbox.delete(recursive: true);
  });

  test(
    'existing installs enable Jio with Wi-Fi high and mobile standard',
    () async {
      final state = await container().read(settingsControllerProvider.future);
      expect(state.jioSaavnEnabled, isTrue);
      expect(state.wifiAudioQuality, AudioQualityProfile.high);
      expect(state.mobileAudioQuality, AudioQualityProfile.standard);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('settings.jioSaavnEnabled'), isFalse);
      expect(prefs.containsKey('settings.wifiAudioQuality'), isFalse);
      expect(prefs.containsKey('settings.mobileAudioQuality'), isFalse);
    },
  );

  test('source toggles preserve profiles and survive restart', () async {
    final first = container();
    await first.read(settingsControllerProvider.future);
    final controller = first.read(settingsControllerProvider.notifier);
    await controller.setMobileAudioQuality(AudioQualityProfile.high);
    await controller.setJioSaavnEnabled(false);

    final restored = await container().read(settingsControllerProvider.future);
    expect(restored.jioSaavnEnabled, isFalse);
    expect(restored.wifiAudioQuality, AudioQualityProfile.high);
    expect(restored.mobileAudioQuality, AudioQualityProfile.high);
    final policy = AudioSourcePolicy(
      jioSaavnEnabled: restored.jioSaavnEnabled,
      wifiAudioQuality: restored.wifiAudioQuality,
      mobileAudioQuality: restored.mobileAudioQuality,
    );
    expect(
      policy.profileFor(AudioNetworkKind.wifi),
      AudioQualityProfile.standard,
    );
    expect(
      policy.profileFor(AudioNetworkKind.mobile),
      AudioQualityProfile.standard,
    );

    await controller.setJioSaavnEnabled(true);
    final enabled = first.read(settingsControllerProvider).requireValue;
    expect(enabled.wifiAudioQuality, AudioQualityProfile.high);
    expect(enabled.mobileAudioQuality, AudioQualityProfile.high);
    expect(enabled.copyWith(showAudioQuality: true).jioSaavnEnabled, isTrue);
  });

  test('rapid source and quality selections persist the final state', () async {
    final first = container();
    await first.read(settingsControllerProvider.future);
    final controller = first.read(settingsControllerProvider.notifier);
    await Future.wait([
      controller.setJioSaavnEnabled(false),
      controller.setJioSaavnEnabled(true),
      controller.setJioSaavnEnabled(false),
      controller.setWifiAudioQuality(AudioQualityProfile.standard),
      controller.setWifiAudioQuality(AudioQualityProfile.high),
      controller.setWifiAudioQuality(AudioQualityProfile.standard),
      controller.setMobileAudioQuality(AudioQualityProfile.high),
      controller.setMobileAudioQuality(AudioQualityProfile.standard),
      controller.setMobileAudioQuality(AudioQualityProfile.high),
    ]);
    final state = await container().read(settingsControllerProvider.future);
    expect(state.jioSaavnEnabled, isFalse);
    expect(state.wifiAudioQuality, AudioQualityProfile.standard);
    expect(state.mobileAudioQuality, AudioQualityProfile.high);
  });

  test('unknown stored profiles use each network default', () async {
    SharedPreferences.setMockInitialValues({
      'settings.wifiAudioQuality': 'future-quality',
      'settings.mobileAudioQuality': 'future-quality',
      'settings.jioSaavnEnabled': false,
    });
    final state = await container().read(settingsControllerProvider.future);
    expect(state.jioSaavnEnabled, isFalse);
    expect(state.wifiAudioQuality, AudioQualityProfile.high);
    expect(state.mobileAudioQuality, AudioQualityProfile.standard);
  });

  test('source and quality strings cover every supported language', () {
    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      final labels = [
        strings.audioSources,
        strings.audioSourcesSummary,
        strings.youtubeMusicSourceDescription,
        strings.jioSaavnSourceDescription,
        strings.audioSourceAlwaysEnabled,
        strings.dataSaving,
        strings.dataSavingSummary,
        strings.audioQuality,
        strings.desktopDataSavingSummary,
        strings.mobileNetwork,
        strings.highAudioQuality,
        strings.standardAudioQuality,
        strings.lowAudioQuality,
        strings.improvingAudioQuality,
      ];
      for (final label in labels) {
        expect(label, isNotEmpty);
        expect(label.contains('?'), isFalse);
      }
      if (language != AppLanguage.english) {
        expect(strings.audioSources, isNot('Audio sources'));
        expect(strings.highAudioQuality, isNot('High quality'));
        expect(strings.audioQuality, isNot('Audio quality'));
      }
      expect(strings.wifiNetwork, 'Wi-Fi');
    }
  });
}
