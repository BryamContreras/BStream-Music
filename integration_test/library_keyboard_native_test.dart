import 'dart:io';
import 'dart:ui' as ui;

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_playlist.dart';
import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/domain/entities/playlist_entry.dart';
import 'package:bstream_music/features/music/presentation/pages/home_page.dart';
import 'package:bstream_music/features/music/presentation/pages/search_view.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/playlist_artwork_mosaic.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/sharing/incoming_track_link_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _useNativeIme = bool.fromEnvironment(
  'BS_TEST_NATIVE_IME',
  defaultValue: true,
);
const _keyboardGlassOnly = bool.fromEnvironment('BS_TEST_KEYBOARD_GLASS_ONLY');

/// Native IME and playlist presentation check using production HomePage.
/// All catalog/settings/player state is in memory. Access to the actual
/// database is explicitly blocked, and generated covers live in one temp dir.
///
/// Build --profile --target=integration_test/library_keyboard_native_test.dart,
/// install manually with adb install -r, launch, forward its VM service, then:
/// VM_SERVICE_URL=... dart run test_driver/library_keyboard_driver.dart
/// Never use an uninstall/clear-data fallback for installation errors.
/// On Android emulators enable: settings put secure show_ime_with_hard_keyboard 1
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native keyboard cycles retain shell, playlist mosaic and navigation',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'bstream_library_keyboard_',
      );
      final fixture = await _Fixture.create(directory);
      final container = _container(fixture);
      final timings = <FrameTiming>[];
      void collect(List<FrameTiming> frames) => timings.addAll(frames);
      addTearDown(() async {
        SchedulerBinding.instance.removeTimingsCallback(collect);
        container.dispose();
        await directory.delete(recursive: true);
      });
      await LiquidGlassSurface.warmUp();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData(
              platform: Platform.isIOS
                  ? TargetPlatform.iOS
                  : TargetPlatform.android,
              brightness: Brightness.dark,
              colorSchemeSeed: AppAccent.blue.seedColor,
              fontFamily: 'Roboto',
              extensions: const [
                AppAccentTheme(accent: AppAccent.blue),
                AppSurfaceTheme(
                  backgroundMode: SurfaceBackgroundMode.liquidGlass,
                ),
              ],
            ),
            home: const HomePage(),
          ),
        ),
      );
      await _settle(tester);
      final viewport = find.byKey(const ValueKey('shell-content-stack'));
      final cycles = <Map<String, Object?>>[];
      SchedulerBinding.instance.addTimingsCallback(collect);

      await _navigate(tester, 1);
      for (var cycle = 0; cycle < (_keyboardGlassOnly ? 1 : 2); cycle++) {
        cycles.add(
          await _keyboardCycleOrTextEntry(
            tester,
            field: find
                .descendant(
                  of: find.byType(SearchView),
                  matching: find.byType(TextField),
                )
                .hitTestable()
                .first,
            viewport: viewport,
            label: 'search-${cycle + 1}',
            useNativeIme: _useNativeIme,
          ),
        );
      }

      if (_keyboardGlassOnly) {
        SchedulerBinding.instance.removeTimingsCallback(collect);
        binding.reportData = {
          'nativeKeyboardGlassTransition': {
            'displayRefreshRateHz': tester.view.display.refreshRate,
            'cycles': cycles,
            'frameTimings': _frameReport(
              timings,
              tester.view.display.refreshRate,
            ),
            'scope': 'One real Android IME open/close cycle on SearchView.',
          },
        };
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }

      await _navigate(tester, 3);
      final row = find.byKey(
        ValueKey('library-playlist-${fixture.playlist.id}'),
      );
      await tester.ensureVisible(row);
      await _settle(tester);
      final rowKey = ValueKey(
        'library-playlist-artwork-${fixture.playlist.id}',
      );
      final originalSources = _mosaicSources(tester, rowKey);
      expect(originalSources, hasLength(4));
      expect(originalSources.toSet(), hasLength(4));
      expect(originalSources.every(fixture.artworkPaths.contains), isTrue);
      await tester.tap(row);
      await _settle(tester);
      final heroKey = ValueKey('library-playlist-hero-${fixture.playlist.id}');
      expect(_mosaicSources(tester, heroKey), originalSources);
      expect(
        find.byKey(const ValueKey('library-playlist-background-photo')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('library-playlist-background-color')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('library-play-all-${fixture.playlist.id}')),
        findsOneWidget,
      );
      await _openPlaylistSearch(tester, fixture.playlist.id);

      for (var cycle = 0; cycle < 2; cycle++) {
        cycles.add(
          await _keyboardCycleOrTextEntry(
            tester,
            field: find.descendant(
              of: find.byKey(const ValueKey('library-filter-surface')),
              matching: find.byType(TextField),
            ),
            viewport: viewport,
            label: 'library-filter-${cycle + 1}',
            useNativeIme: _useNativeIme,
          ),
        );
        expect(_mosaicSources(tester, heroKey), originalSources);
      }

      final searchField = find.descendant(
        of: find.byKey(const ValueKey('library-filter-surface')),
        matching: find.byType(TextField),
      );
      _setFieldText(tester, searchField, 'Artista de prueba 3');
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('library-catalog-entry-native-entry-2')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('library-filter-clear-or-close')),
      );
      await _settle(tester);
      expect(searchField, findsOneWidget);
      expect(tester.widget<TextField>(searchField).controller!.text, isEmpty);

      await _backFromPlaylist(tester);
      await _settle(tester);
      expect(searchField, findsNothing);
      await _backFromPlaylist(tester);
      await tester.ensureVisible(row);
      await _settle(tester);
      final rotatedSources = _mosaicSources(tester, rowKey);
      expect(rotatedSources, hasLength(4));
      expect(rotatedSources.first, isNot(originalSources.first));
      for (var cycle = 0; cycle < 2; cycle++) {
        final fullHeight = tester.getSize(viewport).height;
        await tester.tap(
          find.byKey(const ValueKey('library-create-playlist-button')),
        );
        await tester.pump();
        cycles.add(
          await _keyboardCycleOrTextEntry(
            tester,
            field: find.byKey(const ValueKey('create-playlist-name')),
            viewport: viewport,
            label: 'create-playlist-dialog-${cycle + 1}',
            restingHeight: fullHeight,
            useNativeIme: _useNativeIme,
            close: () async {
              await tester.tap(
                find.byKey(const ValueKey('create-playlist-cancel')),
              );
            },
          ),
        );
        expect(
          find.byKey(const ValueKey('create-playlist-name')),
          findsNothing,
        );
      }
      // A successful cross-tab roundtrip after six native keyboard cycles
      // catches stale modal barriers and focus/input capture regressions.
      await _navigate(tester, 0);
      await _navigate(tester, 3);
      await tester.ensureVisible(row);
      await _settle(tester);
      final revisitSources = _mosaicSources(tester, rowKey);
      expect(revisitSources.first, isNot(rotatedSources.first));
      await tester.tap(row);
      await _settle(tester);
      expect(_mosaicSources(tester, heroKey), revisitSources);
      await tester.pump(const Duration(milliseconds: 250));
      SchedulerBinding.instance.removeTimingsCallback(collect);
      final refreshRate = tester.view.display.refreshRate;
      expect(
        timings,
        isNotEmpty,
        reason: 'Native Flutter timings were not captured.',
      );
      binding.reportData = {
        'nativeLibraryKeyboard': {
          'platform': Platform.operatingSystem,
          'displayRefreshRateHz': refreshRate,
          'scope': _useNativeIme
              ? 'Production HomePage, in-memory catalog and native IME. '
                    'Emulator timing is descriptive; it is not physical-device FPS.'
              : 'Production HomePage, in-memory catalog and controller-driven text entry. '
                    'Native IME is not measured in this run.',
          'keyboardCycles': cycles,
          'frameTimings': _frameReport(timings, refreshRate),
          'mosaic': {
            'sourceCount': originalSources.length,
            'rowMatchesDetail': true,
            'stableDuringKeyboard': true,
            'rotatesOnReturn': true,
            'rotatesOnTabRevisit': true,
            'allSourcesLocal': true,
          },
        },
      };
      expect(tester.takeException(), isNull);

      // Native screenshots are taken only after timing collection stops.
      // Android's Flutter-surface conversion changes composition and should
      // not be mixed into the keyboard performance sample.
      if (Platform.isAndroid) await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      await binding.takeScreenshot('playlist-detail-four-covers');
      await _backFromPlaylist(tester);
      await tester.ensureVisible(row);
      await _settle(tester);
      await binding.takeScreenshot('library-playlist-four-covers');
      await _navigate(tester, 1);
      final screenshotSearchField = find
          .descendant(
            of: find.byType(SearchView),
            matching: find.byType(TextField),
          )
          .hitTestable()
          .first;
      if (_useNativeIme) {
        await binding.takeScreenshot('search-before-keyboard');
        await tester.tap(screenshotSearchField);
        await _waitUntil(
          tester,
          () => tester.view.viewInsets.bottom > 0,
          'Native keyboard did not reopen for screenshot.',
        );
        await _settle(tester);
        await binding.takeScreenshot('search-native-keyboard');
        FocusManager.instance.primaryFocus?.unfocus();
        await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        await _waitUntil(
          tester,
          () => tester.view.viewInsets.bottom == 0,
          'Native keyboard did not dismiss after screenshot.',
        );
      } else {
        _setFieldText(tester, screenshotSearchField, 'emulator smoke test');
        await _settle(tester);
        await binding.takeScreenshot('search-test-input');
        FocusManager.instance.primaryFocus?.unfocus();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<Map<String, Object?>> _keyboardCycle(
  WidgetTester tester, {
  required Finder field,
  required Finder viewport,
  required String label,
  double? restingHeight,
  Future<void> Function()? close,
}) async {
  final fullHeight = restingHeight ?? tester.getSize(viewport).height;
  final stopwatch = Stopwatch()..start();
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pump();
  expect(
    FocusManager.instance.primaryFocus?.hasFocus,
    isTrue,
    reason:
        '$label: the tapped field must own focus before requesting the IME.',
  );
  await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  await _waitUntil(
    tester,
    () => tester.view.viewInsets.bottom > 0,
    '$label: real IME did not appear. Enable show_ime_with_hard_keyboard.',
  );
  await tester.pump();
  _expectNavigationGlassPaused(tester, label);
  await _settle(tester);
  _expectNavigationGlassRestored(tester, label);
  final openedAt = stopwatch.elapsedMilliseconds;
  final inset = tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
  final resizedHeight = tester.getSize(viewport).height;
  expect(
    resizedHeight,
    lessThan(fullHeight - 40),
    reason: '$label: the focused viewport must resize above the native IME.',
  );
  expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
  final closeWatch = Stopwatch()..start();
  if (close != null) await close();
  FocusManager.instance.primaryFocus?.unfocus();
  await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  await _waitUntil(
    tester,
    () => tester.view.viewInsets.bottom == 0,
    '$label: IME did not dismiss.',
  );
  await tester.pump();
  _expectNavigationGlassPaused(tester, '$label close');
  await _settle(tester);
  _expectNavigationGlassRestored(tester, '$label close');
  final closedAt = closeWatch.elapsedMilliseconds;
  final restoredHeight = tester.getSize(viewport).height;
  expect(restoredHeight, closeTo(fullHeight, 1));
  expect(tester.takeException(), isNull);
  return {
    'surface': label,
    'restingHeightDp': fullHeight,
    'keyboardInsetDp': inset,
    'openedHeightDp': resizedHeight,
    'restoredHeightDp': restoredHeight,
    'openObservedMsIncludingSettle': openedAt,
    'closeObservedMsIncludingSettle': closedAt,
    'glassPausedAndRestoredDuringOpen': true,
    'glassPausedAndRestoredDuringClose': true,
  };
}

void _expectNavigationGlassPaused(WidgetTester tester, String label) {
  final navigation = find.byKey(const ValueKey('bottom-navigation-glass'));
  expect(
    navigation,
    findsOneWidget,
    reason: '$label: glass surface is mounted',
  );
  expect(
    find.descendant(of: navigation, matching: find.byType(BackdropFilter)),
    findsNothing,
    reason: '$label: expensive live glass pauses while the IME is moving',
  );
}

void _expectNavigationGlassRestored(WidgetTester tester, String label) {
  final navigation = find.byKey(const ValueKey('bottom-navigation-glass'));
  expect(
    find.descendant(of: navigation, matching: find.byType(BackdropFilter)),
    findsOneWidget,
    reason: '$label: full Liquid Glass returns when the IME settles',
  );
}

Future<Map<String, Object?>> _keyboardCycleOrTextEntry(
  WidgetTester tester, {
  required Finder field,
  required Finder viewport,
  required String label,
  required bool useNativeIme,
  double? restingHeight,
  Future<void> Function()? close,
}) {
  if (useNativeIme) {
    return _keyboardCycle(
      tester,
      field: field,
      viewport: viewport,
      label: label,
      restingHeight: restingHeight,
      close: close,
    );
  }
  return _textEntryCycle(
    tester,
    field: field,
    viewport: viewport,
    label: label,
    restingHeight: restingHeight,
    close: close,
  );
}

Future<Map<String, Object?>> _textEntryCycle(
  WidgetTester tester, {
  required Finder field,
  required Finder viewport,
  required String label,
  double? restingHeight,
  Future<void> Function()? close,
}) async {
  final fullHeight = restingHeight ?? tester.getSize(viewport).height;
  final stopwatch = Stopwatch()..start();
  await tester.ensureVisible(field);
  await tester.tap(field);
  _setFieldText(tester, field, 'test-$label');
  await _settle(tester);
  final enteredAt = stopwatch.elapsedMilliseconds;
  expect(tester.widget<TextField>(field).controller!.text, 'test-$label');
  if (close != null) {
    await close();
  } else {
    _setFieldText(tester, field, '');
  }
  FocusManager.instance.primaryFocus?.unfocus();
  await _settle(tester);
  expect(tester.getSize(viewport).height, closeTo(fullHeight, 1));
  expect(tester.takeException(), isNull);
  return {
    'surface': label,
    'inputMode': 'textControllerTestEntry',
    'restingHeightDp': fullHeight,
    'textEntryObservedMsIncludingSettle': enteredAt,
  };
}

void _setFieldText(WidgetTester tester, Finder field, String text) {
  final controller = tester.widget<TextField>(field).controller;
  if (controller == null) {
    throw StateError('The test text field must expose its controller.');
  }
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
}

Future<void> _navigate(WidgetTester tester, int index) async {
  final destination = find.byKey(ValueKey('bottom-navigation-item-$index'));
  await tester.tap(destination);
  await _settle(tester);
}

Future<void> _backFromPlaylist(WidgetTester tester) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('library-detail-header')),
      matching: find.byIcon(Icons.arrow_back_rounded),
    ),
  );
  await _settle(tester);
}

