import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_source_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/services/audio_sources/audio_source_policy.dart';
import 'package:bstream_music/services/live/tiktok_live_command_service.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('audio sources keeps YouTube enabled and allows Jio toggling', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(850, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    await _open(tester, 'settings-card-audio-sources');

    final youtube = tester.widget<Switch>(
      find.byKey(const ValueKey('audio-source-youtube-music-switch')),
    );
    expect(youtube.value, isTrue);
    expect(youtube.onChanged, isNull);
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    final jio = find.byKey(const ValueKey('audio-source-jiosaavn-switch'));
    expect(tester.widget<Switch>(jio).value, isTrue);
    await tester.tap(jio);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(jio).value, isFalse);
    expect(
      tester
          .widget<Switch>(
            find.byKey(const ValueKey('audio-source-youtube-music-switch')),
          )
          .value,
      isTrue,
    );
    expect(
      (await SharedPreferences.getInstance()).getBool(
        'settings.jioSaavnEnabled',
      ),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop exposes one quality choice and uses it for every transport',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_harness(desktop: true));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsPanel)),
      );
      // A retained mobile preference is independent of the desktop choice.
      await container
          .read(settingsControllerProvider.notifier)
          .setMobileAudioQuality(AudioQualityProfile.high);
      await _open(tester, 'storage-data-saving');
      expect(find.byKey(const ValueKey('data-saving-quality')), findsOneWidget);
      expect(find.byKey(const ValueKey('data-saving-wifi')), findsNothing);
      expect(find.byKey(const ValueKey('data-saving-mobile')), findsNothing);
      await _open(tester, 'data-saving-quality');
      expect(find.text('Calidad de audio'), findsNWidgets(2));
      await tester.tap(
        find.byKey(const ValueKey('audio-quality-profile-standard')),
      );
      await tester.pumpAndSettle();
      final state = container.read(settingsControllerProvider).requireValue;
      expect(state.wifiAudioQuality, AudioQualityProfile.standard);
      expect(state.mobileAudioQuality, AudioQualityProfile.high);
      final policy = container.read(audioSourcePolicyProvider);
      expect(policy.useSingleProfile, isTrue);
      for (final network in AudioNetworkKind.values) {
        expect(policy.profileFor(network), AudioQualityProfile.standard);
      }
      await _open(tester, 'data-saving-quality');
      await tester.tap(
        find.byKey(const ValueKey('audio-quality-profile-high')),
      );
      await tester.pumpAndSettle();
      final high = container.read(audioSourcePolicyProvider);
      for (final network in AudioNetworkKind.values) {
        expect(high.profileFor(network), AudioQualityProfile.high);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'network profiles select enabled providers and keep route hierarchy',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final navigation = SettingsNavigationController();
      addTearDown(navigation.dispose);
      await tester.pumpWidget(_harness(navigation: navigation));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsPanel)),
      );
      final dataSaving = find.byKey(const ValueKey('storage-data-saving'));
      final backup = find.byKey(const ValueKey('settings-card-storage'));
      await tester.scrollUntilVisible(
        dataSaving,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(dataSaving, findsOneWidget);
      expect(backup, findsOneWidget);
      expect(
        tester.getTopLeft(dataSaving).dy,
        lessThan(tester.getTopLeft(backup).dy),
      );
      await _open(tester, 'storage-data-saving');
      expect(find.text('Alta calidad · JioSaavn'), findsOneWidget);
      expect(find.text('Calidad estándar · YouTube Music'), findsOneWidget);
      await _open(tester, 'data-saving-mobile');
      expect(
        find.byKey(const ValueKey('audio-quality-profile-high')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('audio-quality-profile-high')),
      );
      await tester.pumpAndSettle();
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .mobileAudioQuality,
        AudioQualityProfile.high,
      );

      await container
          .read(settingsControllerProvider.notifier)
          .setJioSaavnEnabled(false);
      await tester.pumpAndSettle();
      await _open(tester, 'data-saving-wifi');
      expect(
        find.byKey(const ValueKey('audio-quality-profile-high')),
        findsNothing,
      );
      final standard = find.byKey(
        const ValueKey('audio-quality-profile-standard'),
      );
      expect(standard, findsOneWidget);
      await tester.tap(standard);
      await tester.pumpAndSettle();
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .wifiAudioQuality,
        AudioQualityProfile.standard,
      );
      expect(navigation.maybePop(), isTrue);
      await tester.pumpAndSettle();
      await _reveal(tester, 'storage-data-saving');
      expect(find.byKey(const ValueKey('storage-data-saving')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-card-storage')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('data-saving-wifi')), findsNothing);
      await _open(tester, 'settings-card-storage');
      expect(find.byKey(const ValueKey('storage-data-saving')), findsNothing);
      expect(
        find.byKey(const ValueKey('storage-import-backup')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _open(WidgetTester tester, String key) async {
  await _reveal(tester, key);
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(
    target,
    220,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Widget _harness({
  SettingsNavigationController? navigation,
  bool desktop = false,
}) => ProviderScope(
  overrides: [
    audioSourceUsesSingleProfileProvider.overrideWithValue(desktop),
    settingsControllerProvider.overrideWith(_TestSettingsController.new),
    appStringsProvider.overrideWithValue(const AppStrings(AppLanguage.spanish)),
    tiktokLiveControllerProvider.overrideWith(_IdleLiveController.new),
    youtubeMusicSessionStoreProvider.overrideWithValue(
      const _AnonymousSessionStore(),
    ),
    youtubeMusicAccountClientProvider.overrideWithValue(
      const UnconfiguredYouTubeMusicAccountClient(),
    ),
  ],
  child: MaterialApp(
    theme: ThemeData(
      platform: desktop ? TargetPlatform.windows : TargetPlatform.iOS,
    ),
    home: Scaffold(body: SettingsPanel(navigationController: navigation)),
  ),
);

class _TestSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
  );
}

class _IdleLiveController extends TikTokLiveController {
  @override
  Future<TikTokLiveState> build() async => const TikTokLiveState(
    creatorInput: '',
    status: TikTokLiveStatus.idle,
    message: 'Idle',
  );
}

class _AnonymousSessionStore implements YouTubeMusicSessionStore {
  const _AnonymousSessionStore();

  @override
  Future<void> delete() async {}

  @override
  Future<YouTubeMusicSessionCredential?> read() async => null;

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {}
}
