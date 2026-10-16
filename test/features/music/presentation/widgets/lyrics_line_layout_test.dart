import 'package:bstream_music/features/music/presentation/widgets/lyrics_line_layout.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_page.dart';
import 'package:bstream_music/features/music/presentation/widgets/lyrics_text_style_transition.dart';
import 'package:bstream_music/services/lyrics/lyrics_romanization_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_translation_service.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const original = '二人 歳を重ねてた 変わらないね 思い出しては';
  const romanized =
      'futari toshi wo kasaneteta kawaranai ne omoidashite wa '
      'yoku nagashi ta ki ki iru hodo';
  const translated =
      'Los dos hemos seguido cumpliendo años, y al recordar todo aquello '
      'me parece que nada ha cambiado todavía.';

  const fontAssets = {
    'Roboto': 'assets/fonts/Roboto-Regular.ttf',
    'Fredoka': 'assets/fonts/Fredoka-Variable.ttf',
    'Nunito': 'assets/fonts/Nunito-Variable.ttf',
    'Lora': 'assets/fonts/Lora-Variable.ttf',
    'Space Mono': 'assets/fonts/SpaceMono-Regular.ttf',
  };

  setUpAll(() async {
    for (final font in fontAssets.entries) {
      await (FontLoader(font.key)..addFont(rootBundle.load(font.value))).load();
    }
  });

  for (final family in fontAssets.keys) {
    for (final sample in [
      (name: 'romanization', text: romanized),
      (name: 'translation', text: translated),
    ]) {
      testWidgets(
        '$family ${sample.name} fits its reserved row throughout resize',
        (tester) async {
          final inherited = TextStyle(
            fontFamily: family,
            fontFamilyFallback: const ['Roboto'],
            wordSpacing: 2.5,
            leadingDistribution: TextLeadingDistribution.even,
          );
          final activeStyle = resolveLyricsOriginalStyle(
            inherited,
            fontSize: 37,
          ).copyWith(color: Colors.white);
          final inactiveStyle = resolveLyricsOriginalStyle(
            inherited,
            fontSize: 36,
          ).copyWith(color: Colors.grey);
          const heightBehavior = TextHeightBehavior(
            applyHeightToFirstAscent: false,
            applyHeightToLastDescent: false,
          );

          for (final scale in [1.0, 1.6, 2.0]) {
            final textScaler = TextScaler.linear(scale);
            for (final width in [760.0, 520.0, 420.25, 280.0, 219.75]) {
              final extent = measureLyricsLineExtent(
                originalText: original,
                secondaryText: sample.text,
                contentWidth: width,
                activeStyle: activeStyle,
                inactiveStyle: inactiveStyle,
                secondaryFontSize: romanizedLyricsFontSize(37),
                textScaler: textScaler,
                textDirection: TextDirection.ltr,
                locale: const Locale('es'),
                textHeightBehavior: heightBehavior,
              );
              for (final active in [false, true]) {
                await tester.pumpWidget(
                  MaterialApp(
                    home: MediaQuery(
                      data: MediaQueryData(textScaler: textScaler),
                      child: DefaultTextStyle(
                        style: inherited,
                        textHeightBehavior: heightBehavior,
                        child: SingleChildScrollView(
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: SizedBox(
                              width: width,
                              height: extent,
                              child: LyricsTextStyleTransition(
                                active: active,
                                originalText: original,
                                secondaryText: sample.text,
                                secondaryKey: const ValueKey('secondary'),
                                activeStyle: activeStyle,
                                inactiveStyle: inactiveStyle,
                                secondaryFontSize: romanizedLyricsFontSize(37),
                                textAlign: TextAlign.start,
                                contentKey: const ValueKey('reserved-row'),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                await tester.pumpAndSettle();
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$family ${sample.name}: $width px, scale $scale',
                );
                final row = tester.getRect(
                  find.byKey(const ValueKey('reserved-row')),
                );
                final paragraphs = find.descendant(
                  of: find.byType(LyricsTextStyleTransition),
                  matching: find.byType(RichText),
                );
                for (final paragraph in paragraphs.evaluate()) {
                  final rect = tester.getRect(
                    find.byElementPredicate(
                      (element) => identical(element, paragraph),
                    ),
                  );
                  expect(rect.top, greaterThanOrEqualTo(row.top));
                  expect(rect.bottom, lessThanOrEqualTo(row.bottom));
                }
              }
            }
          }
        },
      );
    }
  }

  test('resolves inherited font metrics without a second implicit merge', () {
    const inherited = TextStyle(
      fontFamily: 'Fredoka',
      fontFamilyFallback: ['Roboto'],
      wordSpacing: 7,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final originalStyle = resolveLyricsOriginalStyle(inherited, fontSize: 34);
    final secondaryStyle = lyricsSecondaryStyleFor(originalStyle, fontSize: 20);

    for (final style in [originalStyle, secondaryStyle]) {
      expect(style.inherit, isFalse);
      expect(style.fontFamily, 'Fredoka');
      expect(style.fontFamilyFallback, ['Roboto']);
      expect(style.wordSpacing, 7);
      expect(style.leadingDistribution, TextLeadingDistribution.even);
    }
    expect(originalStyle.fontSize, 34);
    expect(originalStyle.letterSpacing, -0.45);
    expect(secondaryStyle.fontSize, 20);
    expect(secondaryStyle.letterSpacing, 0);
  });

  testWidgets('accessible font spacing is measured for both cached endpoints', (
    tester,
  ) async {
    final active = resolveLyricsOriginalStyle(
      const TextStyle(fontFamily: 'Fredoka'),
      fontSize: 34,
    );
    final inactive = active.copyWith(fontSize: 33);
    const accessibility = (
      boldText: true,
      lineHeight: 1.9,
      letterSpacing: 2.0,
      wordSpacing: 5.0,
    );
    const textScaler = TextScaler.linear(1.5);
    final extent = measureLyricsLineExtent(
      originalText: original,
      secondaryText: translated,
      contentWidth: 420,
      activeStyle: active,
      inactiveStyle: inactive,
      secondaryFontSize: 20,
      textScaler: textScaler,
      textDirection: TextDirection.ltr,
      locale: const Locale('es'),
      accessibility: accessibility,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            textScaler: textScaler,
            boldText: true,
            lineHeightScaleFactorOverride: 1.9,
            letterSpacingOverride: 2,
            wordSpacingOverride: 5,
          ),
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 420,
                height: extent,
                child: LyricsTextStyleTransition(
                  active: true,
                  originalText: original,
                  secondaryText: translated,
                  secondaryKey: const ValueKey('accessible-secondary'),
                  activeStyle: active,
                  inactiveStyle: inactive,
                  secondaryFontSize: 20,
                  textAlign: TextAlign.start,
                  contentKey: const ValueKey('accessible-row'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final paragraphs = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(LyricsTextStyleTransition),
        matching: find.byType(RichText),
      ),
    );
    expect(paragraphs, hasLength(4));
    for (final paragraph in paragraphs) {
      expect(paragraph.text.style?.fontWeight, FontWeight.bold);
      expect(paragraph.text.style?.height, accessibility.lineHeight);
      expect(paragraph.text.style?.letterSpacing, accessibility.letterSpacing);
      expect(paragraph.text.style?.wordSpacing, accessibility.wordSpacing);
    }
  });

  for (final translation in [false, true]) {
    testWidgets(
      'desktop ${translation ? 'translation' : 'romanization'} survives compact window resizing',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final controller = _LayoutPlayerController();
        final romanizationService = _LayoutRomanizationService(romanized);
        const document = LyricsDocument(
          provider: 'Test',
          trackName: 'Layout test',
          artistName: 'Test artist',
          lines: [
            LyricLine(timestamp: Duration.zero, text: original),
            LyricLine(timestamp: Duration(seconds: 20), text: original),
            LyricLine(timestamp: Duration(seconds: 40), text: original),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            playerControllerProvider.overrideWith(() => controller),
            settingsControllerProvider.overrideWith(
              () => _LayoutSettingsController(translation: translation),
            ),
            favoriteTrackIdsProvider.overrideWithValue(const {}),
            lyricsProvider.overrideWith((ref, lookup) async => document),
            lyricsRomanizationServiceProvider.overrideWithValue(
              romanizationService,
            ),
            currentLyricsTranslationProvider.overrideWith(
              (ref) async => const TranslatedLyricsView(
                syncedLines: [translated, translated, translated],
                plainLyrics: null,
                sourceLanguage: 'ja',
                alreadyInTargetLanguage: false,
              ),
            ),
          ],
        );
        addTearDown(() {
          container.dispose();
          romanizationService.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1600, 860);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.windows,
                fontFamily: 'Fredoka',
              ),
              home: const LyricsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final secondaryKey = ValueKey(
          'lyrics-line-${translation ? 'translation' : 'romanization'}-0',
        );
        expect(find.byKey(secondaryKey), findsOneWidget);

        // Cross typography breakpoints and fractional layout widths while the
        // same virtual list and row elements remain mounted.
        for (final width in [
          1230.0,
          1199.75,
          1000.0,
          840.25,
          839.9,
          730.0,
          600.25,
          600.0,
          560.0,
          1600.0,
        ]) {
          tester.view.physicalSize = Size(width, 860);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'window width $width');
          expect(find.byKey(secondaryKey), findsOneWidget);
          controller.emitPosition(const Duration(seconds: 20));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'active line: $width');
          controller.emitPosition(Duration.zero);
          await tester.pumpAndSettle();
        }
      },
    );
  }
}

class _LayoutPlayerController extends PlayerController {
  PlayerSnapshot _snapshot = const PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Layout test',
    artist: 'Test artist',
    trackId: 'layout-test',
    sourceUrl: 'https://example.com/layout-test',
    duration: Duration(minutes: 3),
  );

  @override
  Future<PlayerSnapshot> build() async => _snapshot;

  void emitPosition(Duration position) {
    _snapshot = _snapshot.copyWith(position: position);
    state = AsyncData(_snapshot);
  }
}

class _LayoutSettingsController extends SettingsController {
  _LayoutSettingsController({required this.translation});

  final bool translation;

  @override
  Future<SettingsState> build() async => SettingsState(
    downloadDirectory: '/tmp/lyrics-layout-test',
    language: AppLanguage.spanish,
    lyricsRomanizationEnabled: !translation,
    lyricsTranslationEnabled: translation,
  );
}

class _LayoutRomanizationService extends LyricsRomanizationService {
  _LayoutRomanizationService(this.text);

  final String text;

  @override
  Future<RomanizedLyricsView> romanizeDocument(
    LyricsDocument document,
    Set<LyricsRomanizationLanguage> languages,
  ) async => RomanizedLyricsView(
    syncedLines: [
      for (var index = 0; index < document.lines.length; index++) text,
    ],
    plainLyrics: null,
  );
}
