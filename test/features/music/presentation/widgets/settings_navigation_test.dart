import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/pages/home_page.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:bstream_music/services/sharing/incoming_track_link_service.dart';
import 'package:bstream_music/services/storage/library_csv_import_service.dart';
import 'package:bstream_music/services/storage/library_csv_service.dart';
import 'package:bstream_music/services/storage/local_library_reconciler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'appearance opens as a detail page and returns to settings root',
    (tester) async {
      _configureView(tester, const Size(760, 1100));
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-card-appearance')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('accent-palette-grid')), findsNothing);
      expect(navigationController.canPop, isFalse);

      await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('settings-detail-appearance')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('settings-root')), findsNothing);
      expect(find.byKey(const ValueKey('accent-palette-grid')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-detail-back')),
        findsOneWidget,
      );
      expect(navigationController.canPop, isTrue);

      await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-detail-appearance')),
        findsNothing,
      );
      expect(navigationController.canPop, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'language uses a selected modal option without opening a settings page',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      _configureView(tester, const Size(320, 720));
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('settings-card-language')));
      await tester.pumpAndSettle();

      final dialog = find.byKey(const ValueKey('settings-language-dialog'));
      final spanish = find.byKey(
        const ValueKey('settings-language-option-spanish'),
      );
      final english = find.byKey(
        const ValueKey('settings-language-option-english'),
      );
      expect(dialog, findsOneWidget);
      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-detail-back')), findsNothing);
      expect(navigationController.canPop, isFalse);
      expect(
        find.descendant(
          of: spanish,
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: english,
          matching: find.byIcon(Icons.radio_button_unchecked_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(english);
      await tester.pumpAndSettle();
      await tester.tap(english);
      await tester.pumpAndSettle();

      expect(dialog, findsNothing);
      expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      expect(navigationController.canPop, isFalse);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-card-language')),
          matching: find.text('English'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('settings cards use compact corners and spacing', (tester) async {
    _configureView(tester, const Size(760, 1100));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    final appearanceCard = find.byKey(
      const ValueKey('settings-card-appearance'),
    );
    final lyricsCard = find.byKey(
      const ValueKey('settings-card-lyrics-appearance'),
    );
    final timerCard = find.byKey(const ValueKey('settings-inline-timer'));

    final cardShape = _outerMaterialShape(tester, appearanceCard);
    final timerShape = _outerMaterialShape(tester, timerCard);
    expect(cardShape.borderRadius, BorderRadius.circular(12));
    expect(timerShape.borderRadius, BorderRadius.circular(12));

    final cardGap =
        tester.getTopLeft(lyricsCard).dy -
        tester.getBottomLeft(appearanceCard).dy;
    expect(cardGap, closeTo(8, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('lyrics appearance offers animation, alignment, and preview', (
    tester,
  ) async {
    _configureView(tester, const Size(430, 900));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('settings-card-lyrics-appearance'));
    expect(card, findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-detail-lyrics')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-animation-options')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-alignment-options')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('lyrics-animation-preview')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('lyrics-animation-option-slide')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('lyrics-animation-option-slide')),
          )
          .selected,
      isTrue,
    );

    await tester.tap(find.text('Centrada'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('lyrics-preview-active-line')),
          )
          .textAlign,
      TextAlign.center,
    );
    expect(
      find.byKey(const ValueKey('lyrics-preview-slide-centered-2')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('lyrics-preview-replay')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(navigationController.maybePop(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
  });

  testWidgets('timer stays inline while storage opens its detail page', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    _configureView(tester, const Size(760, 1600));
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();

    expect(find.text('Reproducción'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-inline-timer')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('settings-inline-timer')),
        matching: find.byType(SwitchListTile),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('settings-card-timer')), findsNothing);
    expect(find.byKey(const ValueKey('settings-inline-tools')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-card-tools')), findsNothing);
    expect(find.byKey(const ValueKey('storage-import-backup')), findsNothing);
    expect(navigationController.canPop, isFalse);
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-card-storage')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-detail-storage')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('storage-import-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-import-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-csv')), findsOneWidget);
    expect(find.text('Importar'), findsOneWidget);
    expect(find.text('Exportar'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('download-directory-field')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('music-import-start')), findsNothing);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(navigationController.canPop, isTrue);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('appearance, inline timer, and storage fit a 320 px phone', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _configureView(tester, const Size(320, 720));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);

    await tester.pumpWidget(
      _settingsHarness(navigationController: navigationController),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('accent-palette-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('accent-ocean')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('accent-ocean'))).width,
      greaterThanOrEqualTo(48),
    );
    expect(find.byKey(const ValueKey('accent-expand-button')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-inline-timer')), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-card-timer')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-card-storage')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('download-directory-field')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('download-directory-field')),
          )
          .readOnly,
      isTrue,
    );
    expect(
      find.byKey(const ValueKey('download-directory-browse')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('storage-import-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-import-csv')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-backup')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-export-csv')), findsOneWidget);
    expect(find.text('Respaldo'), findsNothing);
    expect(find.byKey(const ValueKey('music-import-start')), findsNothing);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'storage confirms destructive ZIP import and offers CSV profiles',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      _configureView(tester, const Size(760, 1000));
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('settings-card-storage')),
      );
      await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
      await tester.pumpAndSettle();

      final importBackup = find.byKey(const ValueKey('storage-import-backup'));
      await tester.ensureVisible(importBackup);
      await tester.tap(importBackup);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('backup-import-confirmation')),
        findsOneWidget,
      );
      expect(find.textContaining('reemplaz'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('backup-import-cancel')));
      await tester.pumpAndSettle();

      final exportCsv = find.byKey(const ValueKey('storage-export-csv'));
      await tester.ensureVisible(exportCsv);
      await tester.tap(exportCsv);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('csv-export-profile-dialog')),
        findsOneWidget,
      );
      for (final profile in const [
        'bstream',
        'metroList',
        'harmony',
        'soundiiz',
      ]) {
        expect(find.byKey(ValueKey('csv-profile-$profile')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('csv-export-profile-cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('CSV import previews before downloading and reports completion', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    _configureView(tester, const Size(760, 1000));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final navigationController = SettingsNavigationController();
    addTearDown(navigationController.dispose);
    final transferController = _ImmediateCsvTransferController();

    await tester.pumpWidget(
      _settingsHarness(
        navigationController: navigationController,
        overrides: [
          storageImportFilePickerProvider.overrideWithValue(
            ({required dialogTitle, required allowedExtensions}) async =>
                FilePickerResult([
                  PlatformFile(name: 'MetroList.csv', size: 42, path: 'x.csv'),
                ]),
          ),
          libraryCsvTransferControllerProvider.overrideWith(
            () => transferController,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-card-storage')),
    );
    await tester.tap(find.byKey(const ValueKey('settings-card-storage')));
    await tester.pumpAndSettle();

    final importCsv = find.byKey(const ValueKey('storage-import-csv'));
    await tester.ensureVisible(importCsv);
    await tester.tap(importCsv);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('csv-import-preview')), findsOneWidget);
    expect(find.textContaining('1 canciones'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('csv-import-preview-confirm')));
    await tester.pumpAndSettle();
    expect(transferController.importCalls, 1);
    expect(
      find.byKey(const ValueKey('csv-import-progress-dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('1 descargadas'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('csv-import-close')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'storage transfer cards fit a small phone with large accessible text',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      _configureView(tester, const Size(320, 568));
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final navigationController = SettingsNavigationController();
      addTearDown(navigationController.dispose);

      await tester.pumpWidget(
        _settingsHarness(navigationController: navigationController),
      );
      await tester.pumpAndSettle();
      final storageCard = find.byKey(const ValueKey('settings-card-storage'));
      await tester.scrollUntilVisible(
        storageCard,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(storageCard);
      await tester.pumpAndSettle();

      const transferKeys = [
        'storage-import-backup',
        'storage-import-csv',
        'storage-export-backup',
        'storage-export-csv',
      ];
      for (final key in transferKeys) {
        final card = find.byKey(ValueKey(key));
        expect(card, findsOneWidget);
        await tester.ensureVisible(card);
        await tester.pumpAndSettle();
        expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      }
      final exportCsv = find.byKey(const ValueKey('storage-export-csv'));
      await tester.ensureVisible(exportCsv);
      await tester.tap(exportCsv);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('csv-export-profile-dialog')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('csv-export-profile-cancel')));
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('system Back closes settings detail before leaving the tab', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _configureView(tester, const Size(430, 900));
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(_homeHarness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ajustes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('settings-detail-appearance')),
      findsOneWidget,
    );
    expect(
      _navigationIcon(tester, Icons.settings_rounded).color,
      _activeColor(tester),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-detail-appearance')),
      findsNothing,
    );
    expect(
      _navigationIcon(tester, Icons.settings_rounded).color,
      _activeColor(tester),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(
      _navigationIcon(tester, Icons.home_rounded).color,
      _activeColor(tester),
    );
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}

void _configureView(WidgetTester tester, Size size) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(() {
    tester.view
      ..resetPhysicalSize()
      ..resetDevicePixelRatio();
  });
}

Widget _settingsHarness({
  required SettingsNavigationController navigationController,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [..._providerOverrides(), ...overrides],
    child: MaterialApp(
      home: Scaffold(
        body: SettingsPanel(navigationController: navigationController),
      ),
    ),
  );
}

Widget _homeHarness() {
  return ProviderScope(
    overrides: [
      ..._providerOverrides(),
      downloaderWarmupProvider.overrideWith((ref) async {}),
      localLibraryReconciliationProvider.overrideWith(
        (ref) async => LocalLibraryReconciliationResult.empty,
      ),
      historyProvider.overrideWith((ref) async => const <LocalTrack>[]),
      libraryTracksProvider.overrideWith((ref) async => const <LocalTrack>[]),
      homeRecommendationsProvider.overrideWith(
        (ref) async => const <HomeRecommendationSection>[],
      ),
      playlistsControllerProvider.overrideWith(_EmptyPlaylistsController.new),
      playerControllerProvider.overrideWith(_IdlePlayerController.new),
      desktopMediaSessionProvider.overrideWithValue(null),
      incomingTrackLinkServiceProvider.overrideWithValue(
        const _EmptyIncomingTrackLinkService(),
      ),
    ],
    child: const MaterialApp(home: HomePage()),
  );
}

final class _EmptyIncomingTrackLinkService implements IncomingTrackLinkService {
  const _EmptyIncomingTrackLinkService();

  @override
  Stream<Uri> get links => const Stream<Uri>.empty();
}

List<Override> _providerOverrides() {
  return [
    settingsControllerProvider.overrideWith(_FixedSettingsController.new),
    appStringsProvider.overrideWithValue(const AppStrings(AppLanguage.spanish)),
    tiktokLiveControllerProvider.overrideWith(_IdleTikTokLiveController.new),
  ];
}

Icon _navigationIcon(WidgetTester tester, IconData icon) {
  final navigation = find.byKey(const ValueKey('bottom-navigation-content'));
  return tester.widget<Icon>(
    find.descendant(of: navigation, matching: find.byIcon(icon)),
  );
}

Color _activeColor(WidgetTester tester) {
  final context = tester.element(
    find.byKey(const ValueKey('bottom-navigation-content')),
  );
  return Theme.of(context).colorScheme.primary;
}

RoundedRectangleBorder _outerMaterialShape(
  WidgetTester tester,
  Finder surface,
) {
  final material = tester.widget<Material>(
    find.descendant(of: surface, matching: find.byType(Material)).first,
  );
  return material.shape! as RoundedRectangleBorder;
}

class _FixedSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
  );

  @override
  Future<void> setLanguage(AppLanguage language) async {
    final current = await future;
    state = AsyncData(current.copyWith(language: language));
  }

  @override
  Future<void> setLyricsAnimationStyle(
    LyricsAnimationStyle lyricsAnimationStyle,
  ) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(lyricsAnimationStyle: lyricsAnimationStyle),
    );
  }

  @override
  Future<void> setLyricsTextAlignment(
    LyricsTextAlignment lyricsTextAlignment,
  ) async {
    final current = await future;
    state = AsyncData(
      current.copyWith(lyricsTextAlignment: lyricsTextAlignment),
    );
  }
}

class _IdleTikTokLiveController extends TikTokLiveController {
  @override
  Future<TikTokLiveState> build() async => const TikTokLiveState(
    creatorInput: '',
    status: TikTokLiveStatus.idle,
    message: 'Listo para conectar.',
  );
}

class _EmptyPlaylistsController extends PlaylistsController {
  @override
  Future<List<Playlist>> build() async => const <Playlist>[];
}

class _IdlePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);
}

class _ImmediateCsvTransferController extends LibraryCsvTransferController {
  int importCalls = 0;

  static const document = LibraryCsvDocument(
    tracks: [
      LibraryCsvTrack(
        rowNumber: 2,
        title: 'Song',
        artist: 'Artist',
        youtubeVideoId: 'dQw4w9WgXcQ',
      ),
    ],
    detectedFormat: LibraryCsvDetectedFormat.metroList,
    defaultPlaylistName: 'MetroList',
    hasPlaylistColumn: false,
  );

  @override
  Future<LibraryCsvDocument> preview(String path) async {
    state = const LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.completed,
      document: document,
    );
    return document;
  }

  @override
  Future<LibraryCsvImportResult> importDocument(
    LibraryCsvDocument document,
  ) async {
    importCalls++;
    const result = LibraryCsvImportResult(
      total: 1,
      processed: 1,
      downloaded: 1,
      reused: 0,
      failed: 0,
      playlistsUpdated: 1,
      cancelled: false,
      failures: [],
    );
    state = const LibraryCsvTransferState(
      phase: LibraryCsvTransferPhase.completed,
      document: _ImmediateCsvTransferController.document,
      result: result,
    );
    return result;
  }
}
