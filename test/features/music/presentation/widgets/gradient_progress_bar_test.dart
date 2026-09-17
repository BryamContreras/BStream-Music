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

          final bar = find.byType(GradientProgressBar);
          final fill = find.descendant(
            of: bar,
            matching: find.byType(DecoratedBox),
          );
          final fillTransform = find.descendant(
            of: bar,
            matching: find.byType(Transform),
          );
          var transform = tester.widget<Transform>(fillTransform);
          var fillSize = tester.getSize(fill);
          expect(fillSize.width, 200);
          expect(fillSize.height, 10);
          expect(transform.transform.storage[0], closeTo(0.22, 0.001));
          expect(
            find.descendant(of: bar, matching: find.byType(RepaintBoundary)),
            findsOneWidget,
          );

          await pumpBar(0.65);
          await tester.pumpAndSettle();

          transform = tester.widget<Transform>(fillTransform);
          fillSize = tester.getSize(fill);
          expect(fillSize.width, 200);
          expect(fillSize.height, 10);
          expect(transform.transform.storage[0], closeTo(0.65, 0.001));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets('determinate fill animates by paint transform, not relayout', (
    tester,
  ) async {
    Future<void> pumpBar(double value) {
      return tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 200,
              child: GradientProgressBar(value: value, height: 8),
            ),
          ),
        ),
      );
    }

    await pumpBar(0.2);
    await tester.pumpAndSettle();

    final bar = find.byType(GradientProgressBar);
    final fill = find.descendant(of: bar, matching: find.byType(DecoratedBox));
    await pumpBar(0.8);
    final fillWidget = tester.widget<DecoratedBox>(fill);
    await tester.pump(const Duration(milliseconds: 110));

    final transform = tester.widget<Transform>(
      find.descendant(of: bar, matching: find.byType(Transform)),
    );
    expect(transform.transform.storage[0], greaterThan(0.2));
    expect(transform.transform.storage[0], lessThan(0.8));
    expect(tester.getSize(fill), const Size(200, 8));
    expect(tester.widget<DecoratedBox>(fill), same(fillWidget));
  });

  testWidgets('indeterminate segment translates without rebuilding its track', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 200,
            child: GradientProgressBar(
              value: null,
              height: 10,
              indeterminate: true,
            ),
          ),
        ),
      ),
    );

    final bar = find.byType(GradientProgressBar);
    final transformFinder = find.descendant(
      of: bar,
      matching: find.byType(Transform),
    );
    final fill = find.descendant(of: bar, matching: find.byType(DecoratedBox));
    final fillWidget = tester.widget<DecoratedBox>(fill);
    final initialTransform = tester.widget<Transform>(transformFinder);
    final initialOffset = initialTransform.transform.storage[12];

    expect(tester.getSize(fill), const Size(68, 10));

    await tester.pump(const Duration(milliseconds: 225));

    final movedTransform = tester.widget<Transform>(transformFinder);
    expect(movedTransform.transform.storage[12], greaterThan(initialOffset));
    expect(tester.getSize(fill), const Size(68, 10));
    expect(tester.widget<DecoratedBox>(fill), same(fillWidget));
  });

  testWidgets('reduced motion freezes indeterminate progress visibly', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Center(
            child: SizedBox(
              width: 200,
              child: GradientProgressBar(
                value: null,
                height: 10,
                indeterminate: true,
              ),
            ),
          ),
        ),
      ),
    );

    final transformFinder = find.descendant(
      of: find.byType(GradientProgressBar),
      matching: find.byType(Transform),
    );
    final initialOffset = tester
        .widget<Transform>(transformFinder)
        .transform
        .storage[12];

    expect(initialOffset, closeTo(66, 0.001));
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.widget<Transform>(transformFinder).transform.storage[12],
      initialOffset,
    );
  });

  testWidgets('TickerMode pauses the indeterminate controller', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(
          enabled: false,
          child: Center(
            child: SizedBox(
              width: 200,
              child: GradientProgressBar(
                value: null,
                height: 10,
                indeterminate: true,
              ),
            ),
          ),
        ),
      ),
    );

    final transformFinder = find.descendant(
      of: find.byType(GradientProgressBar),
      matching: find.byType(Transform),
    );
    final initialOffset = tester
        .widget<Transform>(transformFinder)
        .transform
        .storage[12];

    await tester.pump(const Duration(seconds: 2));
    expect(
      tester.widget<Transform>(transformFinder).transform.storage[12],
      initialOffset,
    );
  });
}
