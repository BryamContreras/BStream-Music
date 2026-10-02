import 'package:bstream_music/features/music/presentation/widgets/ambient_animation_frame_gate.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('decorative frames keep 60 fps on a 120 Hz display', (
    tester,
  ) async {
    final controller = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(seconds: 1),
    );
    final gate = AmbientAnimationFrameGate(controller);
    gate.setDisplayRefreshRate(120);
    var paintedFrames = 0;
    gate.addListener(() => paintedFrames++);
    controller.repeat();
    await tester.pump();
    paintedFrames = 0;

    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(paintedFrames, 4);

    gate.setDisplayRefreshRate(60);
    paintedFrames = 0;
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(paintedFrames, 4);

    gate.dispose();
    controller.dispose();
  });
}
