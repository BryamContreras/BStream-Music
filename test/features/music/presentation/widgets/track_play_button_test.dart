import 'package:bstream_music/core/theme/app_colors.dart';
import 'package:bstream_music/features/music/presentation/widgets/track_play_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final isPlaying in [false, true]) {
    testWidgets('track ${isPlaying ? 'pause' : 'play'} icon is white', (
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
      expect(
        button.style?.foregroundColor?.resolve(<WidgetState>{}),
        AppColors.playerControlForeground,
      );
      expect(
        find.byIcon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
        findsOneWidget,
      );
    });
  }
}