Future<void> _openPlaylistSearch(WidgetTester tester, String playlistId) async {
  final header = find.byKey(const ValueKey('library-detail-header'));
  await tester.tap(
    find.descendant(of: header, matching: find.byIcon(Icons.more_vert_rounded)),
  );
  await _settle(tester);
  final searchItem = find.byKey(ValueKey('playlist-search-$playlistId'));
  expect(searchItem, findsOneWidget);
  await tester.tap(searchItem);
  await _settle(tester);
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('library-filter-surface')),
      matching: find.byType(TextField),
    ),
    findsOneWidget,
  );
}

List<String> _mosaicSources(WidgetTester tester, Key key) {
  final artwork = find.byKey(key);
  final mosaic = tester.widget(artwork) is PlaylistArtworkMosaic
      ? artwork
      : find.descendant(
          of: artwork,
          matching: find.byType(PlaylistArtworkMosaic),
        );
  return tester
      .widget<PlaylistArtworkMosaic>(mosaic)
      .sources
      .map((source) => source.source)
      .toList(growable: false);
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready,
  String diagnostic,
) async {
  final watch = Stopwatch()..start();
  while (!ready() && watch.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: diagnostic);
}

Future<void> _settle(WidgetTester tester) async {
  // A retained Liquid Glass menu can keep paint-only animation tickers alive;
  // pumpAndSettle would measure their lifetime, not just the IME transition.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
}

