import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mini-player blur decodes a bounded background image', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(_TestPlayerController.new),
          favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const Scaffold(body: SizedBox(height: 80, child: MiniPlayer())),
        ),
      ),
    );
    await tester.pump();

    final blur = find.byType(ImageFiltered);
    expect(blur, findsOneWidget);

    final backgroundImage = find.descendant(
      of: blur,
      matching: find.byType(Image),
    );
    expect(backgroundImage, findsOneWidget);
    final image = tester.widget<Image>(backgroundImage);
    final provider = image.image as ResizeImage;
    expect(provider.width, 320);
  });

  for (final size in const [Size(320, 640), Size(360, 800)]) {
    testWidgets(
      'Android ${size.width.toInt()} px mini-player fills width with only top corners rounded',
      (tester) async {
        _configureView(tester, size, textScaleFactor: 3);
        await tester.pumpWidget(_miniPlayerHarness());
        await tester.pump();

        final frame = find.byKey(const ValueKey('mini-player-frame'));
        final containerFinder = find.byKey(
          const ValueKey('mini-player-container'),
        );
        final surface = find.byKey(const ValueKey('mini-player-surface'));
        final play = find.byKey(const ValueKey('mini-player-primary-control'));
        final metadata = find.byKey(const ValueKey('mini-player-metadata'));
        final progress = find.byKey(const ValueKey('mini-player-progress'));
        final frameRect = tester.getRect(frame);
        final surfaceRect = tester.getRect(surface);
        final playRect = tester.getRect(play);
        final metadataRect = tester.getRect(metadata);
        final progressRect = tester.getRect(progress);

        expect(frameRect.left, closeTo(0, 0.1));
        expect(frameRect.right, closeTo(size.width, 0.1));
        expect(surfaceRect, frameRect);
        expect(progressRect.left, closeTo(frameRect.left, 0.1));
        expect(progressRect.right, closeTo(frameRect.right, 0.1));
        expect(progressRect.bottom, closeTo(frameRect.bottom, 0.1));
        expect(progressRect.height, 3);
        expect(progressRect.top, greaterThanOrEqualTo(playRect.bottom));
        expect(progressRect.top, greaterThanOrEqualTo(metadataRect.bottom));
        expect(frameRect.intersect(progressRect), progressRect);
        expect(tester.getSize(play), const Size.square(48));
        expect(tester.getSize(surface).height, greaterThanOrEqualTo(62));
        final container = tester.widget<Container>(containerFinder);
        final decoration = container.decoration! as BoxDecoration;
        expect(container.clipBehavior, Clip.antiAlias);
        expect(
          decoration.borderRadius,
          const BorderRadius.vertical(top: Radius.circular(10)),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('desktop mini-player keeps progress on its lower edge', (
    tester,
  ) async {
    _configureView(tester, const Size(960, 200));
    await tester.pumpWidget(
      _miniPlayerHarness(platform: TargetPlatform.windows),
    );
    await tester.pump();

    final frameRect = tester.getRect(
      find.byKey(const ValueKey('mini-player-frame')),
    );
    final progressRect = tester.getRect(
      find.byKey(const ValueKey('mini-player-progress')),
    );
    final playRect = tester.getRect(
      find.byKey(const ValueKey('mini-player-primary-control')),
    );
    final metadataRect = tester.getRect(
      find.byKey(const ValueKey('mini-player-metadata')),
    );

    expect(progressRect.left, closeTo(frameRect.left, 0.1));
    expect(progressRect.right, closeTo(frameRect.right, 0.1));
    expect(progressRect.bottom, closeTo(frameRect.bottom, 0.1));
    expect(progressRect.height, 3);
    expect(progressRect.top, greaterThanOrEqualTo(playRect.bottom));
    expect(progressRect.top, greaterThanOrEqualTo(metadataRect.bottom));
    expect(frameRect.intersect(progressRect), progressRect);
    expect(tester.takeException(), isNull);
  });
}

Widget _miniPlayerHarness({TargetPlatform platform = TargetPlatform.android}) {
  return ProviderScope(
    overrides: [
      playerControllerProvider.overrideWith(_TestPlayerController.new),
      favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: platform),
      home: const Scaffold(
        body: Align(alignment: Alignment.topCenter, child: MiniPlayer()),
      ),
    ),
  );
}

void _configureView(
  WidgetTester tester,
  Size size, {
  double textScaleFactor = 1,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScaleFactor;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

class _TestPlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => const PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Canción de prueba',
    artist: 'BStream Music',
    thumbnailUrl: 'https://example.invalid/mini-player-artwork.jpg',
    duration: Duration(minutes: 3),
  );
}
