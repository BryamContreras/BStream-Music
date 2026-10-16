import 'package:bstream_music/core/widgets/horizontal_shelf_scroll_behavior.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform mouse drag scrolls without opening a card', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var taps = 0;
      await tester.pumpWidget(
        _ShelfHarness(
          platform: platform,
          controller: controller,
          onTap: () => taps++,
        ),
      );

      await tester.drag(
        find.byKey(const ValueKey('shelf')),
        const Offset(-220, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(controller.offset, greaterThan(150));
      expect(taps, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('$platform keeps touch dragging and does not add mouse drag', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _ShelfHarness(platform: platform, controller: controller),
      );
      final shelf = find.byKey(const ValueKey('shelf'));
      expect(
        ScrollConfiguration.of(
          tester.element(shelf),
        ).dragDevices.contains(PointerDeviceKind.mouse),
        isFalse,
      );
      await tester.drag(shelf, const Offset(-220, 0));
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(150));
    });
  }

  testWidgets(
    'primary click still opens a card and secondary click is retained',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var taps = 0;
      var secondaryTaps = 0;
      await tester.pumpWidget(
        _ShelfHarness(
          controller: controller,
          onTap: () => taps++,
          onSecondaryTap: () => secondaryTaps++,
        ),
      );
      final point = tester.getCenter(find.byKey(const ValueKey('card-0')));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(point);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(controller.offset, 0);

      final secondary = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await secondary.down(point);
      await secondary.up();
      await tester.pumpAndSettle();
      expect(secondaryTaps, 1);
      expect(taps, 1);
      expect(controller.offset, 0);
    },
  );

  testWidgets('desktop touch and trackpad dragging still work', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_ShelfHarness(controller: controller));
    final shelf = find.byKey(const ValueKey('shelf'));
    await tester.drag(shelf, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(100));

    controller.jumpTo(0);
    await tester.pump();
    final trackpad = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    final point = tester.getCenter(shelf);
    await trackpad.panZoomStart(point);
    await trackpad.panZoomUpdate(point, pan: const Offset(-80, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await trackpad.panZoomUpdate(point, pan: const Offset(-160, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await trackpad.panZoomEnd();
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(100));
  });

  testWidgets('horizontal wheel and Shift plus vertical wheel still scroll', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_ShelfHarness(controller: controller));
    final point = tester.getCenter(find.byKey(const ValueKey('shelf')));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: point, scrollDelta: const Offset(80, 0)),
    );
    await tester.pumpAndSettle();
    expect(controller.offset, 80);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(
      PointerScrollEvent(position: point, scrollDelta: const Offset(0, 90)),
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(controller.offset, 170);
  });

  testWidgets('does not enable mouse drag on surrounding vertical lists', (
    tester,
  ) async {
    final shelfController = ScrollController();
    final verticalController = ScrollController();
    addTearDown(shelfController.dispose);
    addTearDown(verticalController.dispose);
    await tester.pumpWidget(
      _ShelfHarness(
        controller: shelfController,
        verticalController: verticalController,
      ),
    );
    final vertical = find.byKey(const ValueKey('vertical-list'));
    expect(
      ScrollConfiguration.of(
        tester.element(vertical),
      ).dragDevices.contains(PointerDeviceKind.mouse),
      isFalse,
    );
    await tester.drag(
      vertical,
      const Offset(0, -180),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(verticalController.offset, 0);
    await tester.drag(vertical, const Offset(0, -180));
    await tester.pumpAndSettle();
    expect(verticalController.offset, greaterThan(100));
  });

  testWidgets('preserves inherited physics, input modifiers and decorations', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    const physics = BouncingScrollPhysics();
    final inherited = const MaterialScrollBehavior().copyWith(
      scrollbars: false,
      overscroll: false,
      dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.trackpad},
      pointerAxisModifiers: {LogicalKeyboardKey.controlLeft},
      multitouchDragStrategy: MultitouchDragStrategy.sumAllPointers,
      physics: physics,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    );
    await tester.pumpWidget(
      _ShelfHarness(controller: controller, behavior: inherited),
    );
    final shelf = find.byKey(const ValueKey('shelf'));
    final context = tester.element(shelf);
    final behavior = ScrollConfiguration.of(context);
    expect(behavior.dragDevices, {
      PointerDeviceKind.touch,
      PointerDeviceKind.trackpad,
      PointerDeviceKind.mouse,
    });
    expect(behavior.getScrollPhysics(context), same(physics));
    expect(behavior.pointerAxisModifiers, {LogicalKeyboardKey.controlLeft});
    expect(
      behavior.getMultitouchDragStrategy(context),
      MultitouchDragStrategy.sumAllPointers,
    );
    expect(
      behavior.getKeyboardDismissBehavior(context),
      ScrollViewKeyboardDismissBehavior.onDrag,
    );
    expect(find.byType(Scrollbar), findsNothing);
    expect(find.byType(RawScrollbar), findsNothing);
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    expect(find.byType(GlowingOverscrollIndicator), findsNothing);
  });
}

class _ShelfHarness extends StatelessWidget {
  const _ShelfHarness({
    required this.controller,
    this.platform = TargetPlatform.windows,
    this.verticalController,
    this.onTap,
    this.onSecondaryTap,
    this.behavior = const MaterialScrollBehavior(),
  });

  final TargetPlatform platform;
  final ScrollController controller;
  final ScrollController? verticalController;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;
  final ScrollBehavior behavior;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(platform: platform),
      scrollBehavior: behavior,
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(
            children: [
              SizedBox(
                width: 320,
                height: 120,
                child: HorizontalShelfScroll(
                  child: ListView.builder(
                    key: const ValueKey('shelf'),
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemExtent: 100,
                    itemCount: 20,
                    itemBuilder: (_, index) => InkWell(
                      key: ValueKey('card-$index'),
                      onTap: onTap,
                      onSecondaryTap: onSecondaryTap,
                      child: Center(child: Text('Card $index')),
                    ),
                  ),
                ),
              ),
              if (verticalController != null)
                Expanded(
                  child: ListView.builder(
                    key: const ValueKey('vertical-list'),
                    controller: verticalController,
                    itemExtent: 60,
                    itemCount: 30,
                    itemBuilder: (_, index) => Text('Row $index'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
