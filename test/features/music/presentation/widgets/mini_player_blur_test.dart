import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/widgets/mini_player.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mini-player blur decodes a bounded background image', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playerControllerProvider.overrideWith(_TestPlayerController.new),
          favoriteTrackIdsProvider.overrideWithValue(const <String>{}),
          appStringsProvider.overrideWithValue(
            const AppStrings(AppLanguage.spanish),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const Scaffold(body: SizedBox(height: 80, child: MiniPlayer())),
        ),
      ),
    );
    await tester.pump();

    final blur = find.byType(ImageFiltered);
    expect(blur, findsOneWidget);

    final backgroundImage = find.descendant(
      of: blur,
      matching: find.byType(Image),
    );
    expect(backgroundImage, findsOneWidget);
    final image = tester.widget<Image>(backgroundImage);
    final provider = image.image as ResizeImage;
    expect(provider.width, 320);
  });
}

class _TestPlayerController extends PlayerController {
  @override
  Future<PlayerSnapshot> build() async => const PlayerSnapshot(
    status: PlayerStatus.paused,
    title: 'Canción de prueba',
    artist: 'BStream Music',
    thumbnailUrl: 'https://example.invalid/mini-player-artwork.jpg',
    duration: Duration(minutes: 3),
  );
}
