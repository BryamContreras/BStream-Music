import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
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

  test('expanded palette exposes twelve persistent accent codes', () {
    expect(AppAccent.values, hasLength(12));
    expect(AppAccent.fromCode('cyan'), AppAccent.cyan);
    expect(AppAccent.fromCode('indigo'), AppAccent.indigo);
    expect(AppAccent.fromCode('lime'), AppAccent.lime);
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
}
