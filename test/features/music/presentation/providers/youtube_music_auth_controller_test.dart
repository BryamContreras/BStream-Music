import 'dart:async';

import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_web_auth_port.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'restores only a public profile while retaining private credentials',
    () async {
      final credential = _credential('stored-channel');
      final store = _FakeSessionStore(value: credential);
      final container = _container(store: store, client: _FakeAccountClient());
      addTearDown(container.dispose);

      expect(
        container.read(youtubeMusicAuthControllerProvider).phase,
        YouTubeMusicAuthPhase.restoring,
      );
      await _settle();

      final state = container.read(youtubeMusicAuthControllerProvider);
      expect(state.phase, YouTubeMusicAuthPhase.authenticated);
      expect(state.profile?.channelId, 'stored-channel');
      expect(state.toString(), isNot(contains('test-session-value')));
      expect(state.toString(), isNot(contains('test-visitor-data')));
      expect(
        container
            .read(youtubeMusicAuthControllerProvider.notifier)
            .credentialForAuthenticatedRequests,
        same(credential),
      );
    },
  );

  test('publishes an anonymous state when no secure session exists', () async {
    final container = _container(
      store: _FakeSessionStore(),
      client: _FakeAccountClient(),
    );
    addTearDown(container.dispose);

    container.read(youtubeMusicAuthControllerProvider);
    await _settle();

    expect(
      container.read(youtubeMusicAuthControllerProvider).phase,
      YouTubeMusicAuthPhase.anonymous,
    );
  });

  test(
    'sanitizes secure-storage failures without exposing platform details',
    () async {
      final container = _container(
        store: _FakeSessionStore(
          readError: StateError('test-secret-platform-detail'),
        ),
        client: _FakeAccountClient(),
      );
      addTearDown(container.dispose);

      container.read(youtubeMusicAuthControllerProvider);
      await _settle();

      final state = container.read(youtubeMusicAuthControllerProvider);
      expect(state.phase, YouTubeMusicAuthPhase.error);
      expect(state.message, isNot(contains('test-secret-platform-detail')));
      expect(state.toString(), isNot(contains('test-secret-platform-detail')));
    },
  );

  test('validates and persists a single-channel login', () async {
    final store = _FakeSessionStore();
    final client = _FakeAccountClient(profile: _profile('channel-a'));
    final container = _container(store: store, client: client);
    addTearDown(container.dispose);
    container.read(youtubeMusicAuthControllerProvider);
    await _settle();
    final controller = container.read(
      youtubeMusicAuthControllerProvider.notifier,
    );

    controller.beginLogin();
    await controller.submitWebAuthentication(_authData());

    final state = container.read(youtubeMusicAuthControllerProvider);
    expect(state.phase, YouTubeMusicAuthPhase.authenticated);
    expect(state.profile?.channelId, 'channel-a');
    expect(client.channelCalls, 1);
    expect(client.validationCalls, 1);
    expect(store.writes, hasLength(1));
    expect(store.writes.single.apiKey, 'test_api_key');
    expect(store.writes.single.clientVersion, '1.20260822.00.00');
  });

  test(
    'transient channel discovery can fall back to account validation',
    () async {
      final store = _FakeSessionStore();
      final client = _FakeAccountClient(
        profile: _profile('channel-a'),
        channelError: const YouTubeMusicAccountException(
          YouTubeMusicAccountFailureKind.transient,
          'Temporary test failure.',
        ),
      );
      final container = _container(store: store, client: client);
      addTearDown(container.dispose);
      container.read(youtubeMusicAuthControllerProvider);
      await _settle();
      final controller = container.read(
        youtubeMusicAuthControllerProvider.notifier,
      );

      controller.beginLogin();
      await controller.submitWebAuthentication(_authData());

      expect(
        container.read(youtubeMusicAuthControllerProvider).phase,
        YouTubeMusicAuthPhase.authenticated,
      );
      expect(store.writes, hasLength(1));
    },
  );

  test(
    'requires explicit selection and validates the switched channel',
    () async {
      final store = _FakeSessionStore();
      final channelA = YouTubeMusicAccountChannel(
        profile: _profile('channel-a'),
        isSelected: true,
      );
      final channelB = YouTubeMusicAccountChannel(
        profile: _profile('channel-b'),
        isSelected: false,
        signInUrl: Uri.parse(
          'https://music.youtube.com/signin?action=switch&channel=channel-b',
        ),
      );
      final client = _FakeAccountClient(
        profile: _profile('channel-a'),
        channels: <YouTubeMusicAccountChannel>[channelA, channelB],
      );
      final container = _container(store: store, client: client);
      addTearDown(container.dispose);
      container.read(youtubeMusicAuthControllerProvider);
      await _settle();
      final controller = container.read(
        youtubeMusicAuthControllerProvider.notifier,
      );

      controller.beginLogin();
      await controller.submitWebAuthentication(_authData());
      var state = container.read(youtubeMusicAuthControllerProvider);
      expect(state.phase, YouTubeMusicAuthPhase.selectingChannel);
      expect(state.channels, hasLength(2));
      expect(client.validationCalls, 0);
      expect(store.writes, isEmpty);

      final target = await controller.chooseChannel(channelB);
      expect(target, channelB.signInUrl);
      expect(
        container.read(youtubeMusicAuthControllerProvider).phase,
        YouTubeMusicAuthPhase.authenticating,
      );

      client.profile = _profile('channel-b');
      await controller.submitWebAuthentication(_authData(authUser: '1'));
      state = container.read(youtubeMusicAuthControllerProvider);
      expect(state.phase, YouTubeMusicAuthPhase.authenticated);
      expect(state.profile?.channelId, 'channel-b');
      expect(client.channelCalls, 1);
      expect(client.validationCalls, 1);
      expect(store.writes, hasLength(1));
    },
  );

  test('cannot inject a channel that was not returned by discovery', () async {
    final knownA = YouTubeMusicAccountChannel(
      profile: _profile('channel-a'),
      isSelected: true,
    );
    final knownB = YouTubeMusicAccountChannel(
      profile: _profile('channel-b'),
      isSelected: false,
      signInUrl: Uri.parse('https://music.youtube.com/switch-b'),
    );
    final container = _container(
      store: _FakeSessionStore(),
      client: _FakeAccountClient(
        channels: <YouTubeMusicAccountChannel>[knownA, knownB],
      ),
    );
    addTearDown(container.dispose);
    container.read(youtubeMusicAuthControllerProvider);
    await _settle();
    final controller = container.read(
      youtubeMusicAuthControllerProvider.notifier,
    );
    controller.beginLogin();
    await controller.submitWebAuthentication(_authData());

    final target = await controller.chooseChannel(
      YouTubeMusicAccountChannel(
        profile: _profile('injected-channel'),
        isSelected: false,
        signInUrl: Uri.parse('https://music.youtube.com/injected'),
      ),
    );

    expect(target, isNull);
    final state = container.read(youtubeMusicAuthControllerProvider);
    expect(state.phase, YouTubeMusicAuthPhase.error);
    expect(state.channels, isEmpty);
  });

  test('logout invalidates a pending account validation', () async {
    final validation = Completer<YouTubeMusicAccountProfile>();
    final store = _FakeSessionStore();
    final client = _FakeAccountClient(validationGate: validation);
    final container = _container(store: store, client: client);
    addTearDown(container.dispose);
    container.read(youtubeMusicAuthControllerProvider);
    await _settle();
    final controller = container.read(
      youtubeMusicAuthControllerProvider.notifier,
    );

    controller.beginLogin();
    final login = controller.submitWebAuthentication(_authData());
    await _waitUntil(() => client.validationCalls == 1);
    await controller.logout();
    validation.complete(_profile('too-late'));
    await login;

    expect(
      container.read(youtubeMusicAuthControllerProvider).phase,
      YouTubeMusicAuthPhase.anonymous,
    );
    expect(controller.credentialForAuthenticatedRequests, isNull);
    expect(store.writes, isEmpty);
    expect(store.deleteCount, 1);
  });

  test(
    'logout compensates if an already-started secure write finishes late',
    () async {
      final writeGate = Completer<void>();
      final store = _FakeSessionStore(writeGate: writeGate);
      final client = _FakeAccountClient(profile: _profile('channel-a'));
      final container = _container(store: store, client: client);
      addTearDown(container.dispose);
      container.read(youtubeMusicAuthControllerProvider);
      await _settle();
      final controller = container.read(
        youtubeMusicAuthControllerProvider.notifier,
      );

      controller.beginLogin();
      final login = controller.submitWebAuthentication(_authData());
      await _waitUntil(() => store.writeStarted);
      final logout = controller.logout();
      expect(
        container.read(youtubeMusicAuthControllerProvider).phase,
        YouTubeMusicAuthPhase.anonymous,
      );
      writeGate.complete();
      await Future.wait<void>(<Future<void>>[login, logout]);

      expect(store.deleteCount, 2);
      expect(store.value, isNull);
      expect(controller.credentialForAuthenticatedRequests, isNull);
    },
  );

  test(
    'logout disables authentication even when cleanup operations fail',
    () async {
      final store = _FakeSessionStore(
        value: _credential('stored-channel'),
        deleteError: StateError('secure deletion failed'),
      );
      final webPort = _FakeWebAuthPort(cleanupError: StateError('web cleanup'));
      final container = _container(store: store, client: _FakeAccountClient());
      addTearDown(container.dispose);
      container.read(youtubeMusicAuthControllerProvider);
      await _settle();
      final controller = container.read(
        youtubeMusicAuthControllerProvider.notifier,
      );

      await controller.logout(webAuthPort: webPort);

      final state = container.read(youtubeMusicAuthControllerProvider);
      expect(state.phase, YouTubeMusicAuthPhase.anonymous);
      expect(state.message, contains('no se pudo eliminar'));
      expect(controller.credentialForAuthenticatedRequests, isNull);
      expect(webPort.cleanupCalls, 1);
    },
  );
}

