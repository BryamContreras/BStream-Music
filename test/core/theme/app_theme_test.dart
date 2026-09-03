import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('white is the first and initial accent option', () {
    expect(AppAccent.values.first, AppAccent.white);
    expect(AppAccent.fromCode(null), AppAccent.white);
    expect(AppAccent.fromCode('unknown'), AppAccent.white);
  });

  test('green remains available as an explicit saved accent', () {
    expect(AppAccent.fromCode('green'), AppAccent.green);
  });

  test('expanded palette exposes eighteen persistent accent codes', () {
    expect(AppAccent.values, hasLength(18));
    expect(AppAccent.fromCode('cyan'), AppAccent.cyan);
    expect(AppAccent.fromCode('indigo'), AppAccent.indigo);
    expect(AppAccent.fromCode('lime'), AppAccent.lime);
    expect(AppAccent.fromCode('mint'), AppAccent.mint);
    expect(AppAccent.fromCode('magenta'), AppAccent.magenta);
    expect(AppAccent.fromCode('coral'), AppAccent.coral);
    expect(AppAccent.fromCode('brown'), AppAccent.brown);
    expect(AppAccent.fromCode('amber'), AppAccent.brown);
    expect(AppAccent.fromCode('lavender'), AppAccent.lavender);
    expect(AppAccent.fromCode('ocean'), AppAccent.ocean);
    expect(
      AppAccent.values.map((accent) => accent.code).toSet(),
      hasLength(AppAccent.values.length),
    );
    expect(
      AppAccent.values.map((accent) => accent.code),
      isNot(contains('amber')),
    );
  });

  test('new accent palettes keep their curated colors and localized names', () {
    expect(AppAccent.mint.seedColor, const Color(0xFF6EE7B7));
    expect(AppAccent.mint.darkColor, const Color(0xFF047857));
    expect(AppAccent.magenta.seedColor, const Color(0xFFD946EF));
    expect(AppAccent.magenta.darkColor, const Color(0xFF86198F));
    expect(AppAccent.coral.seedColor, const Color(0xFFFF6F61));
    expect(AppAccent.coral.darkColor, const Color(0xFFB8322A));
    expect(AppAccent.brown.seedColor, const Color(0xFF8D6E63));
    expect(AppAccent.brown.darkColor, const Color(0xFF4E342E));
    expect(AppAccent.lavender.seedColor, const Color(0xFFC4B5FD));
    expect(AppAccent.lavender.darkColor, const Color(0xFF6D28D9));
    expect(AppAccent.ocean.seedColor, const Color(0xFF38BDF8));
    expect(AppAccent.ocean.darkColor, const Color(0xFF0369A1));

    const spanish = AppStrings(AppLanguage.spanish);
    const english = AppStrings(AppLanguage.english);
    expect(spanish.accentLabel(AppAccent.mint), 'Menta');
    expect(english.accentLabel(AppAccent.mint), 'Mint');
    expect(spanish.accentLabel(AppAccent.magenta), 'Magenta');
    expect(english.accentLabel(AppAccent.coral), 'Coral');
    expect(spanish.accentLabel(AppAccent.brown), 'Marrón');
    expect(english.accentLabel(AppAccent.brown), 'Brown');
    expect(english.accentLabel(AppAccent.lavender), 'Lavender');
    expect(spanish.accentLabel(AppAccent.ocean), 'Océano');
    expect(english.accentLabel(AppAccent.ocean), 'Ocean');
  });

  testWidgets('dark full-player control uses the selected accent', (
    tester,
  ) async {
    late Color background;
    late Color disabledBackground;
    late Color title;
    late Color contentHeading;
    late Color contentTitle;
    late Color contentSubtitle;
    late Color neutralTitle;
    late Color onSurfaceVariant;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          extensions: const [AppAccentTheme(accent: AppAccent.blue)],
        ),
        home: Builder(
          builder: (context) {
            background = AppColors.playbackPrimaryBackgroundFor(context);
            disabledBackground = AppColors.playbackPrimaryDisabledBackgroundFor(
              context,
            );
            title = AppColors.playbackTitleFor(context);
            contentHeading = AppColors.contentHeadingFor(context);
            contentTitle = AppColors.contentTitleFor(context);
            contentSubtitle = AppColors.contentSubtitleFor(context);
            neutralTitle = AppColors.neutralTitleFor(context);
            final colors = Theme.of(context).colorScheme;
            onSurfaceVariant = colors.onSurfaceVariant;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(background, AppAccent.blue.seedColor);
    expect(
      disabledBackground,
      AppAccent.blue.seedColor.withValues(alpha: 0.38),
    );
    expect(
      title,
      Color.alphaBlend(
        AppAccent.blue.seedColor.withValues(alpha: 0.02),
        Colors.white,
      ),
    );
    expect(
      contentHeading,
      Color.alphaBlend(
        AppAccent.blue.seedColor.withValues(alpha: 0.04),
        Colors.white,
      ),
    );
    expect(
      contentTitle,
      Color.alphaBlend(
        AppAccent.blue.seedColor.withValues(alpha: 0.03),
        Colors.white,
      ),
    );
    expect(
      contentSubtitle,
      Color.alphaBlend(
        AppAccent.blue.seedColor.withValues(alpha: 0.02),
        onSurfaceVariant,
      ),
    );
    expect(neutralTitle, Colors.white);
    expect(contentTitle, isNot(AppAccent.blue.seedColor));
  });

  testWidgets(
    'content cards can opt out of Liquid Glass without changing other modes',
    (tester) async {
      for (final mode in SurfaceBackgroundMode.values) {
        late Color inheritedSurface;
        late Color solidSurface;
        late Color inheritedBorder;
        late Color solidBorder;
        late Color inheritedHomeSurface;
        late Color solidHomeSurface;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              scaffoldBackgroundColor: const Color(0xFF030504),
              extensions: [
                const AppAccentTheme(accent: AppAccent.blue),
                AppSurfaceTheme(backgroundMode: mode),
              ],
            ),
            home: Builder(
              builder: (context) {
                inheritedSurface = AppColors.cardSurfaceFor(context);
                solidSurface = AppColors.cardSurfaceFor(
                  context,
                  solidInLiquidGlass: true,
                );
                inheritedBorder = AppColors.cardBorderFor(context);
                solidBorder = AppColors.cardBorderFor(
                  context,
                  solidInLiquidGlass: true,
                );
                inheritedHomeSurface = AppColors.homeCardSurfaceFor(context);
                solidHomeSurface = AppColors.homeCardSurfaceFor(
                  context,
                  solidInLiquidGlass: true,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        if (mode.isLiquidGlass) {
          expect(inheritedSurface.a, lessThan(1));
          expect(inheritedBorder.a, lessThan(1));
          expect(inheritedHomeSurface.a, lessThan(1));
          expect(solidSurface.a, 1);
          expect(solidBorder.a, 1);
          expect(solidHomeSurface, solidSurface);
        } else {
          expect(solidSurface, inheritedSurface);
          expect(solidBorder, inheritedBorder);
          expect(solidHomeSurface, inheritedHomeSurface);
        }
      }
    },
  );
}
