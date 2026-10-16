import 'package:bstream_music/features/music/presentation/widgets/surface_detail_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final metrics = FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: 1000,
    pixels: 50,
    viewportDimension: 500,
    axisDirection: AxisDirection.down,
    devicePixelRatio: 1,
  );

  testWidgets('brief scroll gaps do not recreate the resting filter', (
    tester,
  ) async {
    final motion = GlassScrollMotionNotifier();
    addTearDown(motion.dispose);
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    final changes = <bool>[];
    motion.addListener(() => changes.add(motion.value));
    motion.handleNotification(
      ScrollStartNotification(metrics: metrics, context: context),
    );
    motion.handleNotification(
      ScrollEndNotification(metrics: metrics, context: context),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(motion.value, isTrue);
    motion.handleNotification(
      ScrollStartNotification(metrics: metrics, context: context),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(motion.value, isTrue);
    motion.handleNotification(
      ScrollEndNotification(metrics: metrics, context: context),
    );
    await tester.pump(GlassScrollMotionNotifier.settleDelay);
    expect(motion.value, isFalse);
    expect(changes, [true, false]);
  });

  testWidgets('reset cancels pending settle work', (tester) async {
    final motion = GlassScrollMotionNotifier();
    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    motion.handleNotification(
      ScrollStartNotification(metrics: metrics, context: context),
    );
    motion.handleNotification(
      ScrollEndNotification(metrics: metrics, context: context),
    );
    motion.reset();
    expect(motion.value, isFalse);
    motion.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