ProviderContainer _container({
  required YouTubeMusicSessionStore store,
  required YouTubeMusicAccountClient client,
}) => ProviderContainer(
  overrides: [
    youtubeMusicSessionStoreProvider.overrideWithValue(store),
    youtubeMusicAccountClientProvider.overrideWithValue(client),
  ],
);

Future<void> _settle() async {
  for (var index = 0; index < 5; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition did not become true.');
}

class _FakeSessionStore implements YouTubeMusicSessionStore {
  _FakeSessionStore({
    this.value,
    this.readError,
    this.deleteError,
    this.writeGate,
  });

  YouTubeMusicSessionCredential? value;
  final Object? readError;
  final Object? deleteError;
  final Completer<void>? writeGate;
  final List<YouTubeMusicSessionCredential> writes =
      <YouTubeMusicSessionCredential>[];
  var writeStarted = false;
  var deleteCount = 0;

  @override
  Future<YouTubeMusicSessionCredential?> read() async {
    final error = readError;
    if (error != null) throw error;
    return value;
  }

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {
    writeStarted = true;
    await writeGate?.future;
    writes.add(credential);
    value = credential;
  }

  @override
  Future<void> delete() async {
    deleteCount += 1;
    final error = deleteError;
    if (error != null) throw error;
    value = null;
  }
}

class _FakeAccountClient implements YouTubeMusicAccountClient {
  _FakeAccountClient({
    this.profile,
    this.channels = const <YouTubeMusicAccountChannel>[],
    this.validationGate,
    this.channelError,
  });

  YouTubeMusicAccountProfile? profile;
  final List<YouTubeMusicAccountChannel> channels;
  final Completer<YouTubeMusicAccountProfile>? validationGate;
  final Object? channelError;
  var validationCalls = 0;
  var channelCalls = 0;

  @override
  Future<YouTubeMusicAccountProfile> validateAccount(
    YouTubeMusicWebAuthData authData,
  ) async {
    validationCalls += 1;
    final gate = validationGate;
    if (gate != null) return gate.future;
    return profile ?? _profile('default-channel');
  }

  @override
  Future<List<YouTubeMusicAccountChannel>> listChannels(
    YouTubeMusicWebAuthData authData,
  ) async {
    channelCalls += 1;
    final error = channelError;
    if (error != null) throw error;
    return channels;
  }
}

class _FakeWebAuthPort implements YouTubeMusicWebAuthPort {
  _FakeWebAuthPort({this.cleanupError});

  final Object? cleanupError;
  var cleanupCalls = 0;

  @override
  Future<YouTubeMusicWebCleanupResult> cleanup() async {
    cleanupCalls += 1;
    final error = cleanupError;
    if (error != null) throw error;
    return const YouTubeMusicWebCleanupResult(
      cookiesCleared: true,
      webStorageCleared: true,
      cacheCleared: true,
    );
  }

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}

  @override
  Future<void> navigate(Uri uri) async {}

  @override
  Future<void> prepare() async {}

  @override
  Future<YouTubeMusicWebAuthData> waitForAuthenticatedSession({
    int maximumAttempts = 20,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) {
    throw UnimplementedError();
  }
}

YouTubeMusicWebAuthData _authData({String authUser = '0'}) =>
    YouTubeMusicWebAuthData(
      cookieHeader: 'SAPISID=test-session-value',
      identity: YouTubeMusicAuthIdentity(
        visitorData: 'test-visitor-data',
        authUser: authUser,
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

YouTubeMusicSessionCredential _credential(String channelId) =>
    YouTubeMusicSessionCredential(
      cookieHeader: 'SAPISID=test-session-value',
      identity: const YouTubeMusicAuthIdentity(
        visitorData: 'test-visitor-data',
        authUser: '0',
      ),
      profile: _profile(channelId),
      validatedAt: DateTime.utc(2026, 8, 22),
      apiKey: 'test_api_key',
      clientVersion: '1.20260822.00.00',
      clientName: 'WEB_REMIX',
    );
