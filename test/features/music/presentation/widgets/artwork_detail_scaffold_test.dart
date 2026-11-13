import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/core/widgets/app_shared_widgets.dart';
import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/core/widgets/painted_glass_button_style.dart';
import 'package:bstream_music/features/music/presentation/widgets/artwork_detail_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('circular back button returns from the artwork route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const ArtworkDetailScaffold(
                    body: ColoredBox(color: Colors.teal),
                    bottomNavigationBar: SizedBox.shrink(),
                    backButtonKey: ValueKey('artwork-back'),
                  ),
                ),
              ),
              child: const Text('Open artist'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open artist'));
    await tester.pumpAndSettle();
    final back = find.byKey(const ValueKey('artwork-back'));
    expect(tester.getSize(back), const Size.square(48));
    expect(
      tester.widget<IconButton>(back).style!.shape!.resolve({}),
      isA<CircleBorder>(),
    );
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byType(ArtworkDetailScaffold), findsNothing);
    expect(find.text('Open artist'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'paints behind the $brightness system bar while controls avoid cutouts',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.fromLTRB(20, 44, 0, 0),
                viewPadding: const EdgeInsets.fromLTRB(20, 44, 0, 0),
              ),
              child: child!,
            ),
            home: const ArtworkDetailScaffold(
              body: ColoredBox(
                key: ValueKey('full-bleed-body'),
                color: Colors.teal,
              ),
              bottomNavigationBar: SizedBox.shrink(),
              backButtonKey: ValueKey('artwork-back'),
            ),
          ),
        );
        expect(find.byType(AppBar), findsNothing);
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('full-bleed-body'))),
          Offset.zero,
        );
        final button = tester.getRect(
          find.byKey(const ValueKey('artwork-back')),
        );
        expect(button.top, 52);
        expect(button.left, 32);
        final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.descendant(
            of: find.byType(ArtworkDetailScaffold),
            matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          ),
        );
        expect(region.value.statusBarColor, Colors.transparent);
        expect(region.value.systemStatusBarContrastEnforced, isFalse);
        expect(
          region.value.statusBarIconBrightness,
          brightness == Brightness.dark ? Brightness.light : Brightness.dark,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('selection navigation cancels without leaving the detail', (
    tester,
  ) async {
    var cancels = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ArtworkDetailScaffold(
          body: const SizedBox.expand(),
          bottomNavigationBar: const SizedBox.shrink(),
          backButtonKey: const ValueKey('selection-close'),
          closeButton: true,
          onBack: () => cancels++,
          selectionToolbar: const Text('2 selected'),
        ),
      ),
    );
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('selection-close')));
    await tester.pump();
    expect(cancels, 1);
    expect(find.byType(ArtworkDetailScaffold), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('accent back matches the $brightness action material', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            extensions: const [
              AppSurfaceTheme(backgroundMode: SurfaceBackgroundMode.accent),
            ],
          ),
          home: ArtworkDetailScaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: const ValueKey('detail-play'),
                  style: paintedGlassButtonStyle(context),
                  onPressed: () {},
                  child: const Text('Play'),
                ),
              ),
            ),
            bottomNavigationBar: const SizedBox.shrink(),
            backButtonKey: const ValueKey('detail-back'),
            onBack: () {},
          ),
        ),
      );
      final back = find.byKey(const ValueKey('detail-back'));
      final play = find.byKey(const ValueKey('detail-play'));
      BoxDecoration material(Finder button) =>
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: button,
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as BoxDecoration;
      expect(material(back), material(play));
      expect(
        tester.widget<IconButton>(back).style!.side!.resolve({}),
        tester.widget<FilledButton>(play).style!.side!.resolve({}),
      );
      expect(tester.getSize(back), const Size.square(48));
      expect(find.byType(AppInsetHeaderSurface), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(LiquidGlassSurface), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'navigation lenses share their retained backdrop as selection changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var actionTaps = 0;
      Widget frame(int count) => _selectionFrame(
        mode: SurfaceBackgroundMode.liquidGlass,
        count: count,
        onAction: () => actionTaps++,
      );
      await tester.pumpWidget(frame(4));
      await tester.pumpAndSettle();
      final glass = tester
          .widgetList<LiquidGlassSurface>(find.byType(LiquidGlassSurface))
          .toList();
      expect(glass, hasLength(2));
      final backdrop = glass.first.backdropGroupKey;
      expect(backdrop, isNotNull);
      expect(glass.last.backdropGroupKey, same(backdrop));
      final insetSurfaces = find.byType(AppInsetHeaderSurface);
      expect(insetSurfaces, findsNWidgets(2));
      for (final surface in tester.widgetList<AppInsetHeaderSurface>(
        insetSurfaces,
      )) {
        expect(surface.backdropGroupKey, same(backdrop));
      }
      for (final decorated in tester.widgetList<DecoratedBox>(
        find.byKey(const ValueKey('app-inset-header-surface')),
      )) {
        final decoration = decorated.decoration as BoxDecoration;
        expect(decoration.color, isNull);
        expect(decoration.gradient, isNull);
      }
      for (final material in tester.widgetList<Material>(
        find.descendant(of: insetSurfaces, matching: find.byType(Material)),
      )) {
        expect(
          material.type == MaterialType.transparency || material.color?.a == 0,
          isTrue,
          reason: 'The control material must not hide the sampled glass.',
        );
      }
      final back = find.byKey(const ValueKey('glass-back'));
      final action = find.byKey(const ValueKey('glass-selection-action'));
      final capsule = insetSurfaces.last;
      expect(tester.getSize(back), const Size.square(48));
      expect(tester.getSize(capsule).height, 48);
      expect(back.hitTestable(), findsOneWidget);
      expect(action.hitTestable(), findsOneWidget);
      expect(tester.getRect(back).overlaps(tester.getRect(capsule)), isFalse);
      await tester.tap(action);
      expect(actionTaps, 1);

      await tester.pumpWidget(frame(5));
      await tester.pumpAndSettle();
      expect(find.text('5 selected'), findsOneWidget);
      for (final retained in tester.widgetList<LiquidGlassSurface>(
        find.byType(LiquidGlassSurface),
      )) {
        expect(retained.backdropGroupKey, same(backdrop));
      }
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in [
    SurfaceBackgroundMode.accent,
    SurfaceBackgroundMode.transparent,
  ]) {
    testWidgets('navigation respects $mode without a refractive pipeline', (
      tester,
    ) async {
      await tester.pumpWidget(_selectionFrame(mode: mode, count: 4));
      await tester.pumpAndSettle();
      expect(find.byType(LiquidGlassSurface), findsNothing);
      final filters = find.byType(BackdropFilter);
      if (mode == SurfaceBackgroundMode.accent) {
        expect(filters, findsNothing);
      } else {
        expect(filters, findsNWidgets(2));
        final backdropKeys = tester
            .widgetList<BackdropFilter>(filters)
            .map((filter) => filter.backdropGroupKey)
            .toList();
        expect(backdropKeys.first, isNotNull);
        expect(backdropKeys.last, same(backdropKeys.first));
        for (final filter in filters.evaluate()) {
          final filterFinder = find.byElementPredicate(
            (element) => identical(element, filter),
          );
          final clip = find
              .ancestor(of: filterFinder, matching: find.byType(ClipRRect))
              .first;
          expect(tester.getRect(filterFinder), tester.getRect(clip));
          expect(tester.getSize(filterFinder).height, 48);
        }
      }
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _selectionFrame({
  required SurfaceBackgroundMode mode,
  required int count,
  VoidCallback? onAction,
}) => MaterialApp(
  theme: ThemeData(
    brightness: Brightness.dark,
    extensions: [AppSurfaceTheme(backgroundMode: mode)],
  ),
  home: ArtworkDetailScaffold(
    key: const ValueKey('retained-glass-detail'),
    body: const ColoredBox(color: Colors.teal),
    bottomNavigationBar: const SizedBox.shrink(),
    backButtonKey: const ValueKey('glass-back'),
    closeButton: true,
    onBack: () {},
    selectionToolbar: Row(
      children: [
        Expanded(child: Text('$count selected')),
        IconButton(
          key: const ValueKey('glass-selection-action'),
          onPressed: onAction ?? () {},
          icon: const Icon(Icons.playlist_add_rounded),
        ),
      ],
    ),
  ),
);
