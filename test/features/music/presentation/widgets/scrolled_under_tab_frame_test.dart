import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/core/theme/app_theme.dart';
import 'package:bstream_music/features/music/presentation/widgets/scrolled_under_tab_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'uses a translucent neutral scrolled-under surface and returns to top',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(const _FrameHarness());

      final surfaceFinder = find.byKey(
        const ValueKey('test-tab-header-surface'),
      );
      final titleFinder = find.byKey(const ValueKey('test-tab-title'));
      Material surface() => tester.widget<Material>(surfaceFinder);

      final initialTitleRect = tester.getRect(titleFinder);
      expect(
        surface().color,
        AppColors.tabHeaderSurfaceFor(
          tester.element(surfaceFinder),
          scrolledUnder: false,
        ),
      );
      expect(surface().elevation, 0);
      expect(surface().surfaceTintColor, Colors.transparent);
      expect(surface().shape, isNull);
      expect(tester.getSize(surfaceFinder).height, 64);
      expect(find.byType(PinnedHeaderSliver), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('test-item-0'))).dy,
        closeTo(tester.getBottomLeft(surfaceFinder).dy, 0.01),
      );

      await tester.drag(
        find.byKey(const ValueKey('test-tab-scroll')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      expect(
        surface().color,
        AppColors.tabHeaderSurfaceFor(
          tester.element(surfaceFinder),
          scrolledUnder: true,
        ),
      );
      expect(surface().elevation, 1);
      expect(surface().surfaceTintColor, Colors.transparent);
      expect(surface().shape, isNull);
      expect(tester.getRect(titleFinder), initialTitleRect);
      final overlappingItem = tester.getRect(
        find.byKey(const ValueKey('test-item-6')),
      );
      final pinnedHeader = tester.getRect(surfaceFinder);
      expect(overlappingItem.top, lessThan(pinnedHeader.bottom));
      expect(overlappingItem.bottom, greaterThan(pinnedHeader.top));

      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pumpAndSettle();

      expect(
        surface().color,
        AppColors.tabHeaderSurfaceFor(
          tester.element(surfaceFinder),
          scrolledUnder: false,
        ),
      );
      expect(surface().elevation, 0);
      expect(surface().surfaceTintColor, Colors.transparent);
      expect(tester.getRect(titleFinder), initialTitleRect);
    },
  );

  testWidgets('transparent surface uses real glass with a translucent tint', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _FrameHarness(
        surfaceBackgroundMode: SurfaceBackgroundMode.transparent,
      ),
    );

    final surfaceFinder = find.byKey(const ValueKey('test-tab-header-surface'));
    final surface = tester.widget<Material>(surfaceFinder);
    final glass = find.ancestor(
      of: surfaceFinder,
      matching: find.byType(BackdropFilter),
    );
    final accentGradient = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('tab-header-accent-gradient')),
    );

    expect(glass, findsOneWidget);
    expect(surface.color?.a, greaterThan(0.3));
    expect(surface.color?.a, lessThan(0.5));
    expect(
      (accentGradient.decoration as BoxDecoration).gradient,
      isA<LinearGradient>(),
    );

    await tester.drag(
      find.byKey(const ValueKey('test-tab-scroll')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    final headerRect = tester.getRect(surfaceFinder);
    final itemRect = tester.getRect(find.byKey(const ValueKey('test-item-6')));
    expect(itemRect.top, lessThan(headerRect.bottom));
    expect(itemRect.bottom, greaterThan(headerRect.top));
  });

  testWidgets(
    'pinned header follows large text height without hiding content',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        const _FrameHarness(textScaler: TextScaler.linear(4)),
      );

      final surfaceFinder = find.byKey(
        const ValueKey('test-tab-header-surface'),
      );
      final titleFinder = find.byKey(const ValueKey('test-tab-title'));
      final initialHeader = tester.getRect(surfaceFinder);
      final initialTitle = tester.getRect(titleFinder);
      final firstItem = tester.getRect(
        find.byKey(const ValueKey('test-item-0')),
      );

      expect(initialHeader.height, greaterThan(64));
      expect(firstItem.top, closeTo(initialHeader.bottom, 0.01));

      await tester.drag(
        find.byKey(const ValueKey('test-tab-scroll')),
        const Offset(0, -360),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getRect(surfaceFinder).top,
        closeTo(initialHeader.top, 0.01),
      );
      expect(tester.getRect(titleFinder).top, closeTo(initialTitle.top, 0.01));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'removes the header entirely and disables motion when requested',
    (tester) async {
      await tester.pumpWidget(
        const _FrameHarness(showHeader: false, disableAnimations: true),
      );

      expect(
        find.byKey(const ValueKey('test-tab-header-surface')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('test-tab-title')), findsNothing);
      expect(find.byKey(const ValueKey('test-tab-scroll')), findsOneWidget);

      await tester.pumpWidget(const _FrameHarness(disableAnimations: true));

      expect(
        tester
            .widget<Material>(
              find.byKey(const ValueKey('test-tab-header-surface')),
            )
            .animationDuration,
        Duration.zero,
      );
    },
  );
}

class _FrameHarness extends StatelessWidget {
  const _FrameHarness({
    this.showHeader = true,
    this.disableAnimations = false,
    this.surfaceBackgroundMode = SurfaceBackgroundMode.accent,
    this.textScaler = TextScaler.noScaling,
  });

  final bool showHeader;
  final bool disableAnimations;
  final SurfaceBackgroundMode surfaceBackgroundMode;
  final TextScaler textScaler;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        extensions: [AppSurfaceTheme(backgroundMode: surfaceBackgroundMode)],
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          textScaler: textScaler,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: ScrolledUnderTabFrame(
          surfaceKey: const ValueKey('test-tab-header-surface'),
          scrollKey: const ValueKey('test-tab-scroll'),
          header: showHeader
              ? const Row(
                  children: [
                    Expanded(
                      child: Text('Pestaña', key: ValueKey('test-tab-title')),
                    ),
                  ],
                )
              : null,
          slivers: [
            SliverFixedExtentList.builder(
              itemExtent: 48,
              itemCount: 40,
              itemBuilder: (_, index) => SizedBox(
                key: ValueKey('test-item-$index'),
                child: Text('Elemento $index'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
