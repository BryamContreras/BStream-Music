import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/player/just_audio_player_service.dart';
import 'package:bstream_music/services/player/notification_artwork_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/equalizer_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';

/// Shared mobile DSP scenarios. Platform entry points select their native host
/// while keeping presets, handoffs and lifecycle assertions identical.
void registerNativeEqualizerScenarios({required bool supportedPlatform}) {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native BStream DSP keeps both decks configured', (tester) async {
    if (!supportedPlatform) return;
    final directory = await Directory.systemTemp.createTemp(
      'bstream_mobile_eq_',
    );
    final file = File('${directory.path}${Platform.pathSeparator}tone.wav');
    await file.writeAsBytes(_toneWave());
    final primaryEffect = BStreamEqualizer();
    final standbyEffect = BStreamEqualizer();
    final primary = AudioPlayer(
      audioPipeline: _nativePipeline(primaryEffect),
      useProxyForRequestHeaders: false,
    );
    final standby = AudioPlayer(
      audioPipeline: _nativePipeline(standbyEffect),
      useProxyForRequestHeaders: false,
    );
    final artwork = NotificationArtworkService(
      cacheDirectoryProvider: () async => directory,
    );
    final service = JustAudioPlayerService(
      audioPlayer: primary,
      crossfadeAudioPlayer: standby,
      bstreamEqualizerForPlayer: (player) => identical(player, primary)
          ? primaryEffect
          : identical(player, standby)
          ? standbyEffect
          : null,
      notificationArtworkService: artwork,
    );
    LocalTrack track(String id) => LocalTrack(
      id: id,
      title: 'Native EQ fixture',
      artist: 'BStream integration test',
      filePath: file.path,
      duration: const Duration(seconds: 12),
      addedAt: DateTime(2026),
    );
    const boosted = EqualizerSettings(
      enabled: true,
      gainsDb: [8, 8, 6, 4, 0, -2, 1, 3, 5, 6],
    );
    const cut = EqualizerSettings(
      enabled: true,
      gainsDb: [-4, -4, -3, -2, -1, 0, -2, -3, -4, -5],
    );
    const masterVolume = .35;
    try {
      // A saved target must not wait for decoded PCM or the audio session.
      // Inspect native status after playback instead of the optimistic target.
      await service
          .configureEqualizer(boosted)
          .timeout(const Duration(seconds: 1));
      await service.setVolume(masterVolume);
      await service.playLocal(track('first'));
      await _waitUntil(
        () => primary.position > const Duration(milliseconds: 350),
      );
      expect(primaryEffect.supported, isTrue);
      expect(service.supportsEqualizer, isTrue);
      await _waitForNativeSettings(
        tester,
        primaryEffect,
        boosted,
        requireProcessedAudio: true,
      );
      // Headroom is applied inside the DSP before PCM is quantized, rather
      // than attenuating AudioTrack a second time after equalization.
      expect(primary.volume, closeTo(masterVolume, .001));
      expect(service.currentSnapshot.volume, masterVolume);

      final beforeToggle = primary.position;
      await service.configureEqualizer(const EqualizerSettings());
      await _waitForNativeSettings(
        tester,
        primaryEffect,
        const EqualizerSettings(),
      );
      expect(primary.volume, closeTo(masterVolume, .001));
      expect(
        primary.position,
        greaterThanOrEqualTo(beforeToggle - const Duration(milliseconds: 100)),
      );
      expect(primary.playing, isTrue);

      await service.configureEqualizer(cut);
      await _waitForNativeSettings(tester, primaryEffect, cut);
      expect(primary.volume, closeTo(masterVolume, .001));
      await service.pause();
      final pausedAt = primary.position;
      await service.configureEqualizer(boosted);
      expect(primary.playing, isFalse);
      await _waitForNativeSettings(
        tester,
        primaryEffect,
        boosted,
        allowPendingAudio: true,
      );
      await service.resume();
      await _waitUntil(
        () => primary.position > pausedAt + const Duration(milliseconds: 100),
      );
      await _waitForNativeSettings(
        tester,
        primaryEffect,
        boosted,
        requireProcessedAudio: true,
      );

      await service.configureCrossfade(
        enabled: true,
        duration: const Duration(milliseconds: 750),
      );
      await service.pause();
      // An explicit service seek intentionally invalidates a prepared deck.
      // Seek first, then prepare both decks while paused for deterministic checks.
      await service.seek(const Duration(milliseconds: 11300));
      await service.prepareCrossfade(
        LocalCrossfadePlaybackSource(track('second')),
      );
      expect(standbyEffect.supported, isTrue);
      await _waitForNativeSettings(
        tester,
        standbyEffect,
        boosted,
        allowPendingAudio: true,
      );
      expect(standby.volume, 0);

      // A preference change must reach the already prepared physical deck.
      await service.configureEqualizer(cut);
      await _waitForNativeSettings(
        tester,
        primaryEffect,
        cut,
        allowPendingAudio: true,
      );
      await _waitForNativeSettings(
        tester,
        standbyEffect,
        cut,
        allowPendingAudio: true,
      );
      await service.resume();
      await _waitUntil(() => service.currentSnapshot.trackId == 'second');
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      expect(service.currentSnapshot.volume, masterVolume);
      expect(standby.volume, closeTo(masterVolume, .001));
      await _waitForNativeSettings(
        tester,
        standbyEffect,
        cut,
        requireProcessedAudio: true,
      );
      expect(primary.volume, closeTo(0, .001));

      await service.configureEqualizer(const EqualizerSettings());
      await _waitForNativeSettings(
        tester,
        standbyEffect,
        const EqualizerSettings(),
      );
      expect(standby.volume, closeTo(masterVolume, .001));
      await service.stop();
    } finally {
      await service.dispose();
      // The service only owns the injected standby after its first preparation.
      // If an earlier assertion fails, release that still-unused player here.
      await standby.dispose();
      await artwork.dispose();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });

  testWidgets('all UI presets and custom tuning reach the native BStream DSP', (
    tester,
  ) async {
    if (!supportedPlatform) return;
    final directory = await Directory.systemTemp.createTemp(
      'bstream_eq_presets_',
    );
    final file = File('${directory.path}${Platform.pathSeparator}presets.wav');
    await file.writeAsBytes(_toneWave(seconds: 90));
    final effect = BStreamEqualizer();
    final audio = AudioPlayer(
      audioPipeline: _nativePipeline(effect),
      useProxyForRequestHeaders: false,
    );
    final artwork = NotificationArtworkService(
      cacheDirectoryProvider: () async => directory,
    );
    final service = JustAudioPlayerService(
      audioPlayer: audio,
      bstreamEqualizerForPlayer: (_) => effect,
      notificationArtworkService: artwork,
    );
    try {
      await service.setVolume(.15);
      await service.playLocal(
        LocalTrack(
          id: 'native-presets',
          title: 'Equalizer preset test',
          artist: 'BStream',
          filePath: file.path,
          duration: const Duration(seconds: 90),
          addedAt: DateTime(2026),
        ),
      );
      await _waitUntil(
        () => audio.position > const Duration(milliseconds: 200),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playerServiceProvider.overrideWithValue(service),
            settingsControllerProvider.overrideWith(_PresetTestSettings.new),
            appStringsProvider.overrideWithValue(
              const AppStrings(AppLanguage.english),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              platform: Platform.isIOS
                  ? TargetPlatform.iOS
                  : TargetPlatform.android,
            ),
            home: const EqualizerSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scope = ProviderScope.containerOf(
        tester.element(find.byType(EqualizerSettingsPage)),
      );
      for (final preset in EqualizerPreset.values.where(
        (p) => p != EqualizerPreset.custom,
      )) {
        final before = audio.position;
        final selector = find.byKey(const ValueKey('equalizer-presets'));
        await _reveal(tester, selector);
        await tester.tap(selector);
        await tester.pumpAndSettle();
        final option = find.byKey(ValueKey('equalizer-preset-${preset.name}'));
        await _reveal(tester, option);
        await tester.tap(option);
        await tester.pumpAndSettle();
        final settings = scope
            .read(settingsControllerProvider)
            .requireValue
            .equalizer;
        expect(settings.enabled, isTrue);
        expect(settings.gainsDb, preset.gainsDb);
        final status = await _waitForNativeSettings(
          tester,
          effect,
          settings,
          requireProcessedAudio: !settings.isFlat,
        );
        expect(audio.playing, isTrue);
        expect(
          audio.position,
          greaterThanOrEqualTo(before - const Duration(milliseconds: 150)),
        );
        expect(service.currentSnapshot.volume, closeTo(.15, .001));
        expect(audio.volume, closeTo(.15, .001));
        debugPrint(
          'EQ_PRESET_NATIVE ${preset.name}: enabled=${status.enabled} '
          'engine=${status.engine} preampDb=${status.preampDb} '
          'levels=${status.parameters.bands.map((b) => b.gain).toList()} '
          'processedFrames=${status.processedFrames} '
          'revision=${status.revision} appliedRevision=${status.appliedRevision} '
          'positionMs=${audio.position.inMilliseconds}',
        );
      }

      // Exercise a real vertical gesture as well as preset selection. Native
      // readback must preserve half-dB custom values without OEM rounding.
      final band = find.byKey(const ValueKey('equalizer-band-2'));
      await _reveal(tester, band);
      await tester.drag(band, const Offset(0, -35));
      await tester.pumpAndSettle();
      final custom = scope
          .read(settingsControllerProvider)
          .requireValue
          .equalizer;
      expect(custom.preset, EqualizerPreset.custom);
      await _waitForNativeSettings(
        tester,
        effect,
        custom,
        requireProcessedAudio: true,
      );
      final reset = find.byKey(const ValueKey('equalizer-reset'));
      await _reveal(tester, reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await _waitForNativeSettings(
        tester,
        effect,
        const EqualizerSettings(enabled: true),
      );
      expect(audio.volume, closeTo(.15, .001));
      // The normal switch must bypass the engine without discarding its curve.
      await scope
          .read(settingsControllerProvider.notifier)
          .setEqualizer(
            EqualizerSettings(
              enabled: true,
              gainsDb: EqualizerPreset.rock.gainsDb,
            ),
          );
      await _waitForNativeSettings(
        tester,
        effect,
        EqualizerSettings(enabled: true, gainsDb: EqualizerPreset.rock.gainsDb),
      );
      final toggle = find.byKey(const ValueKey('equalizer-enabled'));
      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      final disabled = scope
          .read(settingsControllerProvider)
          .requireValue
          .equalizer;
      expect(disabled.enabled, isFalse);
      expect(disabled.gainsDb, EqualizerPreset.rock.gainsDb);
      await _waitForNativeSettings(tester, effect, disabled);
      expect(audio.volume, closeTo(.15, .001));

      // stop disposes the native player; restarting must restore the saved
      // curve in a new processor rather than an obsolete Dart-only cache.
      await service.stop();
      await service.playLocal(
        LocalTrack(
          id: 'native-presets-restarted',
          title: 'Equalizer restart test',
          artist: 'BStream',
          filePath: file.path,
          duration: const Duration(seconds: 90),
          addedAt: DateTime(2026),
        ),
      );
      await _waitUntil(
        () => audio.position > const Duration(milliseconds: 200),
      );
      await _waitForNativeSettings(tester, effect, disabled);
      await _reveal(tester, toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      await _waitForNativeSettings(
        tester,
        effect,
        EqualizerSettings(enabled: true, gainsDb: EqualizerPreset.rock.gainsDb),
        requireProcessedAudio: true,
      );
      expect(audio.volume, closeTo(.15, .001));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await service.dispose();
      await artwork.dispose();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('native DSP survives a same-recording quality handoff', (
    tester,
  ) async {
    if (!supportedPlatform) return;
    final directory = await Directory.systemTemp.createTemp(
      'bstream_eq_upgrade_',
    );
    final originalFile = File('${directory.path}/original.wav');
    final replacementFile = File('${directory.path}/replacement.wav');
    final wave = _toneWave(seconds: 30);
    await originalFile.writeAsBytes(wave);
    await replacementFile.writeAsBytes(wave);
    final primaryEffect = BStreamEqualizer();
    final standbyEffect = BStreamEqualizer();
    final primary = AudioPlayer(
      audioPipeline: _nativePipeline(primaryEffect),
      useProxyForRequestHeaders: false,
    );
    final standby = AudioPlayer(
      audioPipeline: _nativePipeline(standbyEffect),
      useProxyForRequestHeaders: false,
    );
    final artwork = NotificationArtworkService(
      cacheDirectoryProvider: () async => directory,
    );
    final service = JustAudioPlayerService(
      audioPlayer: primary,
      crossfadeAudioPlayer: standby,
      bstreamEqualizerForPlayer: (player) => identical(player, primary)
          ? primaryEffect
          : identical(player, standby)
          ? standbyEffect
          : null,
      notificationArtworkService: artwork,
    );
    RemotePlaybackSource source(File file, int bitrate) => RemotePlaybackSource(
      track: TrackInfo(
        id: 'native-eq-upgrade',
        title: 'Native EQ quality handoff',
        artist: 'BStream integration test',
        url: 'https://www.youtube.com/watch?v=bstream-eq-fixture',
        streamUrl: file.uri.toString(),
        streamExtension: 'wav',
        streamBitrate: bitrate,
        duration: const Duration(seconds: 30),
      ),
      uri: file.uri,
      queueEntryId: 'native:eq-upgrade',
      isOnlyLogicalQueueItem: true,
    );
    const settings = EqualizerSettings(
      enabled: true,
      gainsDb: [1.5, 1, -1.5, -2.5, 0.5, 3.5, 1, -1.5, 2.5, 4.5],
    );
    try {
      await service.setVolume(.2);
      await service.configureEqualizer(settings);
      // Local transport fixtures exercise the real remote-upgrade path without
      // depending on catalog matching, network responses or decoder downloads.
      await service.playRemoteSource(source(originalFile, 128000));
      await _waitUntil(
        () => primary.position > const Duration(milliseconds: 250),
      );
      await service.seek(const Duration(seconds: 2));
      await _waitUntil(
        () => primary.position >= const Duration(milliseconds: 1900),
      );
      await _waitForNativeSettings(
        tester,
        primaryEffect,
        settings,
        requireProcessedAudio: true,
      );
      final before = primary.position;
      expect(
        await service.upgradeRemoteSource(source(replacementFile, 320000)),
        isTrue,
      );
      await _waitForNativeSettings(
        tester,
        standbyEffect,
        settings,
        requireProcessedAudio: true,
      );
      expect(service.currentSnapshot.trackId, 'native-eq-upgrade');
      expect(service.currentSnapshot.queueEntryId, 'native:eq-upgrade');
      expect(service.currentSnapshot.status, PlayerStatus.playing);
      expect(
        service.currentSnapshot.position,
        greaterThanOrEqualTo(before - const Duration(milliseconds: 150)),
      );
      expect(
        standby.position,
        greaterThanOrEqualTo(before - const Duration(milliseconds: 150)),
      );
      expect(standby.volume, closeTo(.2, .001));
      expect(primary.volume, closeTo(0, .001));
      expect(service.currentSnapshot.volume, .2);
    } finally {
      await service.dispose();
      await standby.dispose();
      await artwork.dispose();
      await directory.delete(recursive: true);
    }
  });
}

/// Read the actual processor state, including decoded-frame activity, rather
/// than relying on a control's optimistic Dart-side target configuration.
/// Paused/prepared decks may accept a target without consuming new PCM. Those
/// checks opt into pending audio, then verify the applied revision after resume.
Future<BStreamEqualizerStatus> _waitForNativeSettings(
  WidgetTester tester,
  BStreamEqualizer effect,
  EqualizerSettings settings, {
  bool requireProcessedAudio = false,
  bool allowPendingAudio = false,
}) async {
  final watch = Stopwatch()..start();
  while (true) {
    await tester.pump(const Duration(milliseconds: 40));
    final status = await effect.readStatus().timeout(
      const Duration(seconds: 2),
    );
    final enabled = settings.enabled && !settings.isFlat;
    final bands = status.parameters.bands;
    final levelsMatch =
        bands.length == equalizerBandFrequencies.length &&
        bands.indexed.every((entry) {
          final (index, band) = entry;
          return band.index == index &&
              (band.centerFrequency - equalizerBandFrequencies[index]).abs() <
                  .001 &&
              (settings.gainsDb[index] - band.gain).abs() <= .011;
        });
    final pendingDarwinAudio =
        Platform.isIOS && allowPendingAudio && !status.configured;
    if (status.supported &&
        status.hasControl &&
        (status.configured || pendingDarwinAudio) &&
        status.enabled == enabled &&
        levelsMatch &&
        (allowPendingAudio ||
            (status.processedFrames > 0 &&
                status.appliedRevision == status.revision)) &&
        (!requireProcessedAudio || status.processedFrames > 0)) {
      expect(status.engine, 'bstream-dsp');
      expect(status.parameters.bands, hasLength(10));
      expect(status.parameters.minDecibels, -12);
      expect(status.parameters.maxDecibels, 12);
      expect(status.preampDb, closeTo(enabled ? settings.preampDb : 0, .011));
      if (!pendingDarwinAudio) {
        if (Platform.isIOS) {
          // Apple may normalize the tap's PCM rate/channel layout to the
          // active route. Require a valid decoded format, not Android enums.
          expect(status.sampleRate, anyOf(44100, 48000));
          expect(status.channelCount, anyOf(1, 2));
          expect(status.pcmEncoding, anyOf(2, 4));
        } else {
          expect(status.sampleRate, 48000);
          expect(status.channelCount, 1);
          // Media3 may retain PCM16 or provide float PCM to its processor.
          expect(status.pcmEncoding, anyOf(2, 4));
        }
      }
      return status;
    }
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail(
        'BStream DSP mismatch: engine=${status.engine} supported=${status.supported} '
        'configured=${status.configured} enabled=${status.enabled} '
        'frames=${status.processedFrames} control=${status.hasControl} '
        'revision=${status.revision} appliedRevision=${status.appliedRevision} '
        'native=${bands.map((b) => b.gain).toList()} '
        'wanted=${settings.gainsDb}',
      );
    }
  }
}

AudioPipeline _nativePipeline(BStreamEqualizer effect) => Platform.isIOS
    ? AudioPipeline(darwinAudioEffects: [effect])
    : AudioPipeline(androidAudioEffects: [effect]);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .3);
  await tester.pumpAndSettle();
}

class _PresetTestSettings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/unused',
    language: AppLanguage.english,
  );
  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {
    state = AsyncData(state.requireValue.copyWith(equalizer: settings));
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 12)) {
      fail('Native equalizer playback timed out.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Uint8List _toneWave({int seconds = 12}) {
  const rate = 48000;
  final samples = rate * seconds;
  final bytes = Uint8List(44 + samples * 2);
  final data = ByteData.sublistView(bytes);
  void ascii(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  ascii(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var sample = 0; sample < samples; sample++) {
    data.setInt16(
      44 + sample * 2,
      (800 * math.sin(2 * math.pi * 910 * sample / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}
