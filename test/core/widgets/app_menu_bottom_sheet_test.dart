import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/app_menu_bottom_sheet.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cover = Color(0xFFDD974B);
  testWidgets(
    'provided playback background replaces the solid tint without affecting menu geometry',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          background: const ColoredBox(
            key: ValueKey('fixture-menu-photographic-background'),
            color: Colors.black,
          ),
        ),
      );
      await _open(tester);
      expect(_decoration(tester).gradient, isNull);
      final background = find.byKey(
        const ValueKey('fixture-menu-photographic-background'),
      );
      final surface = find.byKey(const ValueKey('app-menu-sheet-surface'));
      final surfaceSize = tester.getSize(surface);
      expect(
        tester.getSize(background),
        Size(surfaceSize.width - 2, surfaceSize.height - 2),
        reason:
            'The image fills the interior inside the one-pixel menu border.',
      );
      expect(
        find.ancestor(of: background, matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
      expect(
        find.ancestor(of: background, matching: find.byType(IgnorePointer)),
        findsWidgets,
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in SurfaceBackgroundMode.values) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '${mode.name} menu uses the cover, retains $brightness and app font',
        (tester) async {
          await tester.pumpWidget(
            _harness(mode: mode, brightness: brightness, artworkColor: cover),
          );
          await _open(tester);
          final content = find.byKey(const ValueKey('test-menu-content'));
          final context = tester.element(content);
          expect(Theme.of(context).brightness, brightness);
          expect(Theme.of(context).textTheme.bodyMedium?.fontFamily, 'Lora');
          expect(Theme.of(context).extension<AppAccentTheme>(), isNull);
          expect(
            AppColors.surfaceBackgroundModeFor(context),
            SurfaceBackgroundMode.accent,
          );
          expect(
            find.byKey(const ValueKey('app-menu-sheet-drag-handle')),
            findsOneWidget,
          );
          expect(find.byType(BackdropFilter), findsNothing);
          expect(find.byType(LiquidGlassSurface), findsNothing);
          final decoration = _decoration(tester);
          final gradient = decoration.gradient! as LinearGradient;
          for (final color in gradient.colors) {
            expect(
              color.a,
              1,
              reason: 'An opaque menu must not leak the player controls.',
            );
            expect(
              HSLColor.fromColor(color).hue,
              closeTo(HSLColor.fromColor(cover).hue, 1),
            );
          }
          final foreground = Theme.of(context).colorScheme.onSurface;
          expect(
            _contrast(foreground, gradient.colors.first),
            greaterThan(4.5),
          );
          expect(_contrast(foreground, gradient.colors.last), greaterThan(4.5));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'accent and Liquid Glass changes do not change a cover-colored menu',
    (tester) async {
      final gradients = <Gradient?>[];
      final primary = <Color>[];
      for (final accent in [AppAccent.red, AppAccent.blue]) {
        for (final mode in SurfaceBackgroundMode.values) {
          await tester.pumpWidget(
            _harness(
              key: ValueKey('$accent-$mode'),
              accent: accent,
              mode: mode,
              artworkColor: cover,
            ),
          );
          await _open(tester);
          gradients.add(_decoration(tester).gradient);
          primary.add(
            Theme.of(
              tester.element(find.byKey(const ValueKey('test-menu-content'))),
            ).colorScheme.primary,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      }
      expect(gradients.toSet(), hasLength(1));
      expect(primary.toSet(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('different covers give different menu backgrounds', (
    tester,
  ) async {
    final gradients = <Gradient?>[];
    for (final color in [Colors.orange, Colors.green]) {
      await tester.pumpWidget(
        _harness(key: ValueKey(color), artworkColor: color),
      );
      await _open(tester);
      gradients.add(_decoration(tester).gradient);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
    expect(gradients[0], isNot(gradients[1]));
  });

  testWidgets(
    'missing and grayscale covers keep a neutral background and controls',
    (tester) async {
      for (final color in [null, Colors.grey]) {
        await tester.pumpWidget(
          _harness(
            key: ValueKey(color),
            artworkColor: color,
            mode: SurfaceBackgroundMode.liquidGlass,
          ),
        );
        await _open(tester);
        final gradient = _decoration(tester).gradient! as LinearGradient;
        for (final color in gradient.colors) {
          expect(color.r, color.g);
          expect(color.g, color.b);
        }
        final primary = Theme.of(
          tester.element(find.byKey(const ValueKey('test-menu-content'))),
        ).colorScheme.primary;
        expect(primary.r, primary.g);
        expect(primary.g, primary.b);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    },
  );

  for (final mode in SurfaceBackgroundMode.values) {
    testWidgets(
      '${mode.name} menu scrolls in compact landscape at text scale 3',
      (tester) async {
        tester.view
          ..physicalSize = const Size(568, 320)
          ..devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 3;
        addTearDown(() {
          tester.view
            ..resetPhysicalSize()
            ..resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        await tester.pumpWidget(
          _harness(mode: mode, artworkColor: cover, longContent: true),
        );
        await _open(tester);
        final sheet = find.byKey(const ValueKey('app-menu-sheet-drag-handle'));
        expect(tester.getTopLeft(sheet).dy, greaterThanOrEqualTo(0));
        expect(
          tester.getSize(find.byKey(const ValueKey('test-menu-content'))).width,
          lessThanOrEqualTo(480),
        );
        await tester.ensureVisible(find.text('Ultima accion'));
        await tester.pump();
        expect(find.text('Ultima accion').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

BoxDecoration _decoration(WidgetTester tester) =>
    tester
            .widget<AnimatedContainer>(
              find.byKey(const ValueKey('app-menu-sheet-surface')),
            )
            .decoration!
        as BoxDecoration;

double _contrast(Color foreground, Color background) {
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  return a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('Abrir'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Widget _harness({
  Key? key,
  SurfaceBackgroundMode mode = SurfaceBackgroundMode.accent,
  Brightness brightness = Brightness.dark,
  AppAccent accent = AppAccent.red,
  Color? artworkColor,
  bool longContent = false,
  Widget? background,
}) => MaterialApp(
  key: key,
  theme: ThemeData(
    platform: TargetPlatform.android,
    brightness: brightness,
    colorSchemeSeed: accent.seedColor,
    fontFamily: 'Lora',
    extensions: [
      AppAccentTheme(accent: accent),
      AppSurfaceTheme(backgroundMode: mode),
    ],
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          onPressed: () => showAppMenuBottomSheet<void>(
            context: context,
            artworkColor: artworkColor,
            surfaceBuilder: background == null
                ? null
                : (_, child) => AppMenuSheetSurface(
                    artworkColor: artworkColor,
                    background: background,
                    child: child,
                  ),
            builder: (context) => SingleChildScrollView(
              key: const ValueKey('test-menu-content'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (longContent)
                    for (var i = 0; i < 12; i++)
                      ListTile(title: Text('Accion larga $i')),
                  const ListTile(title: Text('Ultima accion')),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ),
          ),
          child: const Text('Abrir'),
        ),
      ),
    ),
  ),
);
