import 'dart:io';

import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_menu_bottom_sheet.dart';
import 'package:bstream_music/features/music/presentation/widgets/playback_gradient_background.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Native rendering check with in-memory state; no audio, library writes or
/// network. Use --keep-app-running with flutter drive to preserve app data.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const capture = bool.fromEnvironment('BSTREAM_NATIVE_SCREENSHOTS');
  testWidgets('artwork-colored menus and queue heart in all player styles', (
    tester,
  ) async {
    var screenshotSurfaceReady = false;
    final directory = await getTemporaryDirectory();
    final cover = File('${directory.path}/bstream-menu-native-fixture.png');
    final coverData = await rootBundle.load('assets/icons/bstream_icon.png');
    await cover.writeAsBytes(
      coverData.buffer.asUint8List(
        coverData.offsetInBytes,
        coverData.lengthInBytes,
      ),
    );
    final track = _track.copyWith(thumbnailPath: cover.path);
    final gradients = <Gradient?>[];
    for (final style in PlayerStyle.values) {
      for (final mode in SurfaceBackgroundMode.values) {
        final container = ProviderContainer(
          overrides: [
            playerControllerProvider.overrideWith(_FixturePlayerController.new),
            settingsControllerProvider.overrideWith(
              _FixtureSettingsController.new,
            ),
            libraryTracksProvider.overrideWith((_) async => [track]),
            playlistsControllerProvider.overrideWith(
              _FixturePlaylistsController.new,
            ),
            favoriteTrackIdsProvider.overrideWith(
              (ref) =>
                  ref
                      .watch(playlistsControllerProvider)
                      .value
                      ?.expand((playlist) => playlist.trackIds)
                      .toSet() ??
                  <String>{},
            ),
            playbackQueueProvider.overrideWith(_FixturePlaybackQueue.new),
            downloadControllerProvider.overrideWith(
              _FixtureDownloadController.new,
            ),
            appStringsProvider.overrideWithValue(
              const AppStrings(AppLanguage.spanish),
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.android,
                brightness: Brightness.dark,
                fontFamily: 'Roboto',
                colorSchemeSeed: AppAccent.purple.seedColor,
                extensions: [
                  const AppAccentTheme(accent: AppAccent.purple),
                  AppSurfaceTheme(backgroundMode: mode),
                ],
              ),
              home: Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF38165C),
                            Color(0xFF0A2339),
                            Color(0xFF193C32),
                          ],
                        ),
                      ),
                    ),
                    PlayerPanel(style: style, drawBackground: false),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('player-menu-control')));
        await tester.pumpAndSettle();
        final menu = find.byKey(const ValueKey('player-options-menu'));
        expect(menu, findsOneWidget);
        for (
          var attempt = 0;
          attempt < 40 &&
              container.read(playbackMenuArtworkColorProvider) == null;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(container.read(playbackMenuArtworkColorProvider), isNotNull);
        await tester.pumpAndSettle();
        expect(
          AppColors.surfaceBackgroundModeFor(tester.element(menu)),
          SurfaceBackgroundMode.accent,
        );
        expect(
          find.byKey(const ValueKey('app-menu-sheet-liquid-glass')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('app-menu-sheet-transparent-backdrop')),
          findsNothing,
        );
        final gradient =
            (tester
                        .widget<AnimatedContainer>(
                          find.byKey(const ValueKey('app-menu-sheet-surface')),
                        )
                        .decoration!
                    as BoxDecoration)
                .gradient;
        gradients.add(gradient);
        expect(
          gradient,
          isNull,
          reason: 'Menus must render the player photograph, not a flat tint.',
        );
        final background = tester.widget<PlaybackArtworkBackdrop>(
          find.byKey(const ValueKey('playback-menu-artwork-background')),
        );
        expect(background.source, cover.path);
        expect(background.cacheWidth, 256);
        expect(
          gradients.toSet(),
          hasLength(1),
          reason:
              'The same cover must retain its menu color for every surface preference.',
        );
        expect(
          find.byKey(const ValueKey('player-menu-playlist')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('player-menu-favorite')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (capture && style == PlayerStyle.appleMusic) {
          if (!screenshotSurfaceReady) {
            await binding.convertFlutterSurfaceToImage();
            screenshotSurfaceReady = true;
          }
          await tester.pump(const Duration(milliseconds: 200));
          await binding.takeScreenshot('artwork-menu-${mode.name}');
        }
        await tester.tap(find.byKey(const ValueKey('player-options-close')));
        await tester.pumpAndSettle();
        expect(menu, findsNothing);
        await tester.tap(find.byKey(const ValueKey('player-queue-toggle')));
        await tester.pumpAndSettle();
        final heart = find.byKey(const ValueKey('queue-favorite-toggle'));
        final close = find.byKey(const ValueKey('queue-close'));
        expect(heart, findsOneWidget);
        expect(tester.getSize(heart), const Size(48, 48));
        expect(
          tester.getCenter(heart).dx,
          lessThan(tester.getCenter(close).dx),
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('queue-current-title')))
              .style
              ?.fontSize,
          16,
        );
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('queue-current-artist')))
              .style
              ?.fontSize,
          14,
        );
        await tester.tap(heart);
        await tester.pumpAndSettle();
        expect(container.read(favoriteTrackIdsProvider), contains(track.id));
        expect(
          find.descendant(
            of: heart,
            matching: find.byIcon(Icons.favorite_rounded),
          ),
          findsOneWidget,
        );
        if (capture &&
            style == PlayerStyle.appleMusic &&
            mode == SurfaceBackgroundMode.accent) {
          await tester.pump(const Duration(milliseconds: 200));
          await binding.takeScreenshot('queue-header-favorite');
        }
        await tester.tap(heart);
        await tester.pumpAndSettle();
        expect(
          container.read(favoriteTrackIdsProvider),
          isNot(contains(track.id)),
        );
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(heart, findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        container.dispose();
      }
    }
  });
}

