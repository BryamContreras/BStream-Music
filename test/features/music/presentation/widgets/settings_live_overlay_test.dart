import 'dart:io';

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/providers/live_overlay_controller.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/features/music/presentation/widgets/live_widget_style_settings.dart';
import 'package:bstream_music/services/live/local_overlay_hosts.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      '$platform previews and selects LIVE styles with back to Appearance',
      (tester) async {
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = const Size(1100, 1000);
        addTearDown(() {
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio();
        });
        final navigation = SettingsNavigationController();
        addTearDown(navigation.dispose);
        final settings = _FakeSettingsController();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsControllerProvider.overrideWith(() => settings),
              appStringsProvider.overrideWithValue(
                const AppStrings(AppLanguage.spanish),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(platform: platform),
              home: Scaffold(
                body: SettingsPanel(navigationController: navigation),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('settings-card-appearance')),
        );
        await tester.pumpAndSettle();
        final selector = find.byKey(
          const ValueKey('live-widget-style-selector'),
        );
        await tester.scrollUntilVisible(
          selector,
          280,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(selector);
        await tester.pumpAndSettle();
        expect(find.text('Widget Live'), findsOneWidget);
        expect(
          tester
              .widget<LiveWidgetPreview>(
                find.byKey(const ValueKey('live-widget-preview')),
              )
              .style,
          LiveWidgetStyle.classic,
        );
        await tester.tap(find.byKey(const ValueKey('live-widget-style-wave')));
        await tester.pumpAndSettle();
        expect(settings.state.value?.liveWidgetStyle, LiveWidgetStyle.wave);
        expect(
          tester
              .widget<LiveWidgetPreview>(
                find.byKey(const ValueKey('live-widget-preview')),
              )
              .style,
          LiveWidgetStyle.wave,
        );
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(460, 900);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .getSize(find.byKey(const ValueKey('live-widget-preview')))
              .width,
          lessThanOrEqualTo(460),
        );
        expect(navigation.maybePop(), isTrue);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('settings-detail-appearance')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('settings-root')), findsOneWidget);
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform hides desktop-only LIVE widget styling', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsControllerProvider.overrideWith(
              _FakeSettingsController.new,
            ),
            appStringsProvider.overrideWithValue(
              const AppStrings(AppLanguage.spanish),
            ),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: platform),
            home: const Scaffold(body: SettingsPanel()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-card-appearance')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('live-widget-style-selector')),
        findsNothing,
      );
    });
  }

  testWidgets('Windows shows LIVE details before the local domain overlay', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1100, 1000);
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final client = _FakeOverlayClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
          tiktokLiveControllerProvider.overrideWith(
            () => _FakeTikTokLiveController(connected: true),
          ),
          playerControllerProvider.overrideWith(_FakePlayerController.new),
          liveOverlayAvailableProvider.overrideWithValue(true),
          liveOverlayClientProvider.overrideWithValue(client),
          liveOverlayArtworkLoaderProvider.overrideWithValue((_) async => null),
          liveOverlayAccentProvider.overrideWithValue(AppAccent.blue),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const Scaffold(body: SettingsPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final liveCard = find.byKey(const ValueKey('settings-card-live'));
    await tester.scrollUntilVisible(
      liveCard,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(liveCard);
    await tester.pumpAndSettle();

    final connect = find.byKey(const ValueKey('tiktok-live-disconnect'));
    final sessionDetails = find.byKey(
      const ValueKey('tiktok-live-session-details'),
    );
    final overlayCard = find.byKey(const ValueKey('tiktok-live-overlay-card'));
    final everyoneCommands = find.byKey(
      const ValueKey('tiktok-command-section-everyone'),
    );
    final overlaySwitch = find.byKey(
      const ValueKey('tiktok-live-overlay-switch'),
    );
    expect(connect, findsOneWidget);
    expect(sessionDetails, findsOneWidget);
    expect(overlayCard, findsOneWidget);
    expect(everyoneCommands, findsOneWidget);
    expect(overlaySwitch, findsOneWidget);
    expect(
      tester.getTopLeft(sessionDetails).dy,
      greaterThan(tester.getBottomLeft(connect).dy),
    );
    expect(
      tester.getTopLeft(overlayCard).dy,
      greaterThan(tester.getBottomLeft(sessionDetails).dy),
    );
    expect(
      tester.getTopLeft(everyoneCommands).dy,
      greaterThan(tester.getBottomLeft(overlayCard).dy),
    );
    expect(find.text('room_id: 741852963'), findsOneWidget);
    expect(
      find.textContaining('\u00daltimo comando: !play Perfecta'),
      findsOneWidget,
    );
    expect(tester.widget<Switch>(overlaySwitch).onChanged, isNotNull);

    await tester.tap(overlaySwitch);
    await tester.pumpAndSettle();

    expect(client.startCalls, 1);
    expect(client.published, isNotEmpty);
    expect(
      find.byKey(const ValueKey('tiktok-live-overlay-copy-url')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('tiktok-live-overlay-preview')),
      findsOneWidget,
    );
    expect(find.textContaining(liveOverlayUrl), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tiktok-live-overlay-switch')));
    await tester.pumpAndSettle();
    expect(client.stopCalls, 1);
  });

  testWidgets('Windows can start the local overlay before LIVE connects', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1100, 1000);
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final client = _FakeOverlayClient();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
          tiktokLiveControllerProvider.overrideWith(
            () => _FakeTikTokLiveController(connected: false),
          ),
          playerControllerProvider.overrideWith(_FakePlayerController.new),
          liveOverlayAvailableProvider.overrideWithValue(true),
          liveOverlayClientProvider.overrideWithValue(client),
          liveOverlayArtworkLoaderProvider.overrideWithValue((_) async => null),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const Scaffold(body: SettingsPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final liveCard = find.byKey(const ValueKey('settings-card-live'));
    await tester.scrollUntilVisible(
      liveCard,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(liveCard);
    await tester.pumpAndSettle();

    final overlaySwitch = find.byKey(
      const ValueKey('tiktok-live-overlay-switch'),
    );
    expect(tester.widget<Switch>(overlaySwitch).onChanged, isNotNull);

    await tester.tap(overlaySwitch);
    await tester.pumpAndSettle();

    expect(client.startCalls, 1);
    expect(client.published, isNotEmpty);
    expect(
      find.byKey(const ValueKey('tiktok-live-overlay-copy-url')),
      findsOneWidget,
    );
  });

  testWidgets('Windows shows a concise permission error for the overlay', (
    tester,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(1100, 1000);
    addTearDown(() {
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final client = _FakeOverlayClient(
      startError: const LocalOverlayHostsElevationException(
        'Technical permission wrapper',
        ProcessException(
          'powershell.exe',
          <String>['-EncodedCommand', 'private-technical-detail'],
          'Access denied',
          5,
        ),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
          tiktokLiveControllerProvider.overrideWith(
            () => _FakeTikTokLiveController(connected: true),
          ),
          playerControllerProvider.overrideWith(_FakePlayerController.new),
          liveOverlayAvailableProvider.overrideWithValue(true),
          liveOverlayClientProvider.overrideWithValue(client),
          liveOverlayArtworkLoaderProvider.overrideWithValue((_) async => null),
          liveOverlayAccentProvider.overrideWithValue(AppAccent.blue),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: const Scaffold(body: SettingsPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final liveCard = find.byKey(const ValueKey('settings-card-live'));
    await tester.scrollUntilVisible(
      liveCard,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(liveCard);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tiktok-live-overlay-switch')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Windows no pudo configurar el dominio local. Inténtalo de nuevo y '
        'acepta el permiso de administrador.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('ProcessException'), findsNothing);
    expect(find.textContaining('private-technical-detail'), findsNothing);
  });
}

class _FakeSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: 'BStream-Music',
    language: AppLanguage.spanish,
  );

  @override
  Future<void> setLiveWidgetStyle(LiveWidgetStyle style) async {
    state = AsyncData(state.requireValue.copyWith(liveWidgetStyle: style));
  }
}

class _FakeTikTokLiveController extends TikTokLiveController {
  _FakeTikTokLiveController({required this.connected});

  final bool connected;

  @override
  Future<TikTokLiveState> build() async => TikTokLiveState(
    creatorInput: '@bstream_test',
    status: connected ? TikTokLiveStatus.connected : TikTokLiveStatus.idle,
    message: connected ? 'Conectado' : 'Listo para conectar.',
    roomId: connected ? '741852963' : null,
    lastCommand: connected
        ? const TikTokLiveChatCommand(
            action: 'play',
            user: 'viewer_test',
            text: '!play Perfecta',
            query: 'Perfecta',
          )
        : null,
  );
}

class _FakePlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async =>
      const PlayerSnapshot(status: PlayerStatus.idle);
}

class _FakeOverlayClient implements LiveOverlayClient {
  _FakeOverlayClient({this.startError});

  final Object? startError;
  int startCalls = 0;
  int stopCalls = 0;
  final List<Object?> published = <Object?>[];

  @override
  Future<Uri> start() async {
    startCalls++;
    if (startError case final error?) throw error;
    return Uri.parse(liveOverlayUrl);
  }

  @override
  void publishJson(Object? value) => published.add(value);

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> dispose() async {}
}
