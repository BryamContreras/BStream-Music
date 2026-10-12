import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/app_background_photo.dart';
import 'package:bstream_music/features/music/presentation/widgets/artwork_gradient_header_background.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_gradient_background.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('custom photo appears only on opted-in browsing tabs', (
    tester,
  ) async {
    Widget browsingBackground({required bool showCustomPhoto}) => ProviderScope(
      overrides: [
        settingsControllerProvider.overrideWith(_PhotoSettingsController.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: BrowsingTabBackground(showCustomPhoto: showCustomPhoto),
        ),
      ),
    );

    await tester.pumpWidget(browsingBackground(showCustomPhoto: true));
    await tester.pump();
    expect(find.byType(AppBackgroundPhoto), findsOneWidget);

    await tester.pumpWidget(browsingBackground(showCustomPhoto: false));
    await tester.pump();
    expect(find.byType(AppBackgroundPhoto), findsNothing);
  });

  testWidgets('custom photo does not replace artwork on detail or player', (
    tester,
  ) async {
    final controller = _BackgroundPlayerController(
      const PlayerSnapshot(status: PlayerStatus.paused),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(() => controller),
          settingsControllerProvider.overrideWith(_PhotoSettingsController.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(child: PlayerPlaybackGradientBackground()),
                Expanded(
                  child: ArtworkGradientHeaderBackground(
                    artworkSource: null,
                    cacheWidth: 640,
                    keyPrefix: 'photo-scope-test',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AppBackgroundPhoto), findsNothing);
    expect(
      find.byKey(const ValueKey('photo-scope-test-background-fallback')),
      findsOneWidget,
    );
  });

  testWidgets('player background changes artwork without a luminance dip', (
    tester,
  ) async {
    const first = PlayerSnapshot(
      status: PlayerStatus.playing,
      trackId: 'background-first',
      thumbnailUrl: 'first-background-cover.jpg',
    );
    const second = PlayerSnapshot(
      status: PlayerStatus.playing,
      trackId: 'background-second',
      thumbnailUrl: 'second-background-cover.jpg',
    );
    final controller = _BackgroundPlayerController(first);

    await tester.pumpWidget(_harness(controller));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 530));

    final transitionFinder = find.byKey(
      const ValueKey('player-background-track-transition'),
    );
    final transition = tester.widget<AnimatedSwitcher>(transitionFinder);
    final outgoingKey = transition.child!.key;
    expect(transition.duration, const Duration(milliseconds: 520));

    controller.emit(second);
    await tester.pump();
    final incomingKey = tester
        .widget<AnimatedSwitcher>(transitionFinder)
        .child!
        .key;
    await tester.pump(const Duration(milliseconds: 260));

    Opacity opacityFor(Key? key) => tester.widget<Opacity>(
      find.ancestor(of: find.byKey(key!), matching: find.byType(Opacity)).first,
    );

    expect(incomingKey, isNot(outgoingKey));
    expect(opacityFor(outgoingKey).opacity, 1);
    expect(opacityFor(incomingKey).opacity, greaterThan(0));
    expect(opacityFor(incomingKey).opacity, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('player background honors reduced motion', (tester) async {
    final controller = _BackgroundPlayerController(
      const PlayerSnapshot(status: PlayerStatus.paused),
    );

    await tester.pumpWidget(_harness(controller, disableAnimations: true));

    final transition = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('player-background-track-transition')),
    );
    expect(transition.duration, Duration.zero);
    expect(transition.reverseDuration, Duration.zero);
  });
}

Widget _harness(
  _BackgroundPlayerController controller, {
  bool disableAnimations = false,
}) {
  return ProviderScope(
    overrides: [playerControllerProvider.overrideWith(() => controller)],
    child: MaterialApp(
      builder: disableAnimations
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: child!,
            )
          : null,
      home: const Scaffold(body: PlayerPlaybackGradientBackground()),
    ),
  );
}

class _BackgroundPlayerController extends PlayerController {
  _BackgroundPlayerController(this.initial);

  final PlayerSnapshot initial;

  @override
  Future<PlayerSnapshot> build() async => initial;

  void emit(PlayerSnapshot snapshot) {
    state = AsyncData(snapshot);
  }
}

class _PhotoSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
    appBackgroundPath: '/tmp/BStream-Music/background.png',
  );
}