final _track = LocalTrack(
  id: 'player-menu-fixture',
  title: 'Tu canción favorita',
  artist: 'BStream Music',
  filePath: '/test/player-menu-fixture.m4a',
  addedAt: DateTime(2026),
);

class _FixturePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => PlayerSnapshot(
    status: PlayerStatus.paused,
    trackId: _track.id,
    title: _track.title,
    artist: _track.artist,
    duration: const Duration(minutes: 3),
  );
}

class _FixtureSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: 'BStream-Music',
    language: AppLanguage.spanish,
    animatedArtworkEnabled: false,
  );
}

class _FixtureDownloadController extends DownloadController {
  @override
  Map<String, DownloadTaskState> build() => const {};
}

class _FixturePlaylistsController extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => [];

  @override
  Future<bool> toggleFavorite(String trackId) async {
    final current = state.requireValue;
    final wasFavorite = current.any(
      (playlist) => playlist.trackIds.contains(trackId),
    );
    state = AsyncData(
      wasFavorite
          ? <Playlist>[]
          : [
              Playlist(
                id: Playlist.favoritesId,
                name: 'Favoritos',
                trackIds: [trackId],
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
              ),
            ],
    );
    return !wasFavorite;
  }
}

class _FixturePlaybackQueue extends PlaybackQueueNotifier {
  @override
  PlaybackQueueState build() => PlaybackQueueState(
    entries: [
      PlaybackQueueEntry(
        id: _track.id,
        title: _track.title,
        artist: _track.artist,
        isRemote: false,
      ),
      for (var index = 1; index < 7; index++)
        PlaybackQueueEntry(
          id: 'native-queue-$index',
          title: 'Canción de prueba $index',
          artist: 'Artista de prueba',
          isRemote: false,
        ),
    ],
    currentIndex: 0,
  );
}
