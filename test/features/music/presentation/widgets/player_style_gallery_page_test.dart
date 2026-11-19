import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:bstream_music/features/music/presentation/providers/player_style.dart';
import 'package:bstream_music/features/music/presentation/widgets/player_style_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('miniatures stay static with every surface material', (
    tester,
  ) async {
    _configureView(tester, const Size(320, 720));
    for (final mode in SurfaceBackgroundMode.values) {
      for (final style in PlayerStyle.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              extensions: [AppSurfaceTheme(backgroundMode: mode)],
            ),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 152,
                  height: 320,
                  child: PlayerStylePreview(style: style),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final miniature = find.byType(PlayerStylePreview);
        for (final effect in [
          find.byType(BackdropFilter),
          find.byType(ImageFiltered),
          find.byType(LiquidGlassSurface),
        ]) {
          expect(
            find.descendant(of: miniature, matching: effect),
            findsNothing,
            reason: '$style / $mode must not sample or filter live surfaces',
          );
        }
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('bundled previews match mobile and desktop palettes', (
    tester,
  ) async {
    final verifiedAssets = <String>{};
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      for (final brightness in Brightness.values) {
        for (final style in PlayerStyle.values) {
          await tester.pumpWidget(
            MaterialApp(
              key: ValueKey('preview-$platform-$brightness-$style'),
              theme: ThemeData(brightness: brightness, platform: platform),
              home: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 190,
                    height: 400,
                    child: PlayerStylePreview(style: style),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final preview = find.byKey(
            ValueKey('player-style-preview-${style.code}'),
          );
          final image = tester.widget<Image>(
            find.descendant(of: preview, matching: find.byType(Image)),
          );
          final dark =
              platform == TargetPlatform.android ||
              platform == TargetPlatform.iOS ||
              brightness == Brightness.dark;
          final path =
              'assets/player_styles/${dark ? 'dark' : 'light'}/${style.code}.png';
          expect((image.image as AssetImage).assetName, path);
          expect(image.excludeFromSemantics, isTrue);
          if (verifiedAssets.add(path)) {
            final bytes = await rootBundle.load(path);
            // PNG dimensions are part of its IHDR. This also guards accidental
            // exports at 2x/3x, which multiply thumbnail decode memory.
            expect(bytes.getUint32(16), 380);
            expect(bytes.getUint32(20), 800);
          }
          expect(
            Theme.of(tester.element(find.byType(Scaffold))).brightness,
            brightness,
          );
          expect(tester.takeException(), isNull);
        }
      }
    }
    expect(verifiedAssets.length, PlayerStyle.values.length * 2);
  });

  testWidgets('gallery saves styles immediately and stays open', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 900));
    final saved = <PlayerStyle>[];
    await tester.pumpWidget(_harness(onChanged: (value) => saved.add(value)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(
      find.byType(PlayerStylePreview),
      findsNWidgets(PlayerStyle.values.length),
    );
    expect(
      find.text(const AppStrings(AppLanguage.spanish).playerStylePreview),
      findsNothing,
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
    for (final style in PlayerStyle.values) {
      final previewFinder = find.byKey(
        ValueKey('player-style-preview-${style.code}'),
      );
      expect(
        find.descendant(of: previewFinder, matching: find.byType(Image)),
        findsOneWidget,
      );
      final preview = tester.getRect(previewFinder);
      expect(preview.top, greaterThanOrEqualTo(0));
      expect(preview.bottom, lessThanOrEqualTo(900));
    }
    expect(
      find.byKey(const ValueKey('settings-player-style-option-spotify-music')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-player-style-option-apple-music')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-player-style-gallery')),
      findsOneWidget,
    );
    expect(saved, [PlayerStyle.appleMusic]);
    final semantics = tester.ensureSemantics();
    try {
      await tester.pump();
      const strings = AppStrings(AppLanguage.spanish);
      for (final selection in [
        (
          code: 'apple-music',
          label: strings.playerStyleAppleMusic,
          selected: true,
        ),
        (
          code: 'bstream-music',
          label: strings.playerStyleBStreamMusic,
          selected: false,
        ),
      ]) {
        final card = find.byKey(
          ValueKey('settings-player-style-option-${selection.code}'),
        );
        expect(
          tester.getSemantics(card),
          matchesSemantics(
            label: selection.label,
            isButton: true,
            isSelected: selection.selected,
            hasSelectedState: true,
            hasTapAction: true,
          ),
        );
        final material = tester.widget<Material>(
          find.descendant(of: card, matching: find.byType(Material)).first,
        );
        final border = (material.shape! as RoundedRectangleBorder).side;
        expect(border.width, selection.selected ? 2 : 1);
      }
    } finally {
      semantics.dispose();
    }
    expect(
      find.byKey(const ValueKey('settings-player-style-apply')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('settings-player-style-cancel')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-player-style-option-spotify-music')),
    );
    await tester.pumpAndSettle();
    expect(saved, [PlayerStyle.appleMusic, PlayerStyle.spotifyMusic]);
    expect(
      find.byKey(const ValueKey('settings-player-style-gallery')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('gallery fits complete previews into responsive compact rows', (
    tester,
  ) async {
    _configureView(tester, const Size(320, 720));
    for (final scenario in const [
      (size: Size(320, 720), columns: 2),
      (size: Size(390, 820), columns: 2),
      (size: Size(430, 900), columns: 2),
      (size: Size(768, 1024), columns: 3),
      (size: Size(1280, 900), columns: 4),
    ]) {
      tester.view.physicalSize = scenario.size;
      final saved = <PlayerStyle>[];
      await tester.pumpWidget(
        _harness(
          key: ValueKey(scenario.size),
          onChanged: (value) => saved.add(value),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      final cards = [
        for (final code in [
          'bstream-music',
          'apple-music',
          'classic-vinyl',
          'spotify-music',
        ])
          find.byKey(ValueKey('settings-player-style-option-$code')),
      ];
      final cardRects = [for (final card in cards) tester.getRect(card)];
      for (var index = 0; index < cards.length; index++) {
        final card = cardRects[index];
        expect(card.left, greaterThanOrEqualTo(12));
        expect(card.right, lessThanOrEqualTo(scenario.size.width - 12));
        expect(card.width, lessThanOrEqualTo(220));
        expect(card.height, closeTo(cardRects.first.height, .001));
        if (index < scenario.columns) {
          expect(card.top, closeTo(cardRects.first.top, .001));
        } else {
          expect(card.top, greaterThan(cardRects.first.bottom));
        }
        final preview = tester.getRect(
          find.byKey(
            ValueKey('player-style-preview-${PlayerStyle.values[index].code}'),
          ),
        );
        expect(preview.width / preview.height, closeTo(380 / 800, .001));
        expect(preview.left, greaterThanOrEqualTo(card.left));
        expect(preview.right, lessThanOrEqualTo(card.right));
        expect(preview.top, greaterThanOrEqualTo(card.top));
        expect(preview.bottom, lessThan(card.bottom));
        expect(preview.width / card.width, greaterThan(.8));
      }
      final appleLabel = find.descendant(
        of: cards[1],
        matching: find.text(
          const AppStrings(AppLanguage.spanish).playerStyleAppleMusic,
        ),
      );
      await Scrollable.ensureVisible(tester.element(appleLabel), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(appleLabel);
      await tester.pumpAndSettle();
      expect(saved, [PlayerStyle.appleMusic]);
      expect(tester.takeException(), isNull, reason: '${scenario.size}');
    }
  });

  testWidgets('Back preserves the style already selected', (tester) async {
    _configureView(tester, const Size(1280, 900));
    final saved = <PlayerStyle>[];
    await tester.pumpWidget(_harness(onChanged: (value) => saved.add(value)));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-player-style-option-classic-vinyl')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('gallery-back')));
    await tester.pumpAndSettle();
    expect(saved, [PlayerStyle.classicVinyl]);
    expect(find.text('Open'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed save keeps the previous selection and can be retried', (
    tester,
  ) async {
    _configureView(tester, const Size(1280, 900));
    var attempts = 0;
    await tester.pumpWidget(
      _harness(
        onChanged: (_) {
          attempts++;
          throw StateError('save failed');
        },
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final apple = find.byKey(
      const ValueKey('settings-player-style-option-apple-music'),
    );
    await tester.tap(apple);
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(
      find.byKey(const ValueKey('settings-player-style-gallery')),
      findsOneWidget,
    );
    await tester.tap(apple);
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'full previews remain usable on narrow screens with large text in $brightness',
      (tester) async {
        _configureView(tester, const Size(320, 720));
        PlayerStyle? saved;
        await tester.pumpWidget(
          _harness(
            brightness: brightness,
            textScale: 2,
            onChanged: (value) => saved = value,
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final vinyl = find.byKey(
          const ValueKey('settings-player-style-option-classic-vinyl'),
        );
        final preview = find.byKey(
          const ValueKey('player-style-preview-classicVinyl'),
        );
        final bstream = find.byKey(
          const ValueKey('settings-player-style-option-bstream-music'),
        );
        final apple = find.byKey(
          const ValueKey('settings-player-style-option-apple-music'),
        );
        expect(
          tester.getRect(apple).top,
          greaterThan(tester.getRect(bstream).bottom),
        );
        await Scrollable.ensureVisible(tester.element(preview), alignment: .5);
        await tester.pumpAndSettle();
        expect(tester.getRect(preview).top, greaterThanOrEqualTo(0));
        expect(tester.getRect(preview).bottom, lessThanOrEqualTo(720));
        final label = find.descendant(
          of: vinyl,
          matching: find.text(
            const AppStrings(AppLanguage.spanish).playerStyleClassicVinyl,
          ),
        );
        await Scrollable.ensureVisible(tester.element(label), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(label);
        await tester.pumpAndSettle();
        expect(saved, PlayerStyle.classicVinyl);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

void _configureView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Widget _harness({
  Key? key,
  required ValueChanged<PlayerStyle> onChanged,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) => MaterialApp(
  key: key,
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: brightness,
    ),
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: FilledButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (pageContext) => Scaffold(
                body: PlayerStyleGalleryPage(
                  style: PlayerStyle.bstreamMusic,
                  strings: const AppStrings(AppLanguage.spanish),
                  bottomContentPadding: 0,
                  header: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('gallery-back'),
                        onPressed: () => Navigator.of(pageContext).pop(),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      const Text('Estilos'),
                    ],
                  ),
                  onChanged: (value) async => onChanged(value),
                ),
              ),
            ),
          ),
          child: const Text('Open'),
        ),
      ),
    ),
  ),
);
