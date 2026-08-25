import 'package:bstream_music/features/music/presentation/providers/subscribed_artists_controller.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'loads the account shelf and applies confirmed mutations immediately',
    () async {
      final account = _FakeSubscribedArtistsAccount(<RemoteSubscribedArtist>[
        const RemoteSubscribedArtist(
          browseId: 'UC-initial',
          channelId: 'UC-initial',
          name: 'Inicial',
        ),
      ]);
      final container = ProviderContainer(
        overrides: [
          youtubeMusicAuthControllerProvider.overrideWith(
            () => _StaticAuthController(_authenticated),
          ),
          youtubeMusicSubscribedArtistsAccountProvider.overrideWithValue(
            account,
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        (await container.read(
          subscribedArtistsProvider.future,
        )).map((artist) => artist.name),
        <String>['Inicial'],
      );

      final controller = container.read(subscribedArtistsProvider.notifier);
      controller.recordSubscribed(
        const RemoteSubscribedArtist(
          browseId: 'MPLA-new',
          channelId: 'UC-new',
          name: 'Nuevo',
        ),
      );
      expect(
        container
            .read(subscribedArtistsProvider)
            .requireValue
            .map((artist) => artist.name),
        <String>['Nuevo', 'Inicial'],
      );

      controller.recordUnsubscribed(
        artistBrowseId: 'MPLA-new',
        channelId: 'UC-new',
      );
      expect(
        container
            .read(subscribedArtistsProvider)
            .requireValue
            .map((artist) => artist.name),
        <String>['Inicial'],
      );
      expect(account.reads, 1);
    },
  );

  test('does not read account artists while signed out', () async {
    final account = _FakeSubscribedArtistsAccount(const []);
    final container = ProviderContainer(
      overrides: [
        youtubeMusicAuthControllerProvider.overrideWith(
          () => _StaticAuthController(
            const YouTubeMusicAuthState(
              phase: YouTubeMusicAuthPhase.anonymous,
              generation: 1,
            ),
          ),
        ),
        youtubeMusicSubscribedArtistsAccountProvider.overrideWithValue(account),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(subscribedArtistsProvider.future), isEmpty);
    expect(account.reads, 0);
  });
}

const _authenticated = YouTubeMusicAuthState(
  phase: YouTubeMusicAuthPhase.authenticated,
  generation: 3,
  profile: YouTubeMusicAccountProfile(
    channelId: 'UC-account',
    displayName: 'Cuenta',
  ),
);

class _StaticAuthController extends YouTubeMusicAuthController {
  _StaticAuthController(this.fixedState);

  final YouTubeMusicAuthState fixedState;

  @override
  YouTubeMusicAuthState build() => fixedState;
}

class _FakeSubscribedArtistsAccount
    implements YouTubeMusicSubscribedArtistsAccount {
  _FakeSubscribedArtistsAccount(this.artists);

  final List<RemoteSubscribedArtist> artists;
  int reads = 0;

  @override
  Future<RemoteSubscribedArtistCollection> getSubscribedArtists() async {
    reads += 1;
    return RemoteSubscribedArtistCollection(
      artists: artists,
      termination: RemotePaginationTermination.exhausted,
      pagesFetched: 1,
    );
  }
}
