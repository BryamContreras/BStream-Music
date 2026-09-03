import 'dart:ui' show SemanticsRole;

import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/features/music/presentation/widgets/glass_popup_menu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

enum _TestAction { first, second }

void main() {
  testWidgets('renders one clipped glass surface and keeps item semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    _TestAction? selected;

    await tester.pumpWidget(
      _menuHarness(
        textDirection: TextDirection.rtl,
        onSelected: (value) => selected = value,
      ),
    );

    final anchor = find.byKey(const ValueKey('test-glass-menu-anchor'));
    await tester.tap(anchor);
    await tester.pumpAndSettle();

    final backdrop = find.byKey(const ValueKey('glass-popup-menu-backdrop'));
    final surface = find.byKey(const ValueKey('glass-popup-menu-surface'));
    expect(backdrop, findsOneWidget);
    expect(surface, findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(PopupMenuItem<_TestAction>), findsNWidgets(2));

    final decoration =
        tester.widget<DecoratedBox>(surface).decoration as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.colors, hasLength(3));
    expect(gradient.colors.every((color) => color.a < 1), isTrue);
    expect(gradient.colors[1], isNot(gradient.colors.first));

    final popupMaterial = tester
        .widgetList<Material>(
          find.ancestor(of: surface, matching: find.byType(Material)),
        )
        .firstWhere((material) => material.color == Colors.transparent);
    expect(popupMaterial.surfaceTintColor, Colors.transparent);
    expect(popupMaterial.clipBehavior, Clip.none);
    expect(popupMaterial.elevation, 0);
    expect(popupMaterial.shadowColor, Colors.transparent);

    final surfaceRect = tester.getRect(surface);
    final anchorRect = tester.getRect(anchor);
    // Flutter intentionally lets an "under" popup overlap the anchor by the
    // menu's vertical inset. Verify the route remains anchored below its top
    // edge instead of baking that framework inset into this test.
    expect(surfaceRect.top, greaterThan(anchorRect.top));
    expect(surfaceRect.bottom, greaterThan(anchorRect.bottom));
    expect(surfaceRect.left, greaterThanOrEqualTo(8));
    expect(
      surfaceRect.right,
      lessThanOrEqualTo(tester.view.physicalSize.width + 0.1),
    );

    expect(
      find.semantics.byPredicate(
        (node) => node.getSemanticsData().role == SemanticsRole.menu,
      ),
      findsOne,
    );
    expect(
      find.semantics.byPredicate(
        (node) => node.getSemanticsData().role == SemanticsRole.menuItem,
      ),
      findsExactly(2),
    );

    await tester.tap(find.text('Segunda'));
    await tester.pumpAndSettle();
    expect(selected, _TestAction.second);
    expect(surface, findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('keeps keyboard focus traversal and selection', (tester) async {
    _TestAction? selected;

    await tester.pumpWidget(
      _menuHarness(onSelected: (value) => selected = value),
    );
    await tester.tap(find.byKey(const ValueKey('test-glass-menu-anchor')));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(selected, _TestAction.first);
    expect(
      find.byKey(const ValueKey('glass-popup-menu-surface')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('liquid menu uses one reflective perimeter sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      _menuHarness(
        backgroundMode: SurfaceBackgroundMode.liquidGlass,
        onSelected: (_) {},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('test-glass-menu-anchor')));
    await tester.pumpAndSettle();

    final liquidGlass = find.byType(LiquidGlassSurface);
    expect(liquidGlass, findsOneWidget);
    final surface = tester.widget<LiquidGlassSurface>(liquidGlass);
    expect(surface.blurSigma, 8);
    expect(surface.intensity, 1);
    expect(surface.edgeTreatment, LiquidGlassEdgeTreatment.perimeter);
    expect(find.byKey(LiquidGlassSurface.adaptiveEdgeKey), findsNothing);
    expect(find.byKey(LiquidGlassSurface.opticsKey), findsOneWidget);
    expect(find.byKey(LiquidGlassSurface.shadowKey), findsOneWidget);

    final panel = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('glass-popup-menu-surface')),
    );
    final decoration = panel.decoration as BoxDecoration;
    expect(decoration.color, Colors.transparent);
    expect(decoration.gradient, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('liquid menu energizes its glass while the route animates', (
    tester,
  ) async {
    await tester.pumpWidget(
      _menuHarness(
        backgroundMode: SurfaceBackgroundMode.liquidGlass,
        onSelected: (_) {},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('test-glass-menu-anchor')));
    await tester.pump();

    LiquidGlassSurface glass() =>
        tester.widget<LiquidGlassSurface>(find.byType(LiquidGlassSurface));
    expect(glass().backdropMotion, isTrue);

    await tester.pumpAndSettle();
    expect(glass().backdropMotion, isFalse);

    await tester.tap(find.text('Primera'));
    await tester.pump();
    expect(find.byType(LiquidGlassSurface), findsOneWidget);
    expect(glass().backdropMotion, isTrue);

    await tester.pumpAndSettle();
    expect(find.byType(LiquidGlassSurface), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _menuHarness({
  required ValueChanged<_TestAction> onSelected,
  TextDirection textDirection = TextDirection.ltr,
  SurfaceBackgroundMode backgroundMode = SurfaceBackgroundMode.transparent,
}) {
  final theme = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    extensions: <ThemeExtension<dynamic>>[
      const AppAccentTheme(accent: AppAccent.blue),
      AppSurfaceTheme(backgroundMode: backgroundMode),
    ],
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xE6101112),
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0x55FFFFFF)),
      ),
    ),
  );

  return MaterialApp(
    theme: theme,
    builder: (context, child) =>
        Directionality(textDirection: textDirection, child: child!),
    home: Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF0E3A5C), Color(0xFF551A4A)],
                ),
              ),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.topEnd,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: GlassPopupMenuButton<_TestAction>(
                key: const ValueKey('test-glass-menu-anchor'),
                tooltip: 'Opciones',
                position: PopupMenuPosition.under,
                requestFocus: true,
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: onSelected,
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _TestAction.first,
                    child: Text('Primera'),
                  ),
                  PopupMenuItem(
                    value: _TestAction.second,
                    child: Text('Segunda'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
