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

    final liveController = _FakeTikTokLiveController(
      initialCommandPermissions: const TikTokCommandPermissions(
        everyone: {TikTokLiveCommand.play},
        moderators: {TikTokLiveCommand.revoke},
      ),
    );
    var supportedLinksOpenCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsControllerProvider.overrideWith(_FakeSettingsController.new),
          tiktokLiveControllerProvider.overrideWith(() => liveController),
          settingsSupportedLinksLauncherProvider.overrideWithValue(() async {
            supportedLinksOpenCalls += 1;
            return true;
          }),
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
    final supportedLinksCard = find.byKey(
      const ValueKey('settings-card-supported-links'),
    );
    await tester.scrollUntilVisible(
      supportedLinksCard,
      240,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('settings-root')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(supportedLinksCard);
    await tester.pumpAndSettle();
    expect(supportedLinksCard, findsOneWidget);
    expect(find.text('Abrir enlaces compatibles'), findsOneWidget);
    await tester.tap(supportedLinksCard);
    await tester.pump();
    expect(supportedLinksOpenCalls, 1);

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

    final audienceSections = [
      for (final audience in TikTokCommandAudience.values)
        find.byKey(ValueKey('tiktok-command-section-${audience.name}')),
    ];
    for (final section in audienceSections) {
      expect(section, findsOneWidget);
      expect(
        find.descendant(of: section, matching: find.byType(CheckboxListTile)),
        findsNWidgets(TikTokLiveCommand.values.length),
      );
      final sectionRect = tester.getRect(section);
      expect(sectionRect.left, closeTo(fieldRect.left, 0.1));
      expect(sectionRect.right, closeTo(fieldRect.right, 0.1));
    }
    expect(
      tester.getTopLeft(audienceSections[1]).dy,
      greaterThan(tester.getBottomLeft(audienceSections[0]).dy),
    );
    expect(
      tester.getTopLeft(audienceSections[2]).dy,
      greaterThan(tester.getBottomLeft(audienceSections[1]).dy),
    );
    expect(find.text('Todos'), findsOneWidget);
    expect(find.text('Moderadores'), findsOneWidget);
    expect(find.text('Suscriptores'), findsOneWidget);
    expect(find.text('!stop'), findsNWidgets(3));
    expect(find.text('Pausa la canción LIVE actual.'), findsNWidgets(3));

    for (final audience in TikTokCommandAudience.values) {
      for (final command in TikTokLiveCommand.values) {
        expect(
          find.byKey(
            ValueKey('tiktok-command-${audience.name}-${command.name}'),
          ),
          findsOneWidget,
        );
      }
    }

    final inheritedModeratorPlay = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('tiktok-command-moderators-play')),
    );
    expect(inheritedModeratorPlay.value, isTrue);
    expect(inheritedModeratorPlay.onChanged, isNull);

    final moderatorRevoke = find.byKey(
      const ValueKey('tiktok-command-moderators-revoke'),
    );
    expect(tester.widget<CheckboxListTile>(moderatorRevoke).value, isTrue);
    final detailScrollable = find
        .descendant(
          of: find.byKey(const ValueKey('settings-detail-scroll-live')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      moderatorRevoke,
      240,
      scrollable: detailScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(moderatorRevoke);
    await tester.pump();
    expect(liveController.commandPermissionCalls.last, (
      audience: TikTokCommandAudience.moderators,
      command: TikTokLiveCommand.revoke,
      enabled: false,
    ));

    final moderatorStop = find.byKey(
      const ValueKey('tiktok-command-moderators-stop'),
    );
    expect(tester.widget<CheckboxListTile>(moderatorStop).value, isFalse);
    await tester.scrollUntilVisible(
      moderatorStop,
      240,
      scrollable: detailScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(moderatorStop);
    await tester.pump();
    expect(liveController.commandPermissionCalls.last, (
      audience: TikTokCommandAudience.moderators,
      command: TikTokLiveCommand.stop,
      enabled: true,
    ));

    final subscriberSkip = find.byKey(
      const ValueKey('tiktok-command-subscribers-skip'),
    );
    expect(tester.widget<CheckboxListTile>(subscriberSkip).value, isFalse);
    await tester.scrollUntilVisible(
      subscriberSkip,
      240,
      scrollable: detailScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(subscriberSkip);
    await tester.pump();
    expect(liveController.commandPermissionCalls.last, (
      audience: TikTokCommandAudience.subscribers,
      command: TikTokLiveCommand.skip,
      enabled: true,
    ));
    expect(liveController.commandPermissionCalls, hasLength(3));
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
  _FakeTikTokLiveController({
    this.initialStatus = TikTokLiveStatus.idle,
    this.initialCommandPermissions = defaultTikTokCommandPermissions,
  });

  final TikTokLiveStatus initialStatus;
  final TikTokCommandPermissions initialCommandPermissions;
  var connectCalls = 0;
  var disconnectCalls = 0;
  var saveRequestsToLibraryCalls = 0;
  String? lastCreatorInput;
  bool? lastSaveRequestsToLibrary;
  final commandPermissionCalls =
      <
        ({
          TikTokCommandAudience audience,
          TikTokLiveCommand command,
          bool enabled,
        })
      >[];

  @override
  Future<TikTokLiveState> build() async => TikTokLiveState(
    creatorInput: '',
    status: initialStatus,
    commandPermissions: initialCommandPermissions,
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
  Future<void> setCommandPermission(
    TikTokCommandAudience audience,
    TikTokLiveCommand command,
    bool enabled,
  ) async {
    commandPermissionCalls.add((
      audience: audience,
      command: command,
      enabled: enabled,
    ));
  }

  @override
  Future<void> setSaveRequestsToLibrary(bool value) async {
    saveRequestsToLibraryCalls += 1;
    lastSaveRequestsToLibrary = value;
  }
}
