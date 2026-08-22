import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_coordinator.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes and validates before anything is persisted', () async {
    final store = _MemorySessionStore();
    final client = _FakeAccountClient(profile: _profile('channel-a'));
    final coordinator = YouTubeMusicAuthCoordinator(
      sessionStore: store,
      accountClient: client,
      clock: () => DateTime.utc(2026, 8, 22, 15),
    );

    final credential = await coordinator.validate(
      _authData('VISITOR_INFO1_LIVE=test; SAPISID=test-session-value'),
    );

    expect(client.validatedCookies, <String>[
      'SAPISID=test-session-value; VISITOR_INFO1_LIVE=test',
    ]);
    expect(credential.profile.channelId, 'channel-a');
    expect(credential.validatedAt, DateTime.utc(2026, 8, 22, 15));
    expect(store.writes, isEmpty);

    await coordinator.persist(credential);
    expect(store.writes, <YouTubeMusicSessionCredential>[credential]);
  });

  test('does not produce a credential when remote validation fails', () async {
    final store = _MemorySessionStore();
    final coordinator = YouTubeMusicAuthCoordinator(
      sessionStore: store,
      accountClient: _FakeAccountClient(
        validationError: const YouTubeMusicAccountException(
          YouTubeMusicAccountFailureKind.unauthenticated,
          'Test session rejected.',
        ),
      ),
    );

    await expectLater(
      coordinator.validate(_authData()),
      throwsA(
        isA<YouTubeMusicAccountException>().having(
          (error) => error.kind,
          'kind',
          YouTubeMusicAccountFailureKind.unauthenticated,
        ),
      ),
    );
    expect(store.writes, isEmpty);
  });

  test('rejects a different channel than the user selected', () async {
    final coordinator = YouTubeMusicAuthCoordinator(
      sessionStore: _MemorySessionStore(),
      accountClient: _FakeAccountClient(profile: _profile('unexpected')),
    );
    final expected = YouTubeMusicAccountChannel(
      profile: _profile('expected'),
      isSelected: false,
    );

    await expectLater(
      coordinator.validate(_authData(), expectedChannel: expected),
      throwsA(
        isA<YouTubeMusicAccountException>().having(
          (error) => error.kind,
          'kind',
          YouTubeMusicAccountFailureKind.invalidResponse,
        ),
      ),
    );
  });

  test('discovers an immutable channel list from normalized data', () async {
    final channels = <YouTubeMusicAccountChannel>[
      YouTubeMusicAccountChannel(
        profile: _profile('channel-a'),
        isSelected: true,
      ),
    ];
    final client = _FakeAccountClient(channels: channels);
    final coordinator = YouTubeMusicAuthCoordinator(
      sessionStore: _MemorySessionStore(),
      accountClient: client,
    );

    final discovered = await coordinator.discoverChannels(_authData());

    expect(discovered.single.profile.channelId, 'channel-a');
    expect(() => discovered.add(channels.single), throwsUnsupportedError);
  });

  test('accepts only whitelisted channel switch URLs', () {
    final coordinator = YouTubeMusicAuthCoordinator(
      sessionStore: _MemorySessionStore(),
      accountClient: _FakeAccountClient(),
    );
    final good = Uri.parse('https://music.youtube.com/signin?action=switch');

    expect(coordinator.validateChannelSignInUrl(good), same(good));
    for (final value in const <String>[
      'https://music.youtube.com.evil.example/switch',
      'https://user@music.youtube.com/switch',
      'http://music.youtube.com/switch',
    ]) {
      expect(
        () => coordinator.validateChannelSignInUrl(Uri.parse(value)),
        throwsA(isA<YouTubeMusicAccountException>()),
      );
    }
  });

  test(
    'restore and logout delegate only to the secure session store',
    () async {
      final credential = _credential();
      final store = _MemorySessionStore(value: credential);
      final client = _FakeAccountClient();
      final coordinator = YouTubeMusicAuthCoordinator(
        sessionStore: store,
        accountClient: client,
      );

      expect(await coordinator.restore(), same(credential));
      await coordinator.logout();

      expect(store.deleteCount, 1);
      expect(client.validationCalls, 0);
      expect(client.channelCalls, 0);
    },
  );
}

class _MemorySessionStore implements YouTubeMusicSessionStore {
  _MemorySessionStore({this.value});

  YouTubeMusicSessionCredential? value;
  final List<YouTubeMusicSessionCredential> writes =
      <YouTubeMusicSessionCredential>[];
  int deleteCount = 0;

  @override
  Future<YouTubeMusicSessionCredential?> read() async => value;

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {
    writes.add(credential);
    value = credential;
  }

  @override
  Future<void> delete() async {
    deleteCount += 1;
    value = null;
  }
}

class _FakeAccountClient implements YouTubeMusicAccountClient {
  _FakeAccountClient({
    this.profile,
    this.channels = const <YouTubeMusicAccountChannel>[],
    this.validationError,
  });

  final YouTubeMusicAccountProfile? profile;
  final List<YouTubeMusicAccountChannel> channels;
  final Object? validationError;
  final List<String> validatedCookies = <String>[];
  int validationCalls = 0;
  int channelCalls = 0;

  @override
  Future<YouTubeMusicAccountProfile> validateAccount(
    YouTubeMusicWebAuthData authData,
  ) async {
    validationCalls += 1;
    validatedCookies.add(authData.cookieHeader);
    final error = validationError;
    if (error != null) throw error;
    return profile ?? _profile('channel-default');
  }

  @override
  Future<List<YouTubeMusicAccountChannel>> listChannels(
    YouTubeMusicWebAuthData authData,
  ) async {
    channelCalls += 1;
    return channels;
  }
}

YouTubeMusicWebAuthData _authData([
  String cookieHeader = 'SAPISID=test-session-value',
]) => YouTubeMusicWebAuthData(
  cookieHeader: cookieHeader,
  identity: const YouTubeMusicAuthIdentity(
    visitorData: 'test-visitor-data',
    authUser: '0',
  ),
  apiKey: 'test_api_key',
  clientVersion: '1.20260822.00.00',
  clientName: 'WEB_REMIX',
);

YouTubeMusicAccountProfile _profile(String channelId) =>
    YouTubeMusicAccountProfile(
      channelId: channelId,
      displayName: 'Account $channelId',
    );

YouTubeMusicSessionCredential _credential() => YouTubeMusicSessionCredential(
  cookieHeader: 'SAPISID=test-session-value',
  identity: const YouTubeMusicAuthIdentity(
    visitorData: 'test-visitor-data',
    authUser: '0',
  ),
  profile: _profile('stored-channel'),
  validatedAt: DateTime.utc(2026, 8, 22),
  apiKey: 'test_api_key',
  clientVersion: '1.20260822.00.00',
  clientName: 'WEB_REMIX',
);
