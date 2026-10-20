import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/artwork_progress_color_provider.dart';
import 'package:bstream_music/features/music/presentation/widgets/app_background_photo.dart';
import 'package:bstream_music/features/music/presentation/widgets/artwork_gradient_header_background.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_gradient_background.dart';
import 'package:bstream_music/features/music/presentation/widgets/source_image.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      '$brightness detail body fades artwork color into its surface',
      (tester) async {
        const artwork = 'https://img.test/detail.jpg';
        const tint = Color(0xFF4DDDB5);
        var requests = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              artworkSurfaceColorProvider(artwork).overrideWith((ref) async {
                requests++;
                return tint;
              }),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ArtworkColorPageBackground(
                      artworkSource: artwork,
                      keyPrefix: 'detail-body',
                    ),
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 180,
                      child: ArtworkGradientHeaderBackground(
                        artworkSource: artwork,
                        cacheWidth: 512,
                        keyPrefix: 'detail-header',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final body = find.byKey(const ValueKey('detail-body-background-color'));
        final surface = Theme.of(tester.element(body)).colorScheme.surface;
        final bodyDecoration =
            tester.widget<DecoratedBox>(body).decoration as BoxDecoration;
        final bodyGradient = bodyDecoration.gradient! as LinearGradient;
        final dark = brightness == Brightness.dark;
        final artworkTone = HSLColor.fromColor(tint);
        Color expectedTone(double lightness, double opacity) =>
            Color.alphaBlend(
              artworkTone
                  .withLightness(lightness)
                  .toColor()
                  .withValues(alpha: opacity),
              surface,
            );
        final expectedColors = [
          expectedTone(dark ? 0.66 : 0.88, dark ? 0.58 : 0.32),
          expectedTone(dark ? 0.52 : 0.72, dark ? 0.44 : 0.24),
          expectedTone(dark ? 0.38 : 0.56, dark ? 0.31 : 0.16),
          expectedTone(dark ? 0.26 : 0.40, dark ? 0.22 : 0.09),
        ];
        expect(bodyGradient.colors, expectedColors);
        expect(bodyGradient.stops, [0, 0.36, 0.72, 1]);
        expect(bodyGradient.colors.first, isNot(surface));
        expect(bodyGradient.colors.first, isNot(bodyGradient.colors.last));
        expect(
          find.descendant(of: body, matching: find.byType(SourceImage)),
          findsNothing,
        );
        final headerGradient =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(
                        const ValueKey('detail-header-background-overlay'),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        expect(headerGradient.gradient!.colors.last, expectedColors.first);
        expect(requests, 1, reason: 'Header and body share the same lookup.');
        expect(tester.takeException(), isNull);
      },
    );
  }

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

  for (final brightness in Brightness.values) {
    testWidgets(
      '$brightness menu backdrop shares the player image and overlay recipe at bounded resolution',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: const Scaffold(
              body: SizedBox(
                width: 390,
                height: 400,
                child: PlaybackArtworkBackdrop(
                  source: '/fixture/cover.png',
                  fallbackSource: '/fixture/offline-cover.png',
                  cacheWidth: 256,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final image = tester.widget<SourceImage>(
          find.byType(SourceImage).first,
        );
        expect(image.source, '/fixture/cover.png');
        expect(image.fallbackSource, '/fixture/offline-cover.png');
        expect(image.cacheWidth, 256);
        expect(
          tester
              .widget<ImageFiltered>(find.byType(ImageFiltered))
              .imageFilter
              .toString(),
          contains('blur(44.0, 44.0'),
        );
        final backdrop = find.byType(PlaybackArtworkBackdrop);
        final context = tester.element(backdrop);
        final decorations = tester.widgetList<DecoratedBox>(
          find.descendant(of: backdrop, matching: find.byType(DecoratedBox)),
        );
        expect(
          decorations.any((box) {
            final decoration = box.decoration;
            return decoration is BoxDecoration &&
                decoration.gradient is LinearGradient &&
                listEquals(
                  (decoration.gradient as LinearGradient).colors,
                  playerPlaybackOverlayColors(context),
                );
          }),
          isTrue,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
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
