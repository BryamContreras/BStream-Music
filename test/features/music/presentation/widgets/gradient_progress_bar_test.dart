import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/features/music/presentation/widgets/gradient_progress_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'determinate fill uses its percentage and full height on ${platform.name}',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          Future<void> pumpBar(double value) {
            return tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(platform: platform),
                home: Center(
                  child: SizedBox(
                    width: 200,
                    child: GradientProgressBar(value: value, height: 10),
                  ),
                ),
              ),
            );
          }

          await pumpBar(0.22);
          await tester.pumpAndSettle();

          final progressBar = tester.widget<GradientProgressBar>(
            find.byType(GradientProgressBar),
          );
          expect(progressBar.colors, AppColors.downloadGradient);

          final fill = find.descendant(
            of: find.byType(FractionallySizedBox),
            matching: find.byType(DecoratedBox),
          );
          var fillSize = tester.getSize(fill);
          expect(fillSize.width, closeTo(44, 0.1));
          expect(fillSize.height, 10);

          await pumpBar(0.65);
          await tester.pumpAndSettle();

          fillSize = tester.getSize(fill);
          expect(fillSize.width, closeTo(130, 0.1));
          expect(fillSize.height, 10);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