Map<String, Object> _frameReport(List<FrameTiming> frames, double refreshRate) {
  Map<String, Object> durations(Iterable<Duration> samples) {
    final millis = samples.map((value) => value.inMicroseconds / 1000).toList()
      ..sort();
    double percentile(double fraction) =>
        millis.isEmpty ? 0 : millis[((millis.length - 1) * fraction).round()];
    return {
      'p50Ms': percentile(0.5),
      'p90Ms': percentile(0.9),
      'p99Ms': percentile(0.99),
      'maxMs': millis.isEmpty ? 0 : millis.last,
    };
  }

  final budget = 1000 / (refreshRate > 0 ? refreshRate : 60);
  return {
    'renderedFlutterFrames': frames.length,
    'displayBudgetMs': budget,
    'build': durations(frames.map((frame) => frame.buildDuration)),
    'raster': durations(frames.map((frame) => frame.rasterDuration)),
    'buildOverDisplayBudget': frames
        .where((frame) => frame.buildDuration.inMicroseconds / 1000 > budget)
        .length,
    'rasterOverDisplayBudget': frames
        .where((frame) => frame.rasterDuration.inMicroseconds / 1000 > budget)
        .length,
  };
}

ProviderContainer _container(_Fixture fixture) => ProviderContainer(
  overrides: [
    databaseServiceProvider.overrideWith((_) {
      throw StateError('Native fixture must not access the user database.');
    }),
    downloaderWarmupProvider.overrideWith((_) async {}),
    localLibraryReconciliationProvider.overrideWith(
      (_) async => LocalLibraryReconciliationResult.empty,
    ),
    settingsControllerProvider.overrideWith(_FixtureSettings.new),
    playerControllerProvider.overrideWith(_FixturePlayer.new),
    downloadControllerProvider.overrideWith(_FixtureDownloads.new),
    tiktokLiveControllerProvider.overrideWith(_FixtureLive.new),
    playlistsControllerProvider.overrideWith(
      () => _FixturePlaylists(fixture.playlist),
    ),
    catalogPlaylistsProvider.overrideWith((_) async => [fixture.catalog]),
    catalogPlaylistProvider.overrideWith(
      (_, id) async => id == fixture.playlist.id ? fixture.catalog : null,
    ),
    libraryTracksProvider.overrideWith((_) async => fixture.tracks),
    historyProvider.overrideWith((_) async => const <LocalTrack>[]),
    favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
    desktopMediaSessionProvider.overrideWithValue(null),
    personalizedHomeFeedSourceProvider.overrideWithValue(null),
    homeArtistRecommendationSourceProvider.overrideWithValue(null),
    youtubeMusicHomeRecommendationsProvider.overrideWith((_) async => const []),
    youtubeMusicAuthControllerProvider.overrideWith(_FixtureAuth.new),
    youtubeMusicSearchSuggestionsProvider.overrideWithValue(null),
    searchBrowseCatalogProvider.overrideWith(
      (_) async => SearchBrowseCatalog(
        categories: const [],
        usesLiveYouTubeMusicCategories: false,
      ),
    ),
    searchBrowseCachedCatalogProvider.overrideWith((_) async => null),
    incomingTrackLinkServiceProvider.overrideWithValue(const _EmptyLinks()),
    androidExternalAudioRequestsProvider.overrideWithValue(null),
    androidAppActivationsProvider.overrideWithValue(null),
    appStringsProvider.overrideWithValue(const AppStrings(AppLanguage.spanish)),
  ],
);

