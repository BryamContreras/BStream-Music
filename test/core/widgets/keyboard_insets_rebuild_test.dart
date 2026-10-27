import 'package:bstream_music/core/widgets/liquid_glass_surface.dart';
import 'package:bstream_music/core/widgets/marquee_text.dart';
import 'package:bstream_music/features/music/presentation/widgets/animated_artwork_motion.dart';
import 'package:bstream_music/features/music/presentation/widgets/classic_vinyl_deck.dart';
import 'package:bstream_music/features/music/presentation/widgets/gradient_progress_bar.dart';
import 'package:bstream_music/features/music/presentation/widgets/now_playing_equalizer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'keyboard animation does not rebuild fixed playback animations or glass',
    (tester) async {
      const restingMedia = MediaQueryData(size: Size(400, 900));
      final media = ValueNotifier(restingMedia);
      addTearDown(media.dispose);
      var animationBuilds = 0;
      final previousObserver = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousObserver?.call(element, builtOnce);
        if (element.widget is MarqueeText ||
            element.widget is AnimatedArtworkMotion ||
            element.widget is NowPlayingEqualizer ||
            element.widget is GradientProgressBar ||
            element.widget is ClassicVinylDeck) {
          animationBuilds++;
        }
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previousObserver);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: ValueListenableBuilder<MediaQueryData>(
            valueListenable: media,
            builder: (context, data, child) =>
                MediaQuery(data: data, child: child!),
            child: const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                height: 600,
                child: Column(
                  children: [
                    SizedBox(
                      width: 160,
                      child: MarqueeText(
                        'A long title with several collaborating artists',
                        pause: Duration(milliseconds: 1),
                      ),
                    ),
                    SizedBox(
                      width: 180,
                      height: 90,
                      child: AnimatedArtworkMotion(
                        child: ColoredBox(color: Colors.blue),
                      ),
                    ),
                    NowPlayingEqualizer(isPlaying: true),
                    GradientProgressBar(value: null, indeterminate: true),
                    SizedBox(
                      width: 180,
                      height: 180,
                      child: ClassicVinylDeck(
                        artworkSource: null,
                        artworkFallbackSource: null,
                        identity: 'track',
                        isPlaying: true,
                        animationEnabled: true,
                        progress: 0.4,
                      ),
                    ),
                    SizedBox(
                      height: 60,
                      child: LiquidGlassSurface(child: Text('Glass chrome')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      final initialBuilds = animationBuilds;
      final initialFilter = tester.widget<BackdropFilter>(
        find.byKey(LiquidGlassSurface.backdropKey),
      );

      // Exercise opening, resizing, and dismissing the IME without changing
      // these surfaces' bounds or accessibility preferences. Their paint-only
      // animations keep running while unrelated window insets change.
      for (final bottom in [30.0, 100.0, 200.0, 300.0, 200.0, 100.0, 0.0]) {
        media.value = restingMedia.copyWith(
          viewInsets: EdgeInsets.only(bottom: bottom),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(animationBuilds, initialBuilds);
      expect(
        tester.widget<BackdropFilter>(
          find.byKey(LiquidGlassSurface.backdropKey),
        ),
        same(initialFilter),
      );
      expect(tester.hasRunningAnimations, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
