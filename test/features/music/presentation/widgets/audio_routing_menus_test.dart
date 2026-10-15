import 'package:bstream_music/core/widgets/app_menu_bottom_sheet.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_route_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/audio_routing_menus.dart';
import 'package:bstream_music/services/audio_output/audio_output_service.dart';
import 'package:bstream_music/services/casting/cast_coordinator.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _output = AudioOutputState(
  supported: true,
  volume: .6,
  hasSystemPicker: true,
  routes: [
    AudioOutputRoute(
      id: 'speaker',
      name: 'Phone speaker',
      type: AudioOutputType.speaker,
      selected: true,
    ),
    AudioOutputRoute(
      id: 'bt',
      name: 'Audífonos Bluetooth con un nombre muy largo',
      type: AudioOutputType.bluetooth,
    ),
    AudioOutputRoute(
      id: 'wired',
      name: 'Audífonos con cable',
      type: AudioOutputType.wired,
    ),
  ],
);

void main() {
  for (final size in [
    const Size(320, 600),
    const Size(390, 844),
    const Size(600, 320),
  ]) {
    for (final scale in [1.0, 1.8]) {
      for (final menu in ['output', 'cast']) {
        testWidgets('$menu fits $size text scale $scale', (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final output = _Output();
          final cast = _Cast();
          addTearDown(output.dispose);
          addTearDown(cast.dispose);
          await tester.pumpWidget(
            _harness(
              output,
              cast,
              menu == 'output'
                  ? const AudioOutputMenu()
                  : const CastDevicesMenu(),
              scale: scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.text(menu == 'output' ? 'Salida Multimedia' : 'Transmitir a'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (menu == 'cast') expect(cast.discoveries, 1);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          if (menu == 'cast') expect(cast.discoveryStops, 1);
          if (menu == 'output') expect(output.stops, 1);
        });
      }
    }
  }

  testWidgets(
    'system media slider writes once at release, not on every frame',
    (tester) async {
      final output = _Output();
      final cast = _Cast();
      addTearDown(output.dispose);
      addTearDown(cast.dispose);
      await tester.pumpWidget(_harness(output, cast, const AudioOutputMenu()));
      await tester.pumpAndSettle();
      expect(find.text('Este teléfono'), findsOneWidget);
      expect(find.text('Audífonos con cable'), findsOneWidget);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('audio-output-volume')),
      );
      slider.onChanged!(.7);
      slider.onChanged!(.8);
      expect(output.volumes, isEmpty);
      slider.onChangeEnd!(.8);
      await tester.pumpAndSettle();
      expect(output.volumes, [.8]);
      await tester.tap(
        find.byKey(const ValueKey('audio-output-system-picker')),
      );
      await tester.pumpAndSettle();
      expect(output.pickers, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'empty receiver list is honest, refresh does not start playback',
    (tester) async {
      final output = _Output();
      final cast = _Cast();
      addTearDown(output.dispose);
      addTearDown(cast.dispose);
      await tester.pumpWidget(_harness(output, cast, const CastDevicesMenu()));
      await tester.pumpAndSettle();
      expect(
        find.text('No se encontraron dispositivos compatibles.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_rounded), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cast-refresh')));
      await tester.pumpAndSettle();
      expect(cast.discoveries, 2);
      expect(cast.state.connected, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('iOS exposes genuine AirPlay system selector', (tester) async {
    final output = _Output();
    final cast = _Cast();
    addTearDown(output.dispose);
    addTearDown(cast.dispose);
    await tester.pumpWidget(
      _harness(
        output,
        cast,
        const CastDevicesMenu(),
        platform: TargetPlatform.iOS,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cast-airplay-picker')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cast-airplay-picker')));
    await tester.pumpAndSettle();
    expect(output.pickers, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Widget _harness(
  _Output output,
  _Cast cast,
  Widget child, {
  double scale = 1,
  TargetPlatform platform = TargetPlatform.android,
}) => ProviderScope(
  overrides: [
    appStringsProvider.overrideWithValue(const AppStrings(AppLanguage.spanish)),
    audioOutputServiceProvider.overrideWithValue(output),
    castCoordinatorProvider.overrideWithValue(cast),
    playerServiceProvider.overrideWithValue(_IdlePlayer()),
  ],
  child: MaterialApp(
    theme: ThemeData(platform: platform, brightness: Brightness.dark),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AppMenuSheetSurface(artworkColor: Colors.indigo, child: child),
        ),
      ),
    ),
  ),
);

class _Output extends AudioOutputService {
  int stops = 0, pickers = 0;
  final List<double> volumes = [];
  @override
  Future<AudioOutputState> startWatching() async => _output;
  @override
  Future<void> stopWatching() async {
    stops++;
  }

  @override
  Future<void> setVolume(double value) async {
    volumes.add(value);
  }

  @override
  Future<bool> showSystemPicker() async {
    pickers++;
    return true;
  }
}

class _Cast extends CastCoordinator {
  int discoveries = 0, discoveryStops = 0;
  @override
  Future<void> startDiscovery() async {
    discoveries++;
  }

  @override
  Future<void> stopDiscovery() async {
    discoveryStops++;
  }
}

class _IdlePlayer extends Fake implements PlayerService {}