final class _Fixture {
  _Fixture({
    required this.playlist,
    required this.catalog,
    required this.tracks,
    required this.artworkPaths,
  });

  final Playlist playlist;
  final CatalogPlaylist catalog;
  final List<LocalTrack> tracks;
  final List<String> artworkPaths;

  static Future<_Fixture> create(Directory directory) async {
    const colors = [
      Color(0xFFE53935),
      Color(0xFFFB8C00),
      Color(0xFFFDD835),
      Color(0xFF43A047),
      Color(0xFF00ACC1),
      Color(0xFF1E88E5),
      Color(0xFF5E35B1),
      Color(0xFFD81B60),
      Color(0xFF78909C),
    ];
    final paths = <String>[];
    for (var index = 0; index < colors.length; index++) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 96, 96),
        Paint()..color = colors[index],
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(96, 96);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${directory.path}/cover-$index.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      paths.add(file.path);
      image.dispose();
      picture.dispose();
    }
    final now = DateTime.utc(2026, 10, 26);
    final tracks = List.generate(
      paths.length,
      (index) => LocalTrack(
        id: 'native-track-$index',
        title: 'Canción ${index + 1}',
        artist: 'Artista de prueba ${index + 1}',
        filePath: '${directory.path}/fixture-$index.m4a',
        thumbnailPath: paths[index],
        duration: const Duration(minutes: 3),
        addedAt: now,
      ),
    );
    final playlist = Playlist(
      id: 'native-playlist-fixture',
      name: 'Colores de mi biblioteca',
      trackIds: tracks.map((track) => track.id).toList(),
      createdAt: now,
      updatedAt: now,
    );
    final catalog = CatalogPlaylist(
      playlist: playlist,
      entries: List.generate(
        tracks.length,
        (index) => PlaylistEntry(
          id: 'native-entry-$index',
          playlistId: playlist.id,
          localTrackId: tracks[index].id,
          track: CatalogTrack.local(
            localTrackId: tracks[index].id,
            title: tracks[index].title,
            artists: [tracks[index].artist],
            thumbnailUrl: paths[index],
          ),
          position: index,
          createdAt: now,
          updatedAt: now,
        ),
      ),
    );
    return _Fixture(
      playlist: playlist,
      catalog: catalog,
      tracks: tracks,
      artworkPaths: paths,
    );
  }
}

