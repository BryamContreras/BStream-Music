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

  testWidgets('dark full-player control uses the selected accent', (
    tester,
  ) async {
    late Color background;
    late Color disabledBackground;
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
  });
}
