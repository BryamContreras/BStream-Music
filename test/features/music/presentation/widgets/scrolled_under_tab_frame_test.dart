import 'package:bstream_music/features/music/presentation/widgets/scrolled_under_tab_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'matches the Material 3 scrolled-under surface and returns to top',
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
      final colors = Theme.of(tester.element(surfaceFinder)).colorScheme;
      Material surface() => tester.widget<Material>(surfaceFinder);

      final initialTitleRect = tester.getRect(titleFinder);
      expect(surface().color, colors.surface);
      expect(surface().elevation, 0);

      await tester.drag(
        find.byKey(const ValueKey('test-tab-scroll')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      expect(surface().color, colors.surfaceContainer);
      expect(surface().elevation, 3);
      expect(tester.getRect(titleFinder), initialTitleRect);

      tester.state<ScrollableState>(find.byType(Scrollable)).position.jumpTo(0);
      await tester.pumpAndSettle();

      expect(surface().color, colors.surface);
      expect(surface().elevation, 0);
      expect(tester.getRect(titleFinder), initialTitleRect);
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
  const _FrameHarness({this.showHeader = true, this.disableAnimations = false});

  final bool showHeader;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: ScrolledUnderTabFrame(
          surfaceKey: const ValueKey('test-tab-header-surface'),
          header: showHeader
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Pestaña', key: ValueKey('test-tab-title')),
                )
              : null,
          body: ListView.builder(
            key: const ValueKey('test-tab-scroll'),
            itemCount: 40,
            itemBuilder: (_, index) =>
                SizedBox(height: 48, child: Text('Elemento $index')),
          ),
        ),
      ),
    );
  }
}
