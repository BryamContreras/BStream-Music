import 'dart:convert';

import 'package:bstream_music/core/theme/app_dialog.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/audio_source_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/equalizer_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/settings_panel.dart';
import 'package:bstream_music/services/audio_sources/audio_extension.dart';
import 'package:bstream_music/services/audio_sources/audio_extension_resolver.dart';
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

  testWidgets('playback settings opens the shared equalizer and returns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_harness(desktop: true));
    await tester.pumpAndSettle();
    await _reveal(tester, 'settings-card-equalizer');
    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('settings-card-equalizer')))
          .dy,
      lessThan(
        tester
            .getTopLeft(find.byKey(const ValueKey('settings-inline-timer')))
            .dy,
      ),
    );
    await _open(tester, 'settings-card-equalizer');
    expect(
      find.byKey(const ValueKey('equalizer-settings-page')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('equalizer-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-card-equalizer')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('iOS playback settings opens the same live equalizer controls', (
    tester,
  ) async {
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    await _open(tester, 'settings-card-equalizer');
    expect(
      find.byKey(const ValueKey('equalizer-settings-page')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('equalizer-enabled')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets('extension dialog can be dismissed, validates, and installs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const strings = AppStrings(AppLanguage.spanish);
    final uri = Uri.https('example.com', '/manifest.json');
    final extension = AudioExtension(
      id: 'cd-source',
      name: 'CD source',
      manifestUri: uri,
      allowDownloads: false,
    );
    await tester.pumpWidget(
      _harness(
        extensionResolver: _TestAudioExtensionResolver(uri.toString(), [
          extension,
        ]),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPanel)),
    );
    await _open(tester, 'settings-card-audio-sources');
    final sources = find.byKey(
      const ValueKey('settings-detail-scroll-audioSources'),
    );
    final dialog = find.byType(AppAlertDialog);
    final field = find.byKey(const ValueKey('audio-extension-url'));
    await _open(tester, 'settings-add-audio-source');
    expect(sources, findsOneWidget);
    expect(dialog, findsOneWidget);
    expect(find.descendant(of: dialog, matching: field), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(sources, findsOneWidget);

    await _open(tester, 'settings-add-audio-source');
    await tester.enterText(field, 'not a link');
    await _open(tester, 'audio-extension-submit');
    expect(dialog, findsOneWidget);
    expect(find.text(strings.audioExtensionInvalidUrl), findsOneWidget);
    expect(
      container.read(settingsControllerProvider).requireValue.audioExtensions,
      isEmpty,
    );

    await tester.enterText(field, uri.toString());
    await _open(tester, 'audio-extension-submit');
    expect(dialog, findsNothing);
    expect(sources, findsOneWidget);
    final installed = find.byKey(ValueKey(uri));
    expect(installed, findsOneWidget);
    expect(find.text(extension.name), findsOneWidget);
    expect(find.text(strings.audioExtensionStreamingOnly), findsOneWidget);
    final toggle = find.descendant(
      of: installed,
      matching: find.byType(Switch),
    );
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(find.byTooltip(strings.removeAudioSource));
    await tester.pumpAndSettle();
    expect(installed, findsNothing);
    expect(
      container.read(settingsControllerProvider).requireValue.audioExtensions,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop exposes separate streaming and download quality choices',
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
      await _open(tester, 'data-saving-download-quality');
      await tester.tap(
        find.byKey(const ValueKey('audio-quality-profile-standard')),
      );
      await tester.pumpAndSettle();
      final afterDownload = container
          .read(settingsControllerProvider)
          .requireValue;
      expect(afterDownload.downloadAudioQuality, AudioQualityProfile.standard);
      expect(afterDownload.wifiAudioQuality, AudioQualityProfile.high);
      expect(afterDownload.mobileAudioQuality, AudioQualityProfile.high);
      _expectQualityPage('downloadQuality');
      _expectQualitySelected(const ValueKey('audio-quality-profile-standard'));
      await _returnToDataSaving(tester);

      await _open(tester, 'data-saving-quality');
      expect(find.text('Calidad de audio'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('settings-detail-scroll-wifiQuality')),
        findsOneWidget,
      );
      expect(find.byType(Dialog), findsNothing);
      _expectQualitySelected(const ValueKey('audio-quality-profile-jiosaavn'));
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
      _expectQualityPage('wifiQuality');
      await tester.tap(
        find.byKey(const ValueKey('audio-quality-profile-jiosaavn')),
      );
      await tester.pumpAndSettle();
      _expectQualityPage('wifiQuality');
      _expectQualitySelected(const ValueKey('audio-quality-profile-jiosaavn'));
      final high = container.read(audioSourcePolicyProvider);
      for (final network in AudioNetworkKind.values) {
        expect(high.profileFor(network), AudioQualityProfile.high);
      }
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .downloadAudioQuality,
        AudioQualityProfile.standard,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('catalog import keeps existing choices and adds new sources', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const catalog = 'https://example.com/catalog.json';
    final first = AudioExtension(
      id: 'cd-source',
      name: 'Updated source',
      manifestUri: Uri.https('first.example', '/manifest.json'),
      allowDownloads: false,
    );
    final second = AudioExtension(
      id: 'new-source',
      name: 'New source',
      manifestUri: Uri.https('second.example', '/manifest.json'),
    );
    await tester.pumpWidget(
      _harness(
        extensionResolver: _TestAudioExtensionResolver(catalog, [
          first,
          second,
        ]),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SettingsPanel)),
    );
    await container
        .read(settingsControllerProvider.notifier)
        .addAudioExtension(
          AudioExtension(
            id: first.id,
            name: 'Old source',
            manifestUri: first.manifestUri,
            enabled: false,
          ),
        );
    await tester.pumpAndSettle();
    await _open(tester, 'settings-card-audio-sources');
    await _open(tester, 'settings-add-audio-source');
    await tester.enterText(
      find.byKey(const ValueKey('audio-extension-url')),
      catalog,
    );
    await _open(tester, 'audio-extension-submit');
    expect(find.byType(AppAlertDialog), findsNothing);
    expect(find.text(first.name), findsOneWidget);
    expect(find.text(second.name), findsOneWidget);
    expect(find.text('Old source'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('settings.audioExtensions')!;
    expect(saved.map((item) => jsonDecode(item)), [
      first.copyWith(enabled: false).toJson(),
      second.toJson(),
    ]);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.text('Audio en streaming'), findsOneWidget);
      expect(find.text('Descargas'), findsOneWidget);
      expect(find.text('Alta calidad · JioSaavn'), findsNWidgets(2));
      expect(find.text('Calidad estándar · YTMusic'), findsOneWidget);
      await _open(tester, 'data-saving-download-quality');
      _expectQualityPage('downloadQuality');
      expect(find.byType(Dialog), findsNothing);
      _expectQualitySelected(const ValueKey('audio-quality-profile-jiosaavn'));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('audio-quality-profile-jiosaavn')),
          matching: find.text('JioSaavn → YTMusic'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('audio-quality-profile-standard')),
      );
      await tester.pumpAndSettle();
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .downloadAudioQuality,
        AudioQualityProfile.standard,
      );
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .wifiAudioQuality,
        AudioQualityProfile.high,
      );
      _expectQualityPage('downloadQuality');
      _expectQualitySelected(const ValueKey('audio-quality-profile-standard'));
      await _returnToDataSaving(tester);

      await _open(tester, 'data-saving-mobile');
      _expectQualityPage('mobileQuality');
      await _returnToDataSaving(tester);
      expect(find.byKey(const ValueKey('data-saving-mobile')), findsOneWidget);
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .mobileAudioQuality,
        AudioQualityProfile.standard,
      );
      await _open(tester, 'data-saving-mobile');
      expect(
        find.byKey(const ValueKey('audio-quality-profile-jiosaavn')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('audio-quality-profile-jiosaavn')),
      );
      await tester.pumpAndSettle();
      expect(
        container
            .read(settingsControllerProvider)
            .requireValue
            .mobileAudioQuality,
        AudioQualityProfile.high,
      );
      _expectQualityPage('mobileQuality');
      _expectQualitySelected(const ValueKey('audio-quality-profile-jiosaavn'));
      await _returnToDataSaving(tester);

      await container
          .read(settingsControllerProvider.notifier)
          .setJioSaavnEnabled(false);
      await tester.pumpAndSettle();
      await _open(tester, 'data-saving-download-quality');
      _expectQualityPage('downloadQuality');
      expect(find.text('Alta calidad'), findsNothing);
      await _returnToDataSaving(tester);

      await _open(tester, 'data-saving-wifi');
      expect(find.text('Alta calidad'), findsNothing);
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
      _expectQualityPage('wifiQuality');

      await container
          .read(settingsControllerProvider.notifier)
          .addAudioExtension(
            AudioExtension(
              id: 'stream-only',
              name: 'Streaming extension',
              manifestUri: Uri.https('example.com', '/manifest.json'),
              allowDownloads: false,
            ),
          );
      await tester.pumpAndSettle();
      _expectQualityPage('wifiQuality');
      expect(find.text('Alta calidad'), findsOneWidget);
      expect(find.text('Streaming extension'), findsOneWidget);
      await _returnToDataSaving(tester);
      await _open(tester, 'data-saving-download-quality');
      _expectQualityPage('downloadQuality');
      expect(find.text('Alta calidad'), findsNothing);
      await _returnToDataSaving(tester);

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

  testWidgets('each profile can choose its own audio source priority', (
    tester,
  ) async {
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
    final streaming = AudioExtension(
      id: 'streaming',
      name: 'Streaming extension',
      manifestUri: Uri.https('stream.example', '/manifest.json'),
      allowDownloads: false,
    );
    final downloads = AudioExtension(
      id: 'downloads',
      name: 'Download extension',
      manifestUri: Uri.https('download.example', '/manifest.json'),
    );
    final controller = container.read(settingsControllerProvider.notifier);
    await controller.addAudioExtensions([streaming, downloads]);
    await tester.pumpAndSettle();

    await _open(tester, 'storage-data-saving');
    expect(find.text('Alta calidad · Streaming extension'), findsOneWidget);
    expect(find.text('Alta calidad · Download extension'), findsOneWidget);
    await _open(tester, 'data-saving-wifi');
    _expectQualityPage('wifiQuality');
    _expectQualitySelected(ValueKey(streaming.manifestUri));
    expect(
      find.text('YTMusic → Streaming extension → Otras extensiones → JioSaavn'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey(streaming.manifestUri)));
    await tester.pumpAndSettle();
    _expectQualityPage('wifiQuality');
    _expectQualitySelected(ValueKey(streaming.manifestUri));
    await _returnToDataSaving(tester);

    await _open(tester, 'data-saving-mobile');
    expect(find.text('YTMusic → JioSaavn'), findsOneWidget);
    await _open(tester, 'audio-quality-profile-jiosaavn');
    _expectQualityPage('mobileQuality');
    _expectQualitySelected(const ValueKey('audio-quality-profile-jiosaavn'));
    await _returnToDataSaving(tester);
    expect(find.text('Alta calidad · JioSaavn'), findsOneWidget);

    await _open(tester, 'data-saving-download-quality');
    expect(find.byKey(ValueKey(streaming.manifestUri)), findsNothing);
    _expectQualitySelected(ValueKey(downloads.manifestUri));
    expect(
      find.text('Download extension → JioSaavn → YTMusic'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(ValueKey(downloads.manifestUri)));
    await tester.pumpAndSettle();
    _expectQualityPage('downloadQuality');
    _expectQualitySelected(ValueKey(downloads.manifestUri));
    await _returnToDataSaving(tester);
    expect(find.text('Alta calidad · Download extension'), findsOneWidget);

    final state = container.read(settingsControllerProvider).requireValue;
    expect(
      state.wifiAudioSourcePreference,
      AudioSourcePreference.audioExtension(streaming.manifestUri),
    );
    expect(
      state.mobileAudioSourcePreference,
      const AudioSourcePreference.jioSaavn(),
    );
    expect(
      state.downloadAudioSourcePreference,
      AudioSourcePreference.audioExtension(downloads.manifestUri),
    );

    await controller.setAudioExtensionEnabled(streaming.manifestUri, false);
    await controller.setJioSaavnEnabled(false);
    await tester.pumpAndSettle();
    final unavailableExtension =
        'Streaming extension no está disponible. Alta calidad · Download extension';
    expect(find.text(unavailableExtension), findsOneWidget);
    final unavailableJio =
        'JioSaavn no está disponible. Calidad estándar · YTMusic';
    expect(find.text(unavailableJio), findsOneWidget);
    await _open(tester, 'data-saving-wifi');
    _expectQualitySelected(ValueKey(downloads.manifestUri));
    expect(
      container
          .read(settingsControllerProvider)
          .requireValue
          .wifiAudioSourcePreference,
      AudioSourcePreference.audioExtension(streaming.manifestUri),
    );
    await _returnToDataSaving(tester);
    await _open(tester, 'data-saving-mobile');
    expect(
      find.byKey(const ValueKey('audio-quality-profile-jiosaavn')),
      findsNothing,
    );
    expect(find.byKey(ValueKey(downloads.manifestUri)), findsOneWidget);
    _expectQualitySelected(const ValueKey('audio-quality-profile-standard'));
    expect(tester.takeException(), isNull);
  });
}

void _expectQualityPage(String route) {
  expect(find.byKey(ValueKey('settings-detail-scroll-$route')), findsOneWidget);
  final standardSection = find.byKey(
    const ValueKey('settings-section-panel-Calidad estándar'),
  );
  expect(
    find.descendant(
      of: standardSection,
      matching: find.byKey(const ValueKey('audio-quality-profile-standard')),
    ),
    findsOneWidget,
  );
  expect(
    find.descendant(of: standardSection, matching: find.text('YTMusic')),
    findsOneWidget,
  );
  expect(find.text('Automática'), findsNothing);
}

void _expectQualitySelected(Key key) {
  expect(
    find.descendant(
      of: find.byKey(key),
      matching: find.byIcon(Icons.check_circle_rounded),
    ),
    findsOneWidget,
  );
}

Future<void> _returnToDataSaving(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('settings-detail-back')));
  await tester.pumpAndSettle();
  expect(find.text('Ahorro de datos'), findsOneWidget);
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
  AudioExtensionResolver? extensionResolver,
}) => ProviderScope(
  overrides: [
    audioSourceUsesSingleProfileProvider.overrideWithValue(desktop),
    if (extensionResolver != null)
      audioExtensionResolverProvider.overrideWithValue(extensionResolver),
    settingsControllerProvider.overrideWith(_TestSettingsController.new),
    equalizerRuntimeProvider.overrideWith(_SupportedRuntime.new),
    equalizerAvailableProvider.overrideWithValue(true),
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

class _TestAudioExtensionResolver extends Fake
    implements AudioExtensionResolver {
  _TestAudioExtensionResolver(this.link, this.extensions);

  final String link;
  final List<AudioExtension> extensions;

  @override
  Future<List<AudioExtension>> loadSources(String url) async {
    if (url != link) {
      throw const AudioExtensionException(AudioExtensionError.invalidUrl);
    }
    return extensions;
  }
}

class _TestSettingsController extends SettingsController {
  @override
  Future<SettingsState> build() async => const SettingsState(
    downloadDirectory: '/tmp/BStream-Music',
    language: AppLanguage.spanish,
  );
}

class _SupportedRuntime extends EqualizerRuntimeController {
  @override
  EqualizerRuntimeState build() => const EqualizerRuntimeState(supported: true);
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
