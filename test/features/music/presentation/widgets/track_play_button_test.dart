import 'package:bstream_music/features/music/presentation/widgets/track_play_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final isPlaying in [false, true]) {
    testWidgets('track ${isPlaying ? 'pause' : 'play'} uses neutral control', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: TrackPlayButton(
              tooltip: isPlaying ? 'Pause' : 'Play',
              isPlaying: isPlaying,
              onPressed: () {},
            ),
          ),
        ),
      );

      final button = tester.widget<IconButton>(find.byType(IconButton));
      final buttonContext = tester.element(find.byType(TrackPlayButton));
      final colors = Theme.of(buttonContext).colorScheme;
      expect(
        button.style?.foregroundColor?.resolve(<WidgetState>{}),
        colors.brightness == Brightness.light ? Colors.black : colors.onSurface,
      );
      expect(
        button.style?.backgroundColor?.resolve(<WidgetState>{}),
        colors.surfaceContainerHighest.withValues(alpha: 0.84),
      );
      expect(
        find.byIcon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
        findsOneWidget,
      );
    });
  }
}
