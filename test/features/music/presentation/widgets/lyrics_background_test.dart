import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/playback_artwork_provider.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_background.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_background_selector.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_gradient_background.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'switching lyrics backgrounds shares the playback color and saves the choice',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      const coverColor = Color(0xFF10B8A0);
      final captureKey = GlobalKey();
      final player = _Playback();
      var paletteReads = 0;
      final container = ProviderContainer(
        overrides: [
          settingsControllerProvider.overrideWith(_Settings.new),
          playerControllerProvider.overrideWith(() => player),
          playbackArtworkProvider.overrideWithValue((
            source: null,
            fallback: null,
          )),
          playbackArtworkColorProvider.overrideWith((ref) {
            paletteReads++;
            return coverColor;
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(settingsControllerProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(
                    key: captureKey,
                    child: const LyricsBackground(),
                  ),
                  // A second playback consumer must share the same sample.
                  Consumer(
                    builder: (context, ref, child) {
                      ref.watch(playbackArtworkColorProvider);
                      final settings = ref
                          .watch(settingsControllerProvider)
                          .requireValue;
                      return Align(
                        alignment: Alignment.topCenter,
                        child: LyricsBackgroundSelector(
                          value: settings.lyricsBackgroundStyle,
                          strings: const AppStrings(AppLanguage.spanish),
                          onChanged: ref
                              .read(settingsControllerProvider.notifier)
                              .setLyricsBackgroundStyle,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const ValueKey('lyrics-background-animated-gradient')),
        findsOneWidget,
      );
      final gradient = find.byType(LyricsGradientBackground);
      expect(
        tester.widget<LyricsGradientBackground>(gradient).motionEnabled,
        isTrue,
      );
      player.setStatus(PlayerStatus.paused);
      await tester.pump();
      expect(
        tester.widget<LyricsGradientBackground>(gradient).motionEnabled,
        isFalse,
      );
      player.setStatus(PlayerStatus.playing);
      await tester.pump();
      expect(
        tester.widget<LyricsGradientBackground>(gradient).motionEnabled,
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('lyrics-background-option-blur')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lyrics-background-blur')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('lyrics-background-option-gradient')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lyrics-background-blur')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('lyrics-background-gradient')),
        findsOneWidget,
      );
      expect(find.byType(ImageFiltered), findsNothing);
      expect(paletteReads, 1);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      final samples = await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          Color sample(double x, double y) {
            final pixel =
                ((image.height * y).floor() * image.width +
                    (image.width * x).floor()) *
                4;
            return Color.fromARGB(
              data.getUint8(pixel + 3),
              data.getUint8(pixel),
              data.getUint8(pixel + 1),
              data.getUint8(pixel + 2),
            );
          }

          return (
            center: sample(.5, .5),
            upper: sample(.05, .05),
            lower: sample(.95, .95),
          );
        } finally {
          image.dispose();
        }
      });
      final centerColor = samples!.center;
      expect(centerColor.computeLuminance(), greaterThan(.04));
      expect(
        HSLColor.fromColor(centerColor).hue,
        closeTo(HSLColor.fromColor(coverColor).hue, 3),
      );
      for (final corner in [samples.upper, samples.lower]) {
        expect(
          HSLColor.fromColor(corner).lightness -
              HSLColor.fromColor(centerColor).lightness,
          greaterThan(.07),
          reason:
              'The corner gradients must stand out from the colored center.',
        );
      }
      for (final corner in [samples.upper, samples.lower]) {
        expect(
          HSLColor.fromColor(corner).hue,
          closeTo(HSLColor.fromColor(coverColor).hue, 3),
        );
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('settings.lyricsBackground'), 'gradient');
      await tester.tap(
        find.byKey(const ValueKey('lyrics-background-option-animatedGradient')),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey('lyrics-background-animated-gradient')),
        findsOneWidget,
      );
      expect(prefs.getString('settings.lyricsBackground'), 'animatedGradient');
      expect(find.byType(ImageFiltered), findsNothing);
      expect(paletteReads, 1);
      await tester.tap(
        find.byKey(const ValueKey('lyrics-background-option-blur')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('lyrics-background-blur')),
        findsOneWidget,
      );
      expect(prefs.getString('settings.lyricsBackground'), 'blur');
      expect(paletteReads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test('background choices are translated in all seven app languages', () {
    const english = AppStrings(AppLanguage.english);
    for (final language in AppLanguage.values) {
      final strings = AppStrings(language);
      for (final style in LyricsBackgroundStyle.values) {
        expect(strings.lyricsBackgroundLabel(style), isNotEmpty);
        if (language != AppLanguage.english) {
          expect(
            strings.lyricsBackgroundLabel(style),
            isNot(english.lyricsBackgroundLabel(style)),
          );
        }
      }
      if (language != AppLanguage.english) {
        expect(strings.lyricsBackground, isNot(english.lyricsBackground));
      }
    }
  });
}

class _Settings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
  );
}

class _Playback extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.playing);

  void setStatus(PlayerStatus status) =>
      state = AsyncData(PlayerSnapshot(status: status));
}
