import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'desktop queue animates width and opacity while retaining its outgoing rail',
    (tester) async {
      _configureView(tester);
      await tester.pumpWidget(_playerHarness());
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final switcher = find.byKey(
        const ValueKey('desktop-playback-queue-switcher'),
      );
      final surface = find.byKey(const ValueKey('desktop-player-surface'));
      final toggle = find.byKey(const ValueKey('player-queue-toggle'));
      final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));

      double railWidth() => tester.getSize(switcher).width;
      double surfaceWidth() => tester.getSize(surface).width;

      expect(railWidth(), closeTo(0, 0.1));
      expect(surfaceWidth(), closeTo(960, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      expect(railWidth(), closeTo(0, 0.1));
      expect(surfaceWidth(), closeTo(960, 0.1));

      await tester.pump(const Duration(milliseconds: 80));
      final openingFirst = railWidth();
      final openingSurfaceFirst = surfaceWidth();
      expect(openingFirst, inExclusiveRange(0, 320));
      expect(openingSurfaceFirst, inExclusiveRange(640, 960));
      expect(rail, findsOneWidget);
      expect(
        find.ancestor(of: rail, matching: find.byType(ClipRect)),
        findsWidgets,
      );
      final openingFade = tester.widget<FadeTransition>(
        find.ancestor(of: rail, matching: find.byType(FadeTransition)).first,
      );
      expect(openingFade.opacity.value, inExclusiveRange(0, 1));

      await tester.pump(const Duration(milliseconds: 80));
      final openingSecond = railWidth();
      final openingSurfaceSecond = surfaceWidth();
      expect(openingSecond, greaterThan(openingFirst));
      expect(openingSurfaceSecond, lessThan(openingSurfaceFirst));
      expect(rail, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(railWidth(), closeTo(320, 0.1));
      expect(surfaceWidth(), closeTo(640, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      expect(railWidth(), closeTo(320, 0.1));
      expect(surfaceWidth(), closeTo(640, 0.1));

      await tester.pump(const Duration(milliseconds: 80));
      final closingFirst = railWidth();
      final closingSurfaceFirst = surfaceWidth();
      expect(closingFirst, inExclusiveRange(0, 320));
      expect(closingSurfaceFirst, inExclusiveRange(640, 960));
      expect(rail, findsOneWidget);
      final closingFade = tester.widget<FadeTransition>(
        find.ancestor(of: rail, matching: find.byType(FadeTransition)).first,
      );
      expect(closingFade.opacity.value, inExclusiveRange(0, 1));

      await tester.pump(const Duration(milliseconds: 80));
      final closingSecond = railWidth();
      final closingSurfaceSecond = surfaceWidth();
      expect(closingSecond, lessThan(closingFirst));
      expect(closingSurfaceSecond, greaterThan(closingSurfaceFirst));
      expect(rail, findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(rail, findsNothing);
      expect(railWidth(), closeTo(0, 0.1));
      expect(surfaceWidth(), closeTo(960, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop queue transition is immediate when reduced motion is active',
    (tester) async {
      _configureView(tester);
      await tester.pumpWidget(_playerHarness(disableAnimations: true));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final switcherFinder = find.byKey(
        const ValueKey('desktop-playback-queue-switcher'),
      );
      final surface = find.byKey(const ValueKey('desktop-player-surface'));
      final toggle = find.byKey(const ValueKey('player-queue-toggle'));
      final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));
      final switcher = tester.widget<AnimatedSwitcher>(switcherFinder);

      expect(switcher.duration, Duration.zero);
      expect(switcher.reverseDuration, Duration.zero);
      expect(tester.getSize(switcherFinder).width, closeTo(0, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      expect(rail, findsOneWidget);
      expect(tester.getSize(switcherFinder).width, closeTo(320, 0.1));
      expect(tester.getSize(surface).width, closeTo(640, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      expect(rail, findsNothing);
      expect(tester.getSize(switcherFinder).width, closeTo(0, 0.1));
      expect(tester.getSize(surface).width, closeTo(960, 0.1));
      expect(tester.takeException(), isNull);
    },
  );
}

void _configureView(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(960, 600)
    ..devicePixelRatio = 1;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });
}

Widget _playerHarness({bool disableAnimations = false}) {
  return ProviderScope(
    overrides: [
      playerControllerProvider.overrideWith(_TestPlayerController.new),
      playbackQueueProvider.overrideWith(_TestQueueNotifier.new),
      libraryTracksProvider.overrideWith((ref) async => const []),
      favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(
        platform: TargetPlatform.windows,
        brightness: Brightness.dark,
      ),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: const Scaffold(body: PlayerPanel(drawBackground: false)),
    ),
  );
}

class _TestPlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => const PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Cancion de prueba',
    artist: 'BStream Music',
    trackId: 'queue-transition-track',
    duration: Duration(minutes: 3),
  );
}

class _TestQueueNotifier extends PlaybackQueueNotifier {
  @override
  PlaybackQueueState build() => const PlaybackQueueState(
    entries: [
      PlaybackQueueEntry(
        id: 'queue-transition-track',
        title: 'Cancion de prueba',
        artist: 'BStream Music',
        isRemote: false,
      ),
      PlaybackQueueEntry(
        id: 'queue-transition-next',
        title: 'Siguiente cancion',
        artist: 'BStream Music',
        isRemote: false,
      ),
    ],
    currentIndex: 0,
  );
}
