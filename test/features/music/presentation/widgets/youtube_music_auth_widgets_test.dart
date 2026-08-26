import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_account_avatar.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_account_button.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_account_dialog.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_channel_picker_dialog.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_login_disclosure_dialog.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_playlist_sync_consent_dialog.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('disclosure uses AppStrings and presents both decisions', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: YouTubeMusicLoginDisclosureDialog(
            strings: AppStrings(AppLanguage.english),
          ),
        ),
      ),
    );

    expect(find.text('Unofficial integration'), findsOneWidget);
    expect(find.textContaining('not affiliated with Google'), findsOneWidget);
    expect(find.textContaining('never stores your password'), findsOneWidget);
    expect(
      find.textContaining('may change, block, or restrict'),
      findsOneWidget,
    );
    expect(find.textContaining('Favorites remains local'), findsNothing);
    expect(find.textContaining('required session cookies'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('I understand, continue'), findsOneWidget);
    expect(
      find.byKey(const Key('youtube-music-disclosure-accept')),
      findsOneWidget,
    );
  });

  testWidgets('playlist sync consent states every first-sync side effect', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: YouTubeMusicPlaylistSyncConsentDialog(
            strings: AppStrings(AppLanguage.english),
            localPlaylistCount: 3,
          ),
        ),
      ),
    );

    expect(find.text('Synchronize playlists'), findsOneWidget);
    expect(find.textContaining('3 local playlists will stay'), findsOneWidget);
    expect(
      find.textContaining('Favorites will sync with YouTube Music'),
      findsOneWidget,
    );
    expect(find.textContaining('created as private playlists'), findsOneWidget);
    expect(
      find.textContaining('remote playlists are imported here'),
      findsOneWidget,
    );
    expect(find.text('Keep and synchronize'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('account button keeps a 48dp action with a compact avatar', (
    tester,
  ) async {
    var pressed = false;
    final store = _WidgetSessionStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          youtubeMusicSessionStoreProvider.overrideWithValue(store),
          youtubeMusicAccountClientProvider.overrideWithValue(
            const UnconfiguredYouTubeMusicAccountClient(),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: <Widget>[
                YouTubeMusicAccountButton(
                  strings: const AppStrings(AppLanguage.english),
                  onPressed: (context, ref, state) async {
                    pressed = true;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final button = find.byKey(const Key('home-youtube-music-account'));
    expect(button, findsOneWidget);
    expect(tester.getSize(button).width, greaterThanOrEqualTo(48));
    final avatar = find.byType(YouTubeMusicAccountAvatar);
    expect(tester.widget<YouTubeMusicAccountAvatar>(avatar).size, 30);
    expect(tester.getSize(avatar), const Size.square(30));
    expect(tester.getSize(button), const Size.square(48));
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
    expect(find.byTooltip('Sign in to YouTube Music'), findsOneWidget);

    await tester.tap(button);
    await tester.pump();
    expect(pressed, isTrue);
  });

  testWidgets('untrusted avatar hosts render the local fallback only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: YouTubeMusicAccountAvatar(
          profile: YouTubeMusicAccountProfile(
            channelId: 'test-channel',
            displayName: 'Test account',
            avatarUrl: Uri.parse('https://evil.example/avatar.png'),
          ),
        ),
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.person), findsOneWidget);
  });

  testWidgets('logout requires confirmation and preserves local-library copy', (
    tester,
  ) async {
    var loggedOut = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: YouTubeMusicAccountDialog(
            profile: const YouTubeMusicAccountProfile(
              channelId: 'test-channel',
              displayName: 'Test account',
            ),
            onLogout: () async => loggedOut = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('youtube-music-account-logout')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('youtube-music-logout-confirmation')),
      findsOneWidget,
    );
    expect(find.textContaining('biblioteca local'), findsOneWidget);
    expect(loggedOut, isFalse);

    await tester.tap(find.byKey(const Key('youtube-music-logout-confirm')));
    await tester.pumpAndSettle();
    expect(loggedOut, isTrue);
  });

  testWidgets('channel picker returns only a displayed channel', (
    tester,
  ) async {
    final channel = YouTubeMusicAccountChannel(
      profile: const YouTubeMusicAccountProfile(
        channelId: 'test-channel',
        displayName: 'Test channel',
        handle: '@test',
      ),
      isSelected: true,
    );
    YouTubeMusicAccountChannel? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              selected = await YouTubeMusicChannelPickerDialog.show(
                context,
                <YouTubeMusicAccountChannel>[channel],
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Test channel'), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('youtube-music-channel-test-channel')),
    );
    await tester.pumpAndSettle();
    expect(selected, same(channel));
  });
}

class _WidgetSessionStore implements YouTubeMusicSessionStore {
  @override
  Future<void> delete() async {}

  @override
  Future<YouTubeMusicSessionCredential?> read() async => null;

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {}
}
