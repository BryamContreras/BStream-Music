import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_route_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/audio_routing_menus.dart';
import 'package:bstream_music/services/audio_output/audio_output_service.dart';
import 'package:bstream_music/services/casting/native_cast_client.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Uses actual Android media output/volume/Cast SDK channels, without changing
/// the library or attempting playback on any discovered external receiver.
/// Run with --keep-app-running; install the regular APK afterwards.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real media output volume and receiver discovery', (
    tester,
  ) async {
    final temporary = await getTemporaryDirectory();
    final cover = File('${temporary.path}/bstream-routing-fixture.png');
    final data = await rootBundle.load('assets/icons/bstream_icon.png');
    await cover.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    final track = LocalTrack(
      id: 'routing-fixture',
      title: 'Tu canción favorita',
      artist: 'BStream Music',
      filePath: '/fixture.mp3',
      thumbnailPath: cover.path,
      addedAt: DateTime(2026),
    );
    final container = ProviderContainer(
      overrides: [
        appStringsProvider.overrideWithValue(
          const AppStrings(AppLanguage.spanish),
        ),
        playerControllerProvider.overrideWith(_FixturePlayer.new),
        libraryTracksProvider.overrideWith((_) async => [track]),
      ],
    );
    final output = container.read(audioOutputServiceProvider);
    final original = await output.startWatching();
    expect(original.supported, true);
    expect(
      original.routes.where((route) => route.type == AudioOutputType.speaker),
      isNotEmpty,
    );
    expect(original.volume, inInclusiveRange(0, 1));
    final nativeCast = NativeCastClient();
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(
              brightness: Brightness.dark,
              platform: TargetPlatform.android,
            ),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        key: const ValueKey('open-output'),
                        onPressed: () => showAudioOutputPicker(context, ref),
                        child: const Text('Salida Multimedia'),
                      ),
                      FilledButton(
                        key: const ValueKey('open-cast'),
                        onPressed: () => showCastDevicesMenu(context),
                        child: const Text('Transmitir a'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Flutter cannot tap Android's system output dialog. Check its channels
      // directly; the normal app now opens that dialog without a Flutter sheet.
      final speaker = original.routes.firstWhere(
        (route) => route.type == AudioOutputType.speaker,
      );
      expect(await output.selectRoute(speaker.id), true);
      if (original.volumeAdjustable) {
        final targetVolume = original.volume < .1 ? .2 : original.volume * .7;
        await output.setVolume(targetVolume);
        final changed = await output.getState();
        expect(changed.volume, closeTo(targetVolume, .08));
        await output.setVolume(original.volume);
      }
      await binding.convertFlutterSurfaceToImage();
      await tester.pump(const Duration(milliseconds: 200));
      await binding.takeScreenshot('native-audio-routing-shell');
      await tester.tap(find.byKey(const ValueKey('open-cast')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 4)),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('cast-devices-menu')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(container.read(castCoordinatorProvider).state.connected, false);
      await binding.takeScreenshot('native-cast-devices');
      await tester.tap(find.byKey(const ValueKey('cast-devices-menu-close')));
      await tester.pumpAndSettle();
      expect(container.read(castCoordinatorProvider).state.discovering, false);
      // An unknown device must fail safely, never make the UI claim a cast
      // connection or disturb this phone's media output.
      await nativeCast.initialize();
      if (nativeCast.state.supported) {
        await expectLater(
          nativeCast.connect('nonexistent-bstream-test-receiver'),
          throwsA(isA<PlatformException>()),
        );
      }
      debugPrint(
        'AUDIO_ROUTING_NATIVE_OK routes=${original.routes.length} volume=${original.volume} googleCast=${nativeCast.state.supported}',
      );
    } finally {
      if (original.volumeAdjustable) await output.setVolume(original.volume);
      await nativeCast.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      if (await cover.exists()) await cover.delete();
    }
  });
}

class _FixturePlayer extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => const PlayerSnapshot(
    status: PlayerStatus.paused,
    trackId: 'routing-fixture',
    title: 'Tu canción favorita',
    artist: 'BStream Music',
  );
}
