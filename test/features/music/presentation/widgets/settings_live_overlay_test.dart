import 'dart:io';

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/providers/live_overlay_controller.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/services/live/local_overlay_hosts.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  testWidgets('Windows keeps the overlay disabled before LIVE connects', (
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
    expect(tester.widget<Switch>(overlaySwitch).onChanged, isNull);
    expect(find.textContaining('Conecta un LIVE'), findsOneWidget);
    expect(client.startCalls, 0);
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
