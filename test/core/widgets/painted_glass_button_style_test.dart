import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/core/widgets/painted_glass_button_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final highContrast in [false, true]) {
      testWidgets(
        'painted and live glass share the $brightness tint (contrast=$highContrast)',
        (tester) async {
          Color? tint;
          await tester.pumpWidget(
            _frame(
              brightness: brightness,
              highContrast: highContrast,
              builder: (context) {
                tint = LiquidGlassSurface.materialTintFor(
                  context,
                  intensity: LiquidGlassSurface.chromeIntensity,
                  materialOpacity: LiquidGlassSurface.chromeOpacity,
                );
                return const SizedBox(
                  height: 48,
                  width: 200,
                  child: LiquidGlassSurface(
                    intensity: LiquidGlassSurface.chromeIntensity,
                    materialOpacity: LiquidGlassSurface.chromeOpacity,
                    child: Text('Live glass'),
                  ),
                );
              },
            ),
          );
          final decoration =
              tester
                      .widget<DecoratedBox>(
                        find.byKey(LiquidGlassSurface.surfaceTintKey),
                      )
                      .decoration
                  as BoxDecoration;
          expect(decoration.color, tint);
          final dark = brightness == Brightness.dark;
          final expectedAlpha = dark ? 0.339184 : 0.31552;
          expect(
            tint!.a,
            closeTo(expectedAlpha * (highContrast ? 1.16 : 1), 0.000001),
          );
          expect(
            tint!.withValues(alpha: 1),
            dark ? const Color(0xFF101010) : const Color(0xFFFAFAFA),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '$brightness buttons paint glass without backdrop or optical layers',
      (tester) async {
        var presses = 0;
        await tester.pumpWidget(
          _frame(
            brightness: brightness,
            builder: (context) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  key: const ValueKey('painted-play'),
                  style: paintedGlassButtonStyle(context),
                  onPressed: () => presses++,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Play'),
                ),
                FilledButton.icon(
                  key: const ValueKey('painted-disabled'),
                  style: paintedGlassButtonStyle(context),
                  onPressed: null,
                  icon: const Icon(Icons.playlist_add_rounded),
                  label: const Text('Add to playlist'),
                ),
                IconButton(
                  key: const ValueKey('painted-round'),
                  style: paintedGlassButtonStyle(context, circular: true),
                  onPressed: () => presses++,
                  icon: const Icon(Icons.play_arrow_rounded),
                ),
              ],
            ),
          ),
        );

        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(ImageFiltered), findsNothing);
        expect(find.byType(ShaderMask), findsNothing);
        expect(find.byType(LiquidGlassSurface), findsNothing);
        expect(find.byKey(LiquidGlassSurface.opticsKey), findsNothing);
        expect(find.byKey(LiquidGlassSurface.shadowKey), findsNothing);
        final play = find.byKey(const ValueKey('painted-play'));
        final round = find.byKey(const ValueKey('painted-round'));
        final style = tester.widget<FilledButton>(play).style!;
        expect(style.backgroundColor!.resolve({}), Colors.transparent);
        expect(style.elevation!.resolve({}), 0);
        expect(style.shape!.resolve({}), isA<StadiumBorder>());
        expect(
          tester.widget<IconButton>(round).style!.shape!.resolve({}),
          isA<CircleBorder>(),
        );
        expect(tester.getSize(play).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(round).height, greaterThanOrEqualTo(48));
        final colors = Theme.of(tester.element(play)).colorScheme;
        expect(style.foregroundColor!.resolve({}), colors.onSurface);
        expect(
          style.foregroundColor!.resolve({WidgetState.disabled}),
          colors.onSurface.withValues(alpha: 0.38),
        );
        final decoration = tester.widget<DecoratedBox>(
          find.descendant(of: play, matching: find.byType(DecoratedBox)),
        );
        final fill = decoration.decoration as BoxDecoration;
        expect(fill.gradient, isA<LinearGradient>());
        expect(
          fill.gradient!.colors.every((color) => color.a > 0 && color.a < 0.6),
          isTrue,
          reason:
              'The material remains translucent rather than an opaque fill.',
        );

        await tester.tap(play);
        await tester.tap(round);
        await tester.tap(find.byKey(const ValueKey('painted-disabled')));
        expect(presses, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Widget _frame({
  required Brightness brightness,
  required WidgetBuilder builder,
  bool highContrast = false,
}) => MaterialApp(
  theme: ThemeData(
    brightness: brightness,
    extensions: const [
      AppSurfaceTheme(backgroundMode: SurfaceBackgroundMode.liquidGlass),
    ],
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(highContrast: highContrast),
    child: child!,
  ),
  home: Scaffold(body: Builder(builder: builder)),
);
