import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/app_shared_widgets.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('inset header keeps one fill authority in each surface mode', (
    tester,
  ) async {
    for (final mode in SurfaceBackgroundMode.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: [AppSurfaceTheme(backgroundMode: mode)]),
          home: const Scaffold(
            body: AppInsetHeaderSurface(child: Text('Header')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final surfaceFinder = find.byKey(
        const ValueKey('app-inset-header-surface'),
      );
      final decoration =
          tester.widget<DecoratedBox>(surfaceFinder.first).decoration
              as BoxDecoration;
      if (mode.isLiquidGlass) {
        expect(decoration.color, isNull);
        expect(decoration.gradient, isNull);
        final glass = tester.widget<LiquidGlassSurface>(
          find.byKey(const ValueKey('app-inset-header-liquid-glass')),
        );
        expect(glass.intensity, 1.02);
      } else {
        expect(decoration.gradient, isA<LinearGradient>());
        expect(decoration.color, mode.usesBackdrop ? isNull : isNotNull);
      }
    }
  });
}
