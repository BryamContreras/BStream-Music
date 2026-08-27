import 'dart:async';

import 'package:bstream_music/features/music/presentation/pages/desktop_youtube_music_login_page.dart';
import 'package:bstream_music/features/music/presentation/pages/youtube_music_login_page.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_account_button.dart';
import 'package:bstream_music/services/youtube_music/auth/cdp_youtube_music_web_auth_port.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_navigation_policy.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_web_auth_port.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('platform routing keeps Android embedded and desktops external', () {
    expect(
      buildYouTubeMusicLoginPageForPlatform(
        isWeb: false,
        platform: TargetPlatform.android,
      ),
      isA<YouTubeMusicLoginPage>(),
    );
    expect(
      buildYouTubeMusicLoginPageForPlatform(
        isWeb: false,
        platform: TargetPlatform.linux,
      ),
      isA<DesktopYouTubeMusicLoginPage>(),
    );
    expect(
      buildYouTubeMusicLoginPageForPlatform(
        isWeb: false,
        platform: TargetPlatform.windows,
      ),
      isA<DesktopYouTubeMusicLoginPage>(),
    );
  });

  testWidgets('prepares the external browser and can bring it back', (
    tester,
  ) async {
    final port = _FakeDesktopWebAuthPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_testApp(port));
    await tester.pumpAndSettle();

    expect(port.prepareCalls, 1);
    expect(find.text('Mostrar navegador'), findsOneWidget);
    expect(find.textContaining('perfil temporal'), findsOneWidget);

    await tester.tap(find.text('Mostrar navegador'));
    await tester.pumpAndSettle();

    expect(port.foregroundCalls, 1);
  });

  testWidgets('preparation retry creates a fresh browser port', (tester) async {
    final failedPort = _FakeDesktopWebAuthPort(
      prepareError: const YouTubeMusicWebAuthException('prepare-failed'),
      cleanupResults: const <YouTubeMusicWebCleanupResult>[
        YouTubeMusicWebCleanupResult(
          cookiesCleared: false,
          webStorageCleared: true,
          cacheCleared: true,
        ),
        YouTubeMusicWebCleanupResult(
          cookiesCleared: true,
          webStorageCleared: true,
          cacheCleared: true,
        ),
      ],
    );
    final readyPort = _FakeDesktopWebAuthPort();
    addTearDown(failedPort.dispose);
    addTearDown(readyPort.dispose);
    var factoryCalls = 0;

    await tester.pumpWidget(
      _testApp(
        failedPort,
        factory: () => factoryCalls++ == 0 ? failedPort : readyPort,
      ),
    );
    await _pumpUntil(
      tester,
      () => find.text('prepare-failed').evaluate().isNotEmpty,
    );

    expect(find.text('prepare-failed'), findsOneWidget);
    await _pumpUntil(tester, () => failedPort.cleanupCalls >= 2);
    expect(failedPort.cleanupCalls, 2);

    await tester.tap(find.text('Reintentar'));
    await _pumpUntil(
      tester,
      () => find.text('Mostrar navegador').evaluate().isNotEmpty,
    );

    expect(factoryCalls, 2);
    expect(readyPort.prepareCalls, 1);
    expect(find.text('Mostrar navegador'), findsOneWidget);
  });

  testWidgets('YouTube navigation completes authentication and cleans once', (
    tester,
  ) async {
    final store = _MemorySessionStore();
    final client = _FakeAccountClient(profile: _profile('desktop-channel'));
    final port = _FakeDesktopWebAuthPort(authData: _authData());
    final container = _testContainer(store: store, client: client);
    addTearDown(port.dispose);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testApp(port, includeLoginRoute: true, container: container),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(youtubeMusicAuthControllerProvider).phase,
      YouTubeMusicAuthPhase.authenticating,
    );

    port.emitNavigation(Uri.parse('https://music.youtube.com/'));
    await tester.pump();
    await tester.pump();
    expect(port.authenticationWaitCalls, 1);
    expect(client.channelCalls, 1);
    await _pumpUntil(
      tester,
      () => find.text('home-marker').evaluate().isNotEmpty,
    );

    expect(find.text('home-marker'), findsOneWidget);
    expect(store.writes, hasLength(1));
    expect(store.writes.single.profile.channelId, 'desktop-channel');
    expect(port.authenticationWaitCalls, 1);
    expect(port.cleanupCalls, 1);
  });

  testWidgets('channel selection minimizes and then restores the browser', (
    tester,
  ) async {
    final selected = YouTubeMusicAccountChannel(
      profile: _profile('channel-a'),
      isSelected: true,
    );
    final alternate = YouTubeMusicAccountChannel(
      profile: _profile('channel-b'),
      isSelected: false,
      signInUrl: Uri.parse('https://music.youtube.com/switch/channel-b'),
    );
    final client = _FakeAccountClient(
      profile: _profile('channel-a'),
      channels: <YouTubeMusicAccountChannel>[selected, alternate],
    );
    final port = _FakeDesktopWebAuthPort(authData: _authData());
    final container = _testContainer(client: client);
    addTearDown(port.dispose);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      _testApp(port, includeLoginRoute: true, container: container),
    );
    await tester.pumpAndSettle();
    expect(
      container.read(youtubeMusicAuthControllerProvider).phase,
      YouTubeMusicAuthPhase.authenticating,
    );

    port.emitNavigation(Uri.parse('https://music.youtube.com/'));
    await tester.pump();
    await tester.pump();
    expect(port.authenticationWaitCalls, 1);
    expect(
      container.read(youtubeMusicAuthControllerProvider).phase,
      YouTubeMusicAuthPhase.selectingChannel,
    );
    expect(client.channelCalls, 1);
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('youtube-music-channel-picker'))
          .evaluate()
          .isNotEmpty,
    );

    expect(
      find.byKey(const Key('youtube-music-channel-picker')),
      findsOneWidget,
    );
    expect(port.minimizeCalls, 1);

    await tester.tap(find.byKey(const Key('youtube-music-channel-channel-b')));
    await _pumpUntil(tester, () => port.navigations.isNotEmpty);

    expect(port.navigations, <Uri>[alternate.signInUrl!]);
    expect(port.foregroundCalls, 1);
    expect(
      find.byKey(const Key('youtube-music-desktop-login-page')),
      findsOneWidget,
    );
  });

  testWidgets('closing the browser cancels and cleans the route once', (
    tester,
  ) async {
    final port = _FakeDesktopWebAuthPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_testApp(port, includeLoginRoute: true));
    await tester.pumpAndSettle();

    port.emitBrowserClosed();
    await _pumpUntil(
      tester,
      () => find.text('home-marker').evaluate().isNotEmpty,
    );

    expect(find.text('home-marker'), findsOneWidget);
    expect(port.cleanupCalls, 1);
  });

  testWidgets('cancel action closes and cleans the temporary browser once', (
    tester,
  ) async {
    final port = _FakeDesktopWebAuthPort();
    addTearDown(port.dispose);

    await tester.pumpWidget(_testApp(port, includeLoginRoute: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancelar'));
    await _pumpUntil(
      tester,
      () => find.text('home-marker').evaluate().isNotEmpty,
    );

    expect(port.cleanupCalls, 1);
  });

  testWidgets(
    'partial cleanup is retried and subscription cancellation errors are safe',
    (tester) async {
      final port = _FakeDesktopWebAuthPort(
        cleanupResults: const <YouTubeMusicWebCleanupResult>[
          YouTubeMusicWebCleanupResult(
            cookiesCleared: false,
            webStorageCleared: true,
            cacheCleared: true,
          ),
          YouTubeMusicWebCleanupResult(
            cookiesCleared: true,
            webStorageCleared: true,
            cacheCleared: true,
          ),
        ],
        subscriptionCancelError: StateError('cancel-failed'),
      );
      addTearDown(port.dispose);

      await tester.pumpWidget(_testApp(port, includeLoginRoute: true));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancelar'));
      await _pumpUntil(
        tester,
        () => find.text('home-marker').evaluate().isNotEmpty,
      );
      await _pumpUntil(tester, () => port.cleanupCalls >= 2);

      expect(port.cleanupCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (predicate()) return;
  }
  final text = find
      .byType(Text)
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .toList();
  fail('Widget condition did not become true. Visible text: $text');
}

Widget _testApp(
  _FakeDesktopWebAuthPort port, {
  bool includeLoginRoute = false,
  _MemorySessionStore? store,
  YouTubeMusicAccountClient? client,
  DesktopYouTubeMusicWebAuthPortFactory? factory,
  ProviderContainer? container,
}) {
  final loginPage = DesktopYouTubeMusicLoginPage(
    webAuthPortFactory: factory ?? () => port,
  );
  final app = includeLoginRoute
      ? MaterialApp(
          initialRoute: '/login',
          routes: <String, WidgetBuilder>{
            '/': (_) => const Scaffold(body: Text('home-marker')),
            '/login': (_) => loginPage,
          },
        )
      : MaterialApp(home: loginPage);
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(
    overrides: [
      youtubeMusicSessionStoreProvider.overrideWithValue(
        store ?? _MemorySessionStore(),
      ),
      youtubeMusicAccountClientProvider.overrideWithValue(
        client ?? const UnconfiguredYouTubeMusicAccountClient(),
      ),
    ],
    child: app,
  );
}

ProviderContainer _testContainer({
  _MemorySessionStore? store,
  YouTubeMusicAccountClient? client,
}) => ProviderContainer(
  overrides: [
    youtubeMusicSessionStoreProvider.overrideWithValue(
      store ?? _MemorySessionStore(),
    ),
    youtubeMusicAccountClientProvider.overrideWithValue(
      client ?? const UnconfiguredYouTubeMusicAccountClient(),
    ),
  ],
);

class _FakeDesktopWebAuthPort implements DesktopYouTubeMusicWebAuthPort {
  _FakeDesktopWebAuthPort({
    YouTubeMusicWebAuthData? authData,
    this.prepareError,
    this.cleanupResults = const <YouTubeMusicWebCleanupResult>[
      YouTubeMusicWebCleanupResult(
        cookiesCleared: true,
        webStorageCleared: true,
        cacheCleared: true,
      ),
    ],
    this.subscriptionCancelError,
  }) : assert(cleanupResults.isNotEmpty),
       authData = authData ?? _authData();

  final YouTubeMusicWebAuthData authData;
  final Object? prepareError;
  final List<YouTubeMusicWebCleanupResult> cleanupResults;
  final Object? subscriptionCancelError;
  final _navigationController = StreamController<Uri>.broadcast();
  final _browserClosedController = StreamController<void>.broadcast();
  final List<Uri> navigations = <Uri>[];
  Uri? _currentUri;
  var _prepared = false;
  var prepareCalls = 0;
  var authenticationWaitCalls = 0;
  var foregroundCalls = 0;
  var minimizeCalls = 0;
  var cleanupCalls = 0;

  @override
  YouTubeMusicNavigationPolicy get navigationPolicy =>
      const YouTubeMusicNavigationPolicy();

  @override
  Stream<Uri> get navigationStream =>
      _cancelAwareStream(_navigationController.stream);

  @override
  Stream<void> get browserClosedStream =>
      _cancelAwareStream(_browserClosedController.stream);

  @override
  Uri? get currentUri => _currentUri;

  @override
  bool get isPrepared => _prepared;

  @override
  Future<void> prepare() async {
    prepareCalls += 1;
    final error = prepareError;
    if (error != null) throw error;
    _prepared = true;
    _currentUri = DesktopYouTubeMusicLoginPage.initialLoginUri;
  }

  @override
  Future<void> bringToForeground() async {
    foregroundCalls += 1;
  }

  @override
  Future<void> minimize() async {
    minimizeCalls += 1;
  }

  @override
  Future<YouTubeMusicWebAuthData> waitForAuthenticatedSession({
    int maximumAttempts = 20,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    authenticationWaitCalls += 1;
    return authData;
  }

  @override
  Future<void> navigate(Uri uri) async {
    navigations.add(uri);
    _currentUri = uri;
  }

  @override
  Future<bool> canGoBack() async => false;

  @override
  Future<void> goBack() async {}

  @override
  Future<YouTubeMusicWebCleanupResult> cleanup() async {
    final resultIndex = cleanupCalls < cleanupResults.length
        ? cleanupCalls
        : cleanupResults.length - 1;
    cleanupCalls += 1;
    return cleanupResults[resultIndex];
  }

  Stream<T> _cancelAwareStream<T>(Stream<T> stream) {
    final error = subscriptionCancelError;
    return error == null ? stream : _CancelErrorStream<T>(stream, error);
  }

  void emitNavigation(Uri uri) {
    _currentUri = uri;
    _navigationController.add(uri);
  }

  void emitBrowserClosed() => _browserClosedController.add(null);

  Future<void> dispose() async {
    await _navigationController.close();
    await _browserClosedController.close();
  }
}

class _CancelErrorStream<T> extends Stream<T> {
  const _CancelErrorStream(this.delegate, this.cancelError);

  final Stream<T> delegate;
  final Object cancelError;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _CancelErrorSubscription<T>(
    delegate.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
    cancelError,
  );
}

class _CancelErrorSubscription<T> implements StreamSubscription<T> {
  const _CancelErrorSubscription(this.delegate, this.cancelError);

  final StreamSubscription<T> delegate;
  final Object cancelError;

  @override
  Future<void> cancel() async {
    await delegate.cancel();
    throw cancelError;
  }

  @override
  void onData(void Function(T data)? handleData) => delegate.onData(handleData);

  @override
  void onError(Function? handleError) => delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => delegate.pause(resumeSignal);

  @override
  void resume() => delegate.resume();

  @override
  bool get isPaused => delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => delegate.asFuture(futureValue);
}

class _MemorySessionStore implements YouTubeMusicSessionStore {
  final List<YouTubeMusicSessionCredential> writes =
      <YouTubeMusicSessionCredential>[];

  @override
  Future<void> delete() async {}

  @override
  Future<YouTubeMusicSessionCredential?> read() async => null;

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {
    writes.add(credential);
  }
}

class _FakeAccountClient implements YouTubeMusicAccountClient {
  _FakeAccountClient({
    required this.profile,
    this.channels = const <YouTubeMusicAccountChannel>[],
  });

  YouTubeMusicAccountProfile profile;
  final List<YouTubeMusicAccountChannel> channels;
  var channelCalls = 0;
  var validationCalls = 0;

  @override
  Future<List<YouTubeMusicAccountChannel>> listChannels(
    YouTubeMusicWebAuthData authData,
  ) async {
    channelCalls += 1;
    return channels;
  }

  @override
  Future<YouTubeMusicAccountProfile> validateAccount(
    YouTubeMusicWebAuthData authData,
  ) async {
    validationCalls += 1;
    return profile;
  }
}

YouTubeMusicWebAuthData _authData() => YouTubeMusicWebAuthData(
  cookieHeader: 'SAPISID=desktop-test-session',
  identity: const YouTubeMusicAuthIdentity(
    visitorData: 'desktop-test-visitor',
    authUser: '0',
  ),
  apiKey: 'desktop_test_api_key',
  clientVersion: '1.20260827.00.00',
  clientName: 'WEB_REMIX',
);

YouTubeMusicAccountProfile _profile(String channelId) =>
    YouTubeMusicAccountProfile(
      channelId: channelId,
      displayName: 'Account $channelId',
    );
