import 'dart:ui' as ui;

import 'package:bstream_music/features/music/presentation/widgets/artwork_header_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'header snapshots wait for a decoded frame and clear for a fallback',
    (tester) async {
      final frame = ValueNotifier<ui.Image?>(null);
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(Colors.red, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(4, 4);
      picture.dispose();
      addTearDown(frame.dispose);
      addTearDown(image.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Center(
            child: SizedBox.square(
              dimension: 100,
              child: ArtworkHeaderSnapshot(
                revision: 'album',
                builder: (context, onFrame) =>
                    ValueListenableBuilder<ui.Image?>(
                      valueListenable: frame,
                      builder: (context, current, child) {
                        onFrame(current);
                        return RawImage(image: current);
                      },
                    ),
              ),
            ),
          ),
        ),
      );
      final snapshot = tester.widget<SnapshotWidget>(
        find.byType(SnapshotWidget),
      );
      expect(snapshot.controller.allowSnapshotting, isFalse);

      frame.value = image;
      await tester.pump();
      expect(snapshot.controller.allowSnapshotting, isFalse);
      await tester.pump(const Duration(milliseconds: 170));
      expect(snapshot.controller.allowSnapshotting, isTrue);

      frame.value = null;
      await tester.pump();
      expect(snapshot.controller.allowSnapshotting, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
