import 'dart:async';
import 'dart:io';

import 'package:bstream_music/core/platform/app_platform.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_source_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/services/audio_sources/audio_extension.dart';
import 'package:bstream_music/services/audio_sources/audio_extension_resolver.dart';
import 'package:bstream_music/services/audio_sources/audio_source_policy.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/downloader/innertube_download_service.dart';
import 'package:bstream_music/services/jiosaavn/jiosaavn_audio_resolver.dart';
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

  Future<
    ({
      ProviderContainer scope,
      SettingsController controller,
      _ExtensionLookup extensions,
      _JioLookup jioSaavn,
      List<String> attempts,
    })
  >
  prepareSources(List<AudioExtension> installed) async {
    final attempts = <String>[];
    final extensions = _ExtensionLookup(attempts: attempts);
    final jioSaavn = _JioLookup(attempts: attempts);
    addTearDown(extensions.dispose);
    addTearDown(jioSaavn.dispose);
    final scope = container(
      overrides: [
        audioExtensionResolverProvider.overrideWithValue(extensions),
        jioSaavnAudioResolverProvider.overrideWithValue(jioSaavn),
        audioNetworkMonitorProvider.overrideWith(
          (_) => throw StateError('A source lookup inspected connectivity'),
        ),
      ],
    );
    await scope.read(settingsControllerProvider.future);
    final controller = scope.read(settingsControllerProvider.notifier);
    await controller.addAudioExtensions(installed);
    return (
      scope: scope,
      controller: controller,
      extensions: extensions,
      jioSaavn: jioSaavn,
      attempts: attempts,
    );
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

  test('audio extension settings persist across restarts', () async {
    final scope = container();
    await scope.read(settingsControllerProvider.future);
    final controller = scope.read(settingsControllerProvider.notifier);
    final uri = Uri.https('example.com', 'manifest.json');
    await controller.setJioSaavnEnabled(false);
    await controller.addAudioExtension(
      AudioExtension(
        id: 'cd-audio',
        name: 'CD audio',
        manifestUri: uri,
        allowDownloads: false,
      ),
    );
    final enabled = await container().read(settingsControllerProvider.future);
    expect(enabled.audioExtensions.single.manifestUri, uri);
    expect(enabled.hasHighQualityAudioSource, isTrue);
    expect(enabled.hasHighQualityDownloadSource, isFalse);

    await controller.setAudioExtensionEnabled(uri, false);
    final disabled = await container().read(settingsControllerProvider.future);
    expect(disabled.audioExtensions.single.enabled, isFalse);
    expect(disabled.hasHighQualityAudioSource, isFalse);

    await controller.removeAudioExtension(uri);
    final removed = await container().read(settingsControllerProvider.future);
    expect(removed.audioExtensions, isEmpty);
  });

  test(
    'uses a CD add-on before JioSaavn and skips streaming-only downloads',
    () async {
      final extension = _ExtensionLookup();
      final jioSaavn = _JioLookup();
      addTearDown(extension.dispose);
      addTearDown(jioSaavn.dispose);
      final scope = container(
        overrides: [
          audioExtensionResolverProvider.overrideWithValue(extension),
          jioSaavnAudioResolverProvider.overrideWithValue(jioSaavn),
        ],
      );
      await scope.read(settingsControllerProvider.future);
      final controller = scope.read(settingsControllerProvider.notifier);
      await controller.addAudioExtension(
        AudioExtension(
          id: 'cd-audio',
          name: 'CD audio',
          manifestUri: Uri.https('example.com', 'manifest.json'),
          allowDownloads: false,
        ),
      );
      const track = TrackInfo(
        id: 'song',
        title: 'Song',
        artist: 'Artist',
        url: 'song',
      );
      final streaming = scope.read(audioSourceUpgradeLookupProvider);
      final downloads = scope.read(downloadAudioSourceUpgradeLookupProvider);
      expect(
        (await streaming(track))?.source,
        AudioStreamSource.audioExtension,
      );
      expect(extension.lookups, 1);
      expect(jioSaavn.lookups, 0);
      expect((await downloads(track))?.source, AudioStreamSource.jioSaavn);
      expect(extension.lookups, 1);
      expect(jioSaavn.lookups, 1);

      extension.available = false;
      expect((await streaming(track))?.source, AudioStreamSource.jioSaavn);
      expect(extension.lookups, 2);
      expect(jioSaavn.lookups, 2);
    },
  );

  test(
    'tries the chosen extension before other enabled extensions and JioSaavn',
    () async {
      final first = _testExtension('first');
      final preferred = _testExtension('preferred');
      final last = _testExtension('last');
      final fixture = await prepareSources([
        first,
        _testExtension('disabled', enabled: false),
        preferred,
        last,
      ]);
      final lookup = fixture.scope.read(audioSourceUpgradeLookupProvider);
      final preference = AudioSourcePreference.audioExtension(
        preferred.manifestUri,
      );
      Future<AudioStreamSource?> resolve() async =>
          (await lookup(_catalogTrack, sourcePreference: preference))?.source;

      expect(await resolve(), AudioStreamSource.audioExtension);
      expect(fixture.attempts, ['preferred']);

      fixture.attempts.clear();
      fixture.extensions.availableIds = {'disabled', 'last'};
      expect(await resolve(), AudioStreamSource.audioExtension);
      expect(fixture.attempts, ['preferred', 'first', 'last']);

      fixture.attempts.clear();
      fixture.extensions.availableIds = {};
      expect(await resolve(), AudioStreamSource.jioSaavn);
      expect(fixture.attempts, ['preferred', 'first', 'last', 'JioSaavn']);

      fixture.attempts.clear();
      await fixture.controller.setJioSaavnEnabled(false);
      await fixture.controller.setAudioExtensionEnabled(
        preferred.manifestUri,
        false,
      );
      expect(await resolve(), isNull);
      expect(fixture.attempts, ['first', 'last']);
    },
  );

  test('an explicit JioSaavn selection never consults extensions', () async {
    final fixture = await prepareSources([_testExtension('extension')]);
    final lookup = fixture.scope.read(audioSourceUpgradeLookupProvider);
    Future<AudioStreamSource?> resolve() async => (await lookup(
      _catalogTrack,
      sourcePreference: const AudioSourcePreference.jioSaavn(),
    ))?.source;

    expect(await resolve(), AudioStreamSource.jioSaavn);
    expect(fixture.attempts, ['JioSaavn']);

    fixture.attempts.clear();
    fixture.jioSaavn.available = false;
    expect(await resolve(), isNull);
    expect(fixture.attempts, ['JioSaavn']);

    fixture.attempts.clear();
    await fixture.controller.setJioSaavnEnabled(false);
    expect(await resolve(), isNull);
    expect(fixture.attempts, isEmpty);
  });

  test(
    'downloads use their saved priority and skip streaming-only extensions',
    () async {
      final streamingOnly = _testExtension('streaming', allowDownloads: false);
      final first = _testExtension('first');
      final preferred = _testExtension('preferred');
      final fixture = await prepareSources([streamingOnly, first, preferred]);
      final controller = fixture.controller;
      final downloader =
          fixture.scope.read(downloaderServiceProvider)
              as InnerTubeDownloadService;
      Future<AudioStreamSource?> resolve() async =>
          (await downloader.audioUpgrade!(
            _catalogTrack.url,
            _catalogTrack,
            const AudioStreamResolution(
              source: AudioStreamSource.innerTube,
              streamUrl: 'https://yt.example/audio.m4a',
              bitrate: 129000,
            ),
            () => true,
          ))?.source;

      await controller.setWifiAudioQuality(
        AudioQualityProfile.high,
        sourcePreference: const AudioSourcePreference.jioSaavn(),
      );
      await controller.setDownloadAudioQuality(
        AudioQualityProfile.high,
        sourcePreference: AudioSourcePreference.audioExtension(
          preferred.manifestUri,
        ),
      );
      expect(await resolve(), AudioStreamSource.audioExtension);
      expect(fixture.attempts, ['preferred']);

      fixture.attempts.clear();
      fixture.extensions.availableIds = {'streaming', 'preferred'};
      await controller.setDownloadAudioQuality(
        AudioQualityProfile.high,
        sourcePreference: AudioSourcePreference.audioExtension(
          streamingOnly.manifestUri,
        ),
      );
      expect(await resolve(), AudioStreamSource.audioExtension);
      expect(fixture.attempts, ['first', 'preferred']);

      fixture.attempts.clear();
      await controller.setDownloadAudioQuality(
        AudioQualityProfile.high,
        sourcePreference: const AudioSourcePreference.jioSaavn(),
      );
      expect(await resolve(), AudioStreamSource.jioSaavn);
      expect(fixture.attempts, ['JioSaavn']);
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
          downloadAudioSourceUpgradeLookupProvider.overrideWithValue((
            metadata, {
            currentBitrate,
            sourcePreference,
            shouldContinue,
          }) {
            expect(metadata, same(track));
            expect(currentBitrate, baseline.bitrate);
            expect(sourcePreference, const AudioSourcePreference.jioSaavn());
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
      await controller.setDownloadAudioQuality(
        AudioQualityProfile.high,
        sourcePreference: const AudioSourcePreference.jioSaavn(),
      );
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
        strings.addAudioSource,
        strings.audioExtensionUrl,
        strings.audioExtensionUrlHelp,
        strings.audioExtensionInvalidUrl,
        strings.audioExtensionUnavailable,
        strings.audioExtensionUnsupported,
        strings.audioExtensionRestricted,
        strings.audioExtensionStreamingOnly,
        strings.audioExtensionsWithFallback,
        strings.removeAudioSource,
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
        expect(strings.addAudioSource, isNot('Add audio source'));
        expect(
          strings.audioExtensionsWithFallback,
          isNot('Add-ons + YTMusic fallback'),
        );
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

const _catalogTrack = TrackInfo(
  id: 'song',
  title: 'Song',
  artist: 'Artist',
  url: 'song',
);

AudioExtension _testExtension(
  String id, {
  bool enabled = true,
  bool allowDownloads = true,
}) => AudioExtension(
  id: id,
  name: id,
  manifestUri: Uri.https('$id.example', 'manifest.json'),
  enabled: enabled,
  allowDownloads: allowDownloads,
);

class _ExtensionLookup extends AudioExtensionResolver {
  _ExtensionLookup({this.attempts});

  final List<String>? attempts;
  int lookups = 0;
  bool available = true;
  Set<String>? availableIds;

  @override
  Future<AudioStreamResolution?> findUpgrade(
    TrackInfo track, {
    required List<AudioExtension> extensions,
    bool forDownload = false,
    bool Function()? shouldContinue,
  }) async {
    lookups++;
    for (final extension in extensions) {
      if (shouldContinue?.call() == false) return null;
      if (!extension.enabled || (forDownload && !extension.allowDownloads)) {
        continue;
      }
      attempts?.add(extension.id);
      if (!available || availableIds?.contains(extension.id) == false) {
        continue;
      }
      return const AudioStreamResolution(
        source: AudioStreamSource.audioExtension,
        streamUrl: 'https://example.com/audio.flac',
        codec: 'flac',
        sampleRate: 44100,
        bitDepth: 16,
        channels: 2,
      );
    }
    return null;
  }
}

class _JioLookup extends JioSaavnAudioResolver {
  _JioLookup({this.attempts});

  final List<String>? attempts;
  int lookups = 0;
  bool available = true;

  @override
  Future<AudioStreamResolution?> findUpgrade(
    TrackInfo track, {
    int? currentBitrate,
    bool Function()? shouldContinue,
  }) async {
    lookups++;
    attempts?.add('JioSaavn');
    if (!available) return null;
    return const AudioStreamResolution(
      source: AudioStreamSource.jioSaavn,
      streamUrl: 'https://jio.example/audio.m4a',
      bitrate: 320000,
    );
  }
}
