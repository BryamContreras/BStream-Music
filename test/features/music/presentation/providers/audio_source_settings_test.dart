import 'dart:async';
import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_source_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/audio_sources/audio_source_policy.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/innertube_download_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory sandbox;

  ProviderContainer container({List<Override> overrides = const []}) {
    final result = ProviderContainer(
      overrides: [
        settingsControllerProvider.overrideWith(
          () => SettingsController.forPlatform(AppPlatformType.ios),
        ),
        ...overrides,
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
      expect(state.downloadAudioQuality, AudioQualityProfile.high);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('settings.jioSaavnEnabled'), isFalse);
      expect(prefs.containsKey('settings.wifiAudioQuality'), isFalse);
      expect(prefs.containsKey('settings.mobileAudioQuality'), isFalse);
      expect(prefs.getString('settings.downloadAudioQuality'), 'high');
    },
  );

  test('source toggles preserve profiles and survive restart', () async {
    final first = container();
    await first.read(settingsControllerProvider.future);
    final controller = first.read(settingsControllerProvider.notifier);
    await controller.setMobileAudioQuality(AudioQualityProfile.high);
    await controller.setDownloadAudioQuality(AudioQualityProfile.standard);
    await controller.setJioSaavnEnabled(false);

    final restored = await container().read(settingsControllerProvider.future);
    expect(restored.jioSaavnEnabled, isFalse);
    expect(restored.wifiAudioQuality, AudioQualityProfile.high);
    expect(restored.mobileAudioQuality, AudioQualityProfile.high);
    expect(restored.downloadAudioQuality, AudioQualityProfile.standard);
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
    expect(enabled.downloadAudioQuality, AudioQualityProfile.standard);
    expect(enabled.copyWith(showAudioQuality: true).jioSaavnEnabled, isTrue);
  });

  test(
    'download quality inherits Wi-Fi once and persists independently',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings.wifiAudioQuality': 'standard',
        'settings.mobileAudioQuality': 'high',
      });
      final first = container();
      final migrated = await first.read(settingsControllerProvider.future);
      expect(migrated.downloadAudioQuality, AudioQualityProfile.standard);
      await first
          .read(settingsControllerProvider.notifier)
          .setWifiAudioQuality(AudioQualityProfile.high);

      final restored = await container().read(
        settingsControllerProvider.future,
      );
      expect(restored.wifiAudioQuality, AudioQualityProfile.high);
      expect(restored.mobileAudioQuality, AudioQualityProfile.high);
      expect(restored.downloadAudioQuality, AudioQualityProfile.standard);
    },
  );

  test(
    'the download resolver uses only the independent download profile',
    () async {
      const track = TrackInfo(
        id: 'song',
        title: 'Song',
        artist: 'Artist',
        url: 'song',
      );
      const baseline = AudioStreamResolution(
        source: AudioStreamSource.innerTube,
        streamUrl: 'https://yt.example/audio.m4a',
        bitrate: 129000,
      );
      const upgrade = AudioStreamResolution(
        source: AudioStreamSource.jioSaavn,
        streamUrl: 'https://jio.example/audio.m4a',
        bitrate: 320000,
      );
      var lookups = 0;
      final result = Completer<AudioStreamResolution?>();
      final scope = container(
        overrides: [
          audioNetworkMonitorProvider.overrideWith(
            (_) => throw StateError('Download queried the network profile'),
          ),
          audioSourceUpgradeLookupProvider.overrideWithValue((
            metadata, {
            currentBitrate,
            shouldContinue,
          }) {
            expect(metadata, same(track));
            expect(currentBitrate, baseline.bitrate);
            expect(shouldContinue!(), isTrue);
            return ++lookups == 1 ? Future.value(upgrade) : result.future;
          }),
        ],
      );
      await scope.read(settingsControllerProvider.future);
      final controller = scope.read(settingsControllerProvider.notifier);
      final downloader =
          scope.read(downloaderServiceProvider) as InnerTubeDownloadService;
      Future<AudioStreamResolution?> resolve() =>
          downloader.audioUpgrade!(track.url, track, baseline, () => true);

      await controller.setDownloadAudioQuality(AudioQualityProfile.standard);
      expect(await resolve(), isNull);
      expect(lookups, 0);

      await controller.setWifiAudioQuality(AudioQualityProfile.standard);
      await controller.setDownloadAudioQuality(AudioQualityProfile.high);
      expect(await resolve(), same(upgrade));
      expect(lookups, 1);

      final pending = resolve();
      await controller.setJioSaavnEnabled(false);
      result.complete(upgrade);
      expect(await pending, isNull);
      expect(await resolve(), isNull);
      expect(lookups, 2);
      expect(scope.read(downloaderServiceProvider), same(downloader));
    },
  );

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
      controller.setDownloadAudioQuality(AudioQualityProfile.standard),
      controller.setDownloadAudioQuality(AudioQualityProfile.high),
      controller.setDownloadAudioQuality(AudioQualityProfile.standard),
      controller.setMobileAudioQuality(AudioQualityProfile.standard),
      controller.setMobileAudioQuality(AudioQualityProfile.high),
    ]);
    final state = await container().read(settingsControllerProvider.future);
    expect(state.jioSaavnEnabled, isFalse);
    expect(state.wifiAudioQuality, AudioQualityProfile.standard);
    expect(state.mobileAudioQuality, AudioQualityProfile.high);
    expect(state.downloadAudioQuality, AudioQualityProfile.standard);
  });

  test('unknown stored profiles use each network default', () async {
    SharedPreferences.setMockInitialValues({
      'settings.wifiAudioQuality': 'future-quality',
      'settings.mobileAudioQuality': 'future-quality',
      'settings.downloadAudioQuality': 'future-quality',
      'settings.jioSaavnEnabled': false,
    });
    final state = await container().read(settingsControllerProvider.future);
    expect(state.jioSaavnEnabled, isFalse);
    expect(state.wifiAudioQuality, AudioQualityProfile.high);
    expect(state.mobileAudioQuality, AudioQualityProfile.standard);
    expect(state.downloadAudioQuality, AudioQualityProfile.high);
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
        strings.streamingAudio,
        strings.downloads,
        strings.downloadAudioQuality,
        strings.downloadHighQualitySource,
        strings.audioQuality,
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
        expect(strings.streamingAudio, isNot('Streaming audio'));
        expect(strings.downloadAudioQuality, isNot('Download quality'));
        expect(
          strings.downloadHighQualitySource,
          isNot('JioSaavn + YTMusic fallback'),
        );
        expect(
          strings.dataSavingSummary,
          isNot('Set streaming and download quality separately.'),
        );
      }
      expect(strings.wifiNetwork, 'Wi-Fi');
    }
  });
}
