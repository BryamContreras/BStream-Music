import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Android exposes a responsive TikTok LIVE settings detail', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final liveController = _FakeTikTokLiveController();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
          tiktokLiveControllerProvider.overrideWith(() => liveController),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const Scaffold(body: SettingsPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final liveCard = find.byKey(const ValueKey('settings-card-live'));
    await tester.scrollUntilVisible(
      liveCard,
      240,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-root')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(liveCard, findsOneWidget);
    final saveRequestsSwitch = find.byKey(
      const ValueKey('tiktok-live-save-requests-to-library'),
    );
    expect(saveRequestsSwitch, findsOneWidget);
    expect(tester.widget<Switch>(saveRequestsSwitch).value, isFalse);
    final storageCard = find.byKey(
      const ValueKey('settings-card-live-request-storage'),
    );
    expect(storageCard, findsOneWidget);
    expect(
      tester.getSize(storageCard).height,
      closeTo(tester.getSize(liveCard).height, 0.1),
    );
    expect(
      tester.getTopLeft(saveRequestsSwitch).dy,
      greaterThan(tester.getBottomLeft(liveCard).dy),
    );

    await tester.scrollUntilVisible(
      saveRequestsSwitch,
      300,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-root')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(saveRequestsSwitch);
    await tester.pump();
    expect(liveController.saveRequestsToLibraryCalls, 1);
    expect(liveController.lastSaveRequestsToLibrary, isTrue);

    await tester.scrollUntilVisible(
      liveCard,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(liveCard);
    await tester.pumpAndSettle();
    await tester.tap(liveCard);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-detail-live')), findsOneWidget);
    final userField = find.byKey(const ValueKey('tiktok-live-user-field'));
    final connectButton = find.byKey(const ValueKey('tiktok-live-connect'));
    expect(saveRequestsSwitch, findsNothing);
    expect(userField, findsOneWidget);
    expect(connectButton, findsOneWidget);

    final fieldRect = tester.getRect(userField);
    final buttonRect = tester.getRect(connectButton);
    expect(buttonRect.top, greaterThan(fieldRect.bottom));
    expect(buttonRect.width, closeTo(fieldRect.width, 0.1));

    await tester.enterText(userField, '@bstream_test');
    await tester.tap(connectButton);
    await tester.pump();
    expect(liveController.connectCalls, 1);
    expect(liveController.lastCreatorInput, '@bstream_test');
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a connecting LIVE session can be cancelled from Settings', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    final liveController = _FakeTikTokLiveController(
      initialStatus: TikTokLiveStatus.connecting,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
          tiktokLiveControllerProvider.overrideWith(() => liveController),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
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
    await tester.ensureVisible(liveCard);
    await tester.pumpAndSettle();
    await tester.tap(liveCard);
    await tester.pumpAndSettle();

    final disconnectButton = find.byKey(
      const ValueKey('tiktok-live-disconnect'),
    );
    expect(disconnectButton, findsOneWidget);
    expect(find.byKey(const ValueKey('tiktok-live-connect')), findsNothing);

    await tester.tap(disconnectButton);
    await tester.pump();

    expect(liveController.disconnectCalls, 1);
    expect(tester.takeException(), isNull);

    debugDefaultTargetPlatformOverride = null;
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
  _FakeTikTokLiveController({this.initialStatus = TikTokLiveStatus.idle});

  final TikTokLiveStatus initialStatus;
  var connectCalls = 0;
  var disconnectCalls = 0;
  var saveRequestsToLibraryCalls = 0;
  String? lastCreatorInput;
  bool? lastSaveRequestsToLibrary;

  @override
  Future<TikTokLiveState> build() async => TikTokLiveState(
    creatorInput: '',
    status: initialStatus,
    message: initialStatus == TikTokLiveStatus.connecting
        ? 'Conectando...'
        : 'Listo para conectar.',
  );

  @override
  Future<void> connect([String? value]) async {
    connectCalls += 1;
    lastCreatorInput = value;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls += 1;
  }

  @override
  Future<void> setSaveRequestsToLibrary(bool value) async {
    saveRequestsToLibraryCalls += 1;
    lastSaveRequestsToLibrary = value;
  }
}