class _FixtureSettings extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: 'native-fixture',
    language: AppLanguage.spanish,
    surfaceBackgroundMode: SurfaceBackgroundMode.liquidGlass,
    miniPlayerBackgroundMode: MiniPlayerBackgroundMode.liquidGlass,
  );
}

class _FixturePlayer extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);
}

class _FixtureDownloads extends DownloadController {
  @override
  Map<String, DownloadTaskState> build() => const {};
}

class _FixtureLive extends TikTokLiveController {
  @override
  Future<TikTokLiveState> build() async => const TikTokLiveState(
    creatorInput: '',
    status: TikTokLiveStatus.idle,
    message: '',
  );
}

class _FixturePlaylists extends PlaylistsController {
  _FixturePlaylists(this.playlist);
  final Playlist playlist;
  @override
  Future<List<Playlist>> build() async => [playlist];
}

class _FixtureAuth extends YouTubeMusicAuthController {
  @override
  YouTubeMusicAuthState build() => const YouTubeMusicAuthState(
    phase: YouTubeMusicAuthPhase.anonymous,
    generation: 1,
  );
}

class _EmptyLinks implements IncomingTrackLinkService {
  const _EmptyLinks();
  @override
  Stream<Uri> get links => const Stream<Uri>.empty();
}
