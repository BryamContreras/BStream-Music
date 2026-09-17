import 'package:bstream_music/features/music/presentation/widgets/classic_vinyl_deck.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('record rotates only while playback and motion are enabled', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(isPlaying: true, animationEnabled: true));

    final rotation = find.byKey(
      const ValueKey('classic-vinyl-record-rotation'),
    );
    expect(rotation, findsOneWidget);
    expect(find.byKey(const ValueKey('classic-vinyl-tonearm')), findsOneWidget);
    expect(find.byKey(const ValueKey('classic-vinyl-spindle')), findsOneWidget);
    final surface = tester.widget<SizedBox>(
      find.byKey(const ValueKey('classic-vinyl-deck-surface')),
    );
    expect(surface.child, isA<Stack>());
    expect(
      tester
          .widget<Stack>(find.byKey(const ValueKey('classic-vinyl-deck-stack')))
          .clipBehavior,
      Clip.none,
    );

    final initialTurns = _turns(tester, rotation);
    await tester.pump(const Duration(milliseconds: 540));
    final playingTurns = _turns(tester, rotation);
    expect(playingTurns, greaterThan(initialTurns));

    await tester.pumpWidget(_harness(isPlaying: false, animationEnabled: true));
    final pausedTurns = _turns(tester, rotation);
    await tester.pump(const Duration(milliseconds: 900));
    expect(_turns(tester, rotation), closeTo(pausedTurns, 0.000001));

    await tester.pumpWidget(_harness(isPlaying: true, animationEnabled: false));
    expect(_turns(tester, rotation), 0);
    await tester.pump(const Duration(milliseconds: 900));
    expect(_turns(tester, rotation), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion keeps the record static', (tester) async {
    await tester.pumpWidget(
      _harness(
        isPlaying: true,
        animationEnabled: true,
        disableAnimations: true,
      ),
    );

    final rotation = find.byKey(
      const ValueKey('classic-vinyl-record-rotation'),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(_turns(tester, rotation), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing tracks resets the record before the new rotation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        identity: 'first-track',
        isPlaying: true,
        animationEnabled: true,
      ),
    );
    final rotation = find.byKey(
      const ValueKey('classic-vinyl-record-rotation'),
    );
    await tester.pump(const Duration(milliseconds: 1080));
    expect(_turns(tester, rotation), greaterThan(0.15));

    await tester.pumpWidget(
      _harness(
        identity: 'second-track',
        isPlaying: false,
        animationEnabled: true,
      ),
    );
    expect(_turns(tester, rotation), 0);
    expect(
      find.byKey(const ValueKey('classic-vinyl-label-second-track')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tonearm glides between grooves and snaps for reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(isPlaying: false, animationEnabled: true, progress: 0.10),
    );

    Animation<double> tonearmProgress() =>
        (tester
                    .widget<CustomPaint>(
                      find.byKey(const ValueKey('classic-vinyl-tonearm')),
                    )
                    .painter
                as ClassicVinylTonearmPainter)
            .progress;

    expect(tonearmProgress().value, closeTo(0.10, 0.0001));

    await tester.pumpWidget(
      _harness(isPlaying: false, animationEnabled: true, progress: 0.80),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(tonearmProgress().value, greaterThan(0.10));
    expect(tonearmProgress().value, lessThan(0.80));

    await tester.pump(const Duration(milliseconds: 500));
    expect(tonearmProgress().value, closeTo(0.80, 0.0001));

    await tester.pumpWidget(
      _harness(
        isPlaying: false,
        animationEnabled: true,
        progress: 0.25,
        disableAnimations: true,
      ),
    );
    expect(tonearmProgress().value, closeTo(0.25, 0.0001));
    expect(tester.takeException(), isNull);
  });
}

double _turns(WidgetTester tester, Finder rotation) {
  return tester.widget<RotationTransition>(rotation).turns.value;
}

Widget _harness({
  String identity = 'vinyl-track',
  required bool isPlaying,
  required bool animationEnabled,
  bool disableAnimations = false,
  double progress = 0.42,
}) {
  return MaterialApp(
    theme: ThemeData(colorSchemeSeed: const Color(0xFF42B6A8)),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: 320,
            child: ClassicVinylDeck(
              artworkSource: null,
              artworkFallbackSource: null,
              identity: identity,
              isPlaying: isPlaying,
              animationEnabled: animationEnabled,
              progress: progress,
            ),
          ),
        ),
      ),
    ),
  );
}
