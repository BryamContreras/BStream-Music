import 'package:bstream_music/features/music/presentation/widgets/library_subscribed_artists_shelf.dart';
import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows followed artists and opens the selected profile', (
    tester,
  ) async {
    const artist = RemoteSubscribedArtist(
      browseId: 'MPLA-artist',
      channelId: 'UC-artist',
      name: 'Artista guardado',
    );
    RemoteSubscribedArtist? opened;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibrarySubscribedArtistsShelf(
            title: 'Artistas',
            artists: const <RemoteSubscribedArtist>[artist],
            onOpenArtist: (artist) => opened = artist,
          ),
        ),
      ),
    );

    expect(find.text('Artistas'), findsOneWidget);
    expect(find.text('Artista guardado'), findsOneWidget);
    expect(find.byType(ClipOval), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('library-open-artist-UC-artist')),
    );
    await tester.pump();

    expect(opened, same(artist));
  });

  testWidgets('does not reserve space for an empty account shelf', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LibrarySubscribedArtistsShelf(
            title: 'Artistas',
            artists: <RemoteSubscribedArtist>[],
            onOpenArtist: _ignoreArtist,
          ),
        ),
      ),
    );

    expect(find.text('Artistas'), findsNothing);
    expect(find.byType(ListView), findsNothing);
  });
}

void _ignoreArtist(RemoteSubscribedArtist _) {}
