import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform repaints the retained glass once after a route returns',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(platform: platform),
            home: const Scaffold(
              body: Center(
                child: SizedBox(
                  width: 280,
                  height: 72,
                  child: LiquidGlassSurface(
                    child: Center(child: Text('Retained navigation')),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final backdrop = tester.renderObject<RenderBackdropFilter>(
          find.byKey(LiquidGlassSurface.backdropKey),
        );
        final material = backdrop.parent!;

        // Cover the page completely so its glass is retained/offstage, as when
        // opening an artist from Home. Keep the same render object throughout.
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Artist')),
          ),
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(
          tester.renderObject<RenderBackdropFilter>(
            find.byKey(LiquidGlassSurface.backdropKey),
          ),
          same(backdrop),
        );
        expect(
          material.debugNeedsPaint,
          isTrue,
          reason:
              'The final route transform must invalidate the retained native '
              'filter without requiring any scroll or pointer input.',
        );
        expect(tester.binding.hasScheduledFrame, isTrue);
        await tester.pump();
        expect(material.debugNeedsPaint, isFalse);
        expect(tester.binding.hasScheduledFrame, isFalse);

        // Ordinary idle frames must not repeatedly repaint or rebuild glass.
        await tester.pump(const Duration(seconds: 1));
        expect(material.debugNeedsPaint, isFalse);
        expect(tester.binding.hasScheduledFrame, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('disposing glass during a route transition leaves no callback', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(
          body: SizedBox(
            width: 280,
            height: 72,
            child: LiquidGlassSurface(child: Text('Navigation')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(builder: (_) => const Scaffold()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
