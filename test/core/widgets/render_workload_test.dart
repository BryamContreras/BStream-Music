import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bstream_music/core/widgets/render_workload.dart';

void main() {
  testWidgets('rendering path follows the viewport physical pixel count', (
    tester,
  ) async {
    late bool highPixelCount;
    Future<void> check(Size size, double ratio, bool expected) async {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: ratio),
          child: Builder(
            builder: (context) {
              highPixelCount = hasHighPixelCount(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(highPixelCount, expected);
    }

    await check(const Size(384, 832), 2.8125, false);
    await check(const Size(384, 832), 3.75, true);
    await check(const Size(832, 384), 3.75, true);
    await check(const Size(1200, 800), 2, true);
    await check(const Size(600, 800), 2, false);
  });
}
