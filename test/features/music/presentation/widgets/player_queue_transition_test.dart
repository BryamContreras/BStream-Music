import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _testFavoriteIdsProvider =
    NotifierProvider<_TestFavoriteIdsNotifier, Set<String>>(
      _TestFavoriteIdsNotifier.new,
    );

void main() {
  testWidgets(
    'queue changes update its rail without rebuilding the player surface',
    (tester) async {
      _configureView(tester);
      await tester.pumpWidget(_playerHarness());
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerPanel)),
      );
      final queue = container.read(playbackQueueProvider.notifier);
      final surface = find.byKey(const ValueKey('desktop-player-surface'));
      final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));

      await tester.tap(find.byKey(const ValueKey('queue-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(rail, findsNothing);
      final closedSurface = tester.widget(surface);
      queue.replace(const [
        PlaybackQueueEntry(
          id: 'updated-queue-track',
          title: 'Cola actualizada',
          artist: 'BStream Music',
          isRemote: false,
        ),
      ], 0);
      await tester.pump();
      expect(tester.widget(surface), same(closedSurface));
      expect(rail, findsNothing);

      await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(rail, findsOneWidget);
      expect(find.text('Cola actualizada'), findsWidgets);

      final openSurface = tester.widget(surface);
      queue.replace(const [
        PlaybackQueueEntry(
          id: 'visible-queue-track',
          title: 'Cola visible actualizada',
          artist: 'BStream Music',
          isRemote: false,
        ),
      ], 0);
      await tester.pump();
      expect(tester.widget(surface), same(openSurface));
      expect(find.text('Cola visible actualizada'), findsWidgets);
      expect(find.text('Cola actualizada'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unrelated favorites retain player and queue while current hearts update',
    (tester) async {
      _configureView(tester);
      await tester.pumpWidget(_playerHarness());
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerPanel)),
      );
      final favorites = container.read(_testFavoriteIdsProvider.notifier);
      final surface = find.byKey(const ValueKey('desktop-player-surface'));
      final queueTitle = find.byKey(const ValueKey('queue-current-title'));
      final originalSurface = tester.widget(surface);
      final originalQueueTitle = tester.widget(queueTitle);

      favorites.replace({'another-track'});
      await tester.pump();
      expect(tester.widget(surface), same(originalSurface));
      expect(tester.widget(queueTitle), same(originalQueueTitle));

      favorites.replace({'another-track', 'queue-transition-track'});
      await tester.pump();
      for (final key in ['player-favorite-control', 'queue-favorite-toggle']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byIcon(Icons.favorite_rounded),
          ),
          findsOneWidget,
        );
      }

      favorites.replace({'another-track'});
      await tester.pump();
      for (final key in ['player-favorite-control', 'queue-favorite-toggle']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byIcon(Icons.favorite_border_rounded),
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

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

      expect(railWidth(), closeTo(352, 0.1));
      expect(surfaceWidth(), closeTo(608, 0.1));
      await tester.tap(find.byKey(const ValueKey('queue-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();

      expect(railWidth(), closeTo(0, 0.1));
      expect(surfaceWidth(), closeTo(960, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      expect(railWidth(), closeTo(0, 0.1));
      expect(surfaceWidth(), closeTo(960, 0.1));

      await tester.pump(const Duration(milliseconds: 80));
      final openingFirst = railWidth();
      final openingSurfaceFirst = surfaceWidth();
      expect(openingFirst, inExclusiveRange(0, 352));
      expect(openingSurfaceFirst, inExclusiveRange(608, 960));
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
      expect(railWidth(), closeTo(352, 0.1));
      expect(surfaceWidth(), closeTo(608, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      expect(railWidth(), closeTo(352, 0.1));
      expect(surfaceWidth(), closeTo(608, 0.1));

      await tester.pump(const Duration(milliseconds: 80));
      final closingFirst = railWidth();
      final closingSurfaceFirst = surfaceWidth();
      expect(closingFirst, inExclusiveRange(0, 352));
      expect(closingSurfaceFirst, inExclusiveRange(608, 960));
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
      expect(tester.getSize(switcherFinder).width, closeTo(352, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      expect(rail, findsNothing);
      expect(tester.getSize(switcherFinder).width, closeTo(0, 0.1));
      expect(tester.getSize(surface).width, closeTo(960, 0.1));

      await tester.tap(toggle);
      await tester.pump();
      await tester.pump();
      expect(rail, findsOneWidget);
      expect(tester.getSize(switcherFinder).width, closeTo(352, 0.1));
      expect(tester.getSize(surface).width, closeTo(608, 0.1));
      expect(tester.takeException(), isNull);
    },
  );

  for (final style in PlayerStyle.values) {
    testWidgets('desktop $style opens its queue on the first active mount', (
      tester,
    ) async {
      _configureView(tester);
      await tester.pumpWidget(_playerHarness(style: style));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('desktop-playback-queue-rail')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('queue-current-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'retained desktop player opens on entry and reopens only on reentry',
    (tester) async {
      _configureView(tester);
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await tester.pumpWidget(_playerHarness(active: active));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));
      expect(rail, findsNothing);

      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(rail, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('queue-close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(rail, findsNothing);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerPanel)),
      );
      (container.read(playerControllerProvider.notifier)
              as _TestPlayerController)
          .updateTitle('Otra cancion');
      await tester.pump();
      tester.view.physicalSize = const Size(1000, 620);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Otra cancion'), findsOneWidget);
      expect(rail, findsNothing);

      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(rail, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow desktop opens the queue page without overflowing', (
    tester,
  ) async {
    _configureView(tester);
    tester.view.physicalSize = const Size(720, 600);
    await tester.pumpWidget(_playerHarness());
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));
    final surface = find.byKey(const ValueKey('desktop-player-surface'));
    expect(rail, findsNothing);
    expect(tester.getSize(surface).width, closeTo(720, 0.1));

    await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
    await tester.pumpAndSettle();

    expect(rail, findsNothing);
    expect(find.byKey(const ValueKey('queue-current-title')), findsOneWidget);
    expect(find.text('Siguiente cancion'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('queue-close')));
    await tester.pumpAndSettle();

    expect(surface, findsOneWidget);
    expect(rail, findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform never opens the queue automatically', (
      tester,
    ) async {
      _configureView(tester);
      tester.view.physicalSize = const Size(390, 820);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        _playerHarness(platform: platform, active: active),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();

      final rail = find.byKey(const ValueKey('desktop-playback-queue-rail'));
      expect(rail, findsNothing);
      expect(find.byKey(const ValueKey('queue-current-title')), findsNothing);

      active.value = false;
      await tester.pump();
      active.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(rail, findsNothing);
      expect(find.byKey(const ValueKey('queue-current-title')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
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

Widget _playerHarness({
  bool disableAnimations = false,
  TargetPlatform platform = TargetPlatform.windows,
  PlayerStyle style = defaultPlayerStyle,
  ValueNotifier<bool>? active,
}) {
  return ProviderScope(
    overrides: [
      playerControllerProvider.overrideWith(_TestPlayerController.new),
      playbackQueueProvider.overrideWith(_TestQueueNotifier.new),
      libraryTracksProvider.overrideWith((ref) async => const []),
      favoriteTrackIdsProvider.overrideWith(
        (ref) => ref.watch(_testFavoriteIdsProvider),
      ),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.spanish),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(platform: platform, brightness: Brightness.dark),
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: Scaffold(
        body: active == null
            ? PlayerPanel(drawBackground: false, style: style)
            : ValueListenableBuilder<bool>(
                valueListenable: active,
                builder: (context, isActive, _) => PlayerPanel(
                  drawBackground: false,
                  style: style,
                  active: isActive,
                ),
              ),
      ),
    ),
  );
}

class _TestPlayerController extends PlayerController {
  void updateTitle(String title) {
    state = AsyncData(
      PlayerSnapshot(
        status: PlayerStatus.paused,
        title: title,
        artist: 'BStream Music',
        trackId: 'queue-transition-track',
        duration: const Duration(minutes: 3),
      ),
    );
  }

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

class _TestFavoriteIdsNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void replace(Set<String> ids) => state = Set.unmodifiable(ids);
}
