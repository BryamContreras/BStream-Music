import 'package:bstream_music/features/music/presentation/widgets/track_change_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'keeps the outgoing surface opaque while the next song fades over it',
    (tester) async {
      var identity = 'first';
      late StateSetter update;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return TrackChangeTransition(
                identity: identity,
                child: SizedBox(
                  key: ValueKey('transition-content-$identity'),
                  width: 80,
                  height: 80,
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      update(() => identity = 'second');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 210));

      Opacity opacityFor(String value) => tester.widget<Opacity>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Opacity &&
              widget.child is KeyedSubtree &&
              (widget.child! as KeyedSubtree).key == ValueKey(value),
        ),
      );

      expect(opacityFor('first').opacity, 1);
      expect(opacityFor('second').opacity, greaterThan(0));
      expect(opacityFor('second').opacity, lessThan(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('disables the song transition when reduced motion is enabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: const TrackChangeTransition(
          identity: 'reduced-motion-song',
          switcherKey: ValueKey('reduced-motion-transition'),
          child: SizedBox(width: 80, height: 80),
        ),
      ),
    );

    final switcher = tester.widget<AnimatedSwitcher>(
      find.byKey(const ValueKey('reduced-motion-transition')),
    );
    expect(switcher.duration, Duration.zero);
    expect(switcher.reverseDuration, Duration.zero);
  });
}
