import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/playlist.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:bstream_music/features/music/presentation/providers/youtube_music_auth_controller.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_account_button.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_account_client.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_auth_models.dart';
import 'package:bstream_music/services/youtube_music/auth/youtube_music_session_store.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_account_sync_coordinator.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_consent_store.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'AccountButton starts exactly one app-start sync after session restore',
    (tester) async {
      final coordinator = _RecordingSyncCoordinator(
        (_, _) async => _successfulResult(),
      );
      final container = _container(
        store: _MemorySessionStore(value: _credential()),
        coordinator: coordinator,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_accountButtonHost(container));
      await _pumpUntil(tester, () => coordinator.triggers.isNotEmpty);
      await _pumpUntil(
        tester,
        () =>
            container.read(youtubeMusicPlaylistSyncControllerProvider).phase ==
            YouTubeMusicPlaylistSyncPhase.synchronized,
      );

      expect(coordinator.triggers, <PlaylistSyncTrigger>[
        PlaylistSyncTrigger.appStart,
      ]);
      expect(
        container.read(youtubeMusicAuthControllerProvider).isAuthenticated,
        isTrue,
      );

      // Rebuilding the Home action must not create another startup pass.
      await tester.pumpWidget(_accountButtonHost(container));
      await tester.pump();
      await tester.pump();
      expect(coordinator.triggers, hasLength(1));
    },
  );

  testWidgets(
    'restored session declines safely and Sync now requests consent again',
    (tester) async {
      final consentStore = _MemoryConsentStore();
      final coordinator = _RecordingSyncCoordinator(
        (_, _) async => _successfulResult(),
      );
      final container = _container(
        store: _MemorySessionStore(value: _credential()),
        coordinator: coordinator,
        consentStore: consentStore,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        _accountButtonHost(container, useDefaultFlow: true),
      );
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('youtube-music-playlist-sync-consent'))
            .evaluate()
            .isNotEmpty,
      );

      expect(coordinator.triggers, isEmpty);
      expect(
        container.read(youtubeMusicAuthControllerProvider).isAuthenticated,
        isTrue,
      );
      await tester.tap(
        find.byKey(const Key('youtube-music-playlist-sync-not-now')),
      );
      await tester.pumpAndSettle();

      container
          .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
          .requestAutomaticSync();
      await tester.pump(const Duration(seconds: 3));
      expect(coordinator.triggers, isEmpty);

      await tester.tap(find.byKey(const Key('home-youtube-music-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('youtube-music-account-sync')));
      await _pumpUntil(
        tester,
        () => find
            .byKey(const Key('youtube-music-playlist-sync-consent'))
            .evaluate()
            .isNotEmpty,
      );
      expect(coordinator.triggers, isEmpty);

      await tester.tap(
        find.byKey(const Key('youtube-music-playlist-sync-accept')),
      );
      await _pumpUntil(tester, () => coordinator.triggers.length == 1);

      expect(coordinator.triggers, <PlaylistSyncTrigger>[
        PlaylistSyncTrigger.appStart,
      ]);
      expect(consentStore.grantCalls, 1);
      expect(consentStore.grantedAccounts, contains('test-channel'));
    },
  );

  testWidgets('fresh login waits for explicit sync consent', (tester) async {
    final consentStore = _MemoryConsentStore();
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _successfulResult(),
    );
    final container = _container(
      store: _MemorySessionStore(),
      coordinator: coordinator,
      consentStore: consentStore,
      accountClient: _SuccessfulAccountClient(),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(
      tester,
      () =>
          container.read(youtubeMusicAuthControllerProvider).phase ==
          YouTubeMusicAuthPhase.anonymous,
    );
    final auth = container.read(youtubeMusicAuthControllerProvider.notifier);
    auth.beginLogin();
    await auth.submitWebAuthentication(_webAuthData());
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('youtube-music-playlist-sync-consent'))
          .evaluate()
          .isNotEmpty,
    );

    expect(coordinator.triggers, isEmpty);
    await tester.tap(
      find.byKey(const Key('youtube-music-playlist-sync-accept')),
    );
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);

    expect(coordinator.triggers.single, PlaylistSyncTrigger.appStart);
    expect(consentStore.grantCalls, 1);
  });

  testWidgets('concurrent consent acceptance coalesces one app-start pass', (
    tester,
  ) async {
    final consentStore = _MemoryConsentStore();
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _successfulResult(),
    );
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
      consentStore: consentStore,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(
      tester,
      () => find
          .byKey(const Key('youtube-music-playlist-sync-consent'))
          .evaluate()
          .isNotEmpty,
    );
    await tester.tap(
      find.byKey(const Key('youtube-music-playlist-sync-not-now')),
    );
    await tester.pumpAndSettle();

    final controller = container.read(
      youtubeMusicPlaylistSyncControllerProvider.notifier,
    );
    final first = controller.acceptConsentAndSync('test-channel');
    final second = controller.acceptConsentAndSync('test-channel');

    expect(identical(first, second), isTrue);
    await Future.wait(<Future<PlaylistAccountSyncResult?>>[first, second]);
    expect(consentStore.grantCalls, 1);
    expect(coordinator.triggers, <PlaylistSyncTrigger>[
      PlaylistSyncTrigger.appStart,
    ]);
  });

  testWidgets(
    'acceptance racing a stale consent read still schedules one app-start pass',
    (tester) async {
      final consentStore = _BlockingConsentStore();
      final coordinator = _RecordingSyncCoordinator(
        (_, _) async => _successfulResult(),
      );
      final container = _container(
        store: _MemorySessionStore(value: _credential()),
        coordinator: coordinator,
        consentStore: consentStore,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_accountButtonHost(container));
      await _pumpUntil(tester, () => consentStore.readCalls == 1);

      final accepted = await container
          .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
          .acceptConsentAndSync('test-channel');
      expect(accepted, isNotNull);
      expect(coordinator.triggers, <PlaylistSyncTrigger>[
        PlaylistSyncTrigger.appStart,
      ]);

      // The restore read began before grantConsent and returns its stale
      // negative value afterwards. It must not revoke consent or enqueue a
      // second startup pass.
      consentStore.completeRead(false);
      await tester.pump();
      await tester.pump();

      expect(
        container
            .read(youtubeMusicPlaylistSyncControllerProvider)
            .consentStatus,
        YouTubeMusicPlaylistSyncConsentStatus.granted,
      );
      expect(coordinator.triggers, <PlaylistSyncTrigger>[
        PlaylistSyncTrigger.appStart,
      ]);
    },
  );

  testWidgets(
    'manual sync waiting on consent cannot publish for a logged-out session',
    (tester) async {
      final consentStore = _BlockingConsentStore();
      final coordinator = _RecordingSyncCoordinator(
        (_, _) async => _successfulResult(),
      );
      final container = _container(
        store: _MemorySessionStore(value: _credential()),
        coordinator: coordinator,
        consentStore: consentStore,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_accountButtonHost(container));
      await _pumpUntil(tester, () => consentStore.readCalls == 1);
      final sync = container
          .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
          .syncNow();

      await container
          .read(youtubeMusicAuthControllerProvider.notifier)
          .logout();
      consentStore.completeRead(false);
      expect(await sync, isNull);
      await tester.pump();

      final state = container.read(youtubeMusicPlaylistSyncControllerProvider);
      expect(
        state.consentStatus,
        YouTubeMusicPlaylistSyncConsentStatus.unavailable,
      );
      expect(state.consentAccountKey, isNull);
      expect(coordinator.triggers, isEmpty);
    },
  );

  testWidgets('AccountButton observes a login and starts one app-start sync', (
    tester,
  ) async {
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _successfulResult(),
    );
    final container = _container(
      store: _MemorySessionStore(),
      coordinator: coordinator,
      accountClient: _SuccessfulAccountClient(),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(
      tester,
      () =>
          container.read(youtubeMusicAuthControllerProvider).phase ==
          YouTubeMusicAuthPhase.anonymous,
    );
    expect(coordinator.triggers, isEmpty);

    final auth = container.read(youtubeMusicAuthControllerProvider.notifier);
    auth.beginLogin();
    await auth.submitWebAuthentication(_webAuthData());
    await _pumpUntil(tester, () => coordinator.triggers.isNotEmpty);
    await _pumpUntil(
      tester,
      () =>
          container.read(youtubeMusicPlaylistSyncControllerProvider).phase ==
          YouTubeMusicPlaylistSyncPhase.synchronized,
    );

    expect(coordinator.triggers, <PlaylistSyncTrigger>[
      PlaylistSyncTrigger.appStart,
    ]);
  });

  testWidgets('manual sync waits for app-start and runs as the next pass', (
    tester,
  ) async {
    final startup = Completer<PlaylistAccountSyncResult>();
    final manual = Completer<PlaylistAccountSyncResult>();
    final coordinator = _RecordingSyncCoordinator((call, trigger) {
      return call == 1 ? startup.future : manual.future;
    });
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);
    expect(coordinator.triggers.single, PlaylistSyncTrigger.appStart);

    PlaylistAccountSyncResult? manualResult;
    var manualCompleted = false;
    unawaited(
      container
          .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
          .syncNow()
          .then((value) {
            manualResult = value;
            manualCompleted = true;
          }),
    );
    await tester.pump();
    expect(coordinator.triggers, hasLength(1));
    expect(manualCompleted, isFalse);

    startup.complete(_successfulResult(importedRemoteCount: 1));
    await _pumpUntil(tester, () => coordinator.triggers.length == 2);
    expect(coordinator.triggers, <PlaylistSyncTrigger>[
      PlaylistSyncTrigger.appStart,
      PlaylistSyncTrigger.manual,
    ]);

    manual.complete(_successfulResult(importedRemoteCount: 2));
    await _pumpUntil(tester, () => manualCompleted);
    expect(manualResult?.importedRemoteCount, 2);
  });

  testWidgets('a deferred result retries once and success clears the retry', (
    tester,
  ) async {
    final coordinator = _RecordingSyncCoordinator((call, trigger) async {
      return call == 1 ? _deferredResult() : _successfulResult();
    });
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
      retryBackoff: const <Duration>[Duration(milliseconds: 10)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(
      tester,
      () =>
          container
              .read(youtubeMusicPlaylistSyncControllerProvider)
              .deferredCount ==
          1,
    );

    await tester.pump(const Duration(milliseconds: 9));
    expect(coordinator.triggers, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    await _pumpUntil(tester, () => coordinator.triggers.length == 2);
    expect(coordinator.triggers.last, PlaylistSyncTrigger.automatic);

    await _pumpUntil(
      tester,
      () =>
          container
              .read(youtubeMusicPlaylistSyncControllerProvider)
              .deferredCount ==
          0,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(coordinator.triggers, hasLength(2));
  });

  testWidgets('bootstrap failures use the bounded retry schedule', (
    tester,
  ) async {
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _bootstrapFailureResult(),
    );
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
      retryBackoff: const <Duration>[
        Duration(milliseconds: 5),
        Duration(milliseconds: 7),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);
    await _pumpUntil(
      tester,
      () =>
          container.read(youtubeMusicPlaylistSyncControllerProvider).phase ==
          YouTubeMusicPlaylistSyncPhase.error,
    );

    await tester.pump(const Duration(milliseconds: 5));
    await _pumpUntil(tester, () => coordinator.triggers.length == 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 7));
    await _pumpUntil(tester, () => coordinator.triggers.length == 3);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(coordinator.triggers, <PlaylistSyncTrigger>[
      PlaylistSyncTrigger.appStart,
      PlaylistSyncTrigger.automatic,
      PlaylistSyncTrigger.automatic,
    ]);
  });

  testWidgets('logout cancels an already scheduled retry', (tester) async {
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _bootstrapFailureResult(),
    );
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
      retryBackoff: const <Duration>[Duration(milliseconds: 50)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);
    await _pumpUntil(
      tester,
      () =>
          container.read(youtubeMusicPlaylistSyncControllerProvider).phase ==
          YouTubeMusicPlaylistSyncPhase.error,
    );

    await container.read(youtubeMusicAuthControllerProvider.notifier).logout();
    await tester.pump(const Duration(milliseconds: 500));

    expect(coordinator.triggers, hasLength(1));
    expect(
      container.read(youtubeMusicAuthControllerProvider).phase,
      YouTubeMusicAuthPhase.anonymous,
    );
  });

  testWidgets('disposing the controller cancels an already scheduled retry', (
    tester,
  ) async {
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _bootstrapFailureResult(),
    );
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
      retryBackoff: const <Duration>[Duration(milliseconds: 50)],
    );

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);
    await _pumpUntil(
      tester,
      () =>
          container.read(youtubeMusicPlaylistSyncControllerProvider).phase ==
          YouTubeMusicPlaylistSyncPhase.error,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 500));
    expect(coordinator.triggers, hasLength(1));
  });

  testWidgets('resuming the app requests an automatic sync', (tester) async {
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _successfulResult(),
    );
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpUntil(tester, () => coordinator.triggers.length == 2);

    expect(coordinator.triggers, <PlaylistSyncTrigger>[
      PlaylistSyncTrigger.appStart,
      PlaylistSyncTrigger.automatic,
    ]);
  });

  testWidgets(
    'resolveConflict is false when manual sync recreates the same conflict',
    (tester) async {
      final original = _unresolvedConflict();
      final recreated = _unresolvedConflict(
        kind: PlaylistSyncConflictKind.order,
        message: 'The manual pass found the conflict again.',
      );
      final syncStore = _ConflictStore(<PlaylistSyncUnresolvedConflict>[
        original,
      ]);
      final coordinator = _RecordingSyncCoordinator((call, trigger) async {
        if (trigger == PlaylistSyncTrigger.manual) {
          syncStore.conflicts = <PlaylistSyncUnresolvedConflict>[recreated];
        }
        return _successfulResult();
      });
      final container = _container(
        store: _MemorySessionStore(value: _credential()),
        coordinator: coordinator,
        syncStore: syncStore,
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(_accountButtonHost(container));
      await _pumpUntil(tester, () => coordinator.triggers.length == 1);
      await _pumpUntil(
        tester,
        () =>
            container.read(youtubeMusicPlaylistSyncControllerProvider).phase ==
            YouTubeMusicPlaylistSyncPhase.synchronized,
      );

      final resolved = await container
          .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
          .resolveConflict(original, PlaylistSyncConflictResolution.keepLocal);

      expect(coordinator.triggers.last, PlaylistSyncTrigger.manual);
      expect(syncStore.resolutions, <PlaylistSyncConflictResolution>[
        PlaylistSyncConflictResolution.keepLocal,
      ]);
      expect(syncStore.listCalls, greaterThanOrEqualTo(1));
      expect(resolved, isFalse);
    },
  );

  testWidgets('resolveConflict is true only after the key disappears', (
    tester,
  ) async {
    final original = _unresolvedConflict();
    final syncStore = _ConflictStore(<PlaylistSyncUnresolvedConflict>[
      original,
    ]);
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _successfulResult(),
    );
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
      syncStore: syncStore,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);
    await _pumpUntil(
      tester,
      () =>
          container.read(youtubeMusicPlaylistSyncControllerProvider).phase ==
          YouTubeMusicPlaylistSyncPhase.synchronized,
    );

    final resolved = await container
        .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
        .resolveConflict(original, PlaylistSyncConflictResolution.keepRemote);

    expect(coordinator.triggers.last, PlaylistSyncTrigger.manual);
    expect(syncStore.listCalls, greaterThanOrEqualTo(1));
    expect(syncStore.conflicts, isEmpty);
    expect(resolved, isTrue);
  });

  testWidgets('an in-flight conflict list is discarded after logout', (
    tester,
  ) async {
    final pending = Completer<List<PlaylistSyncUnresolvedConflict>>();
    final syncStore = _ConflictStore(
      const <PlaylistSyncUnresolvedConflict>[],
      onList: (_) => pending.future,
    );
    final coordinator = _RecordingSyncCoordinator(
      (_, _) async => _successfulResult(),
    );
    final container = _container(
      store: _MemorySessionStore(value: _credential()),
      coordinator: coordinator,
      syncStore: syncStore,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_accountButtonHost(container));
    await _pumpUntil(tester, () => coordinator.triggers.length == 1);
    final conflicts = container
        .read(youtubeMusicPlaylistSyncControllerProvider.notifier)
        .unresolvedConflicts();
    await _pumpUntil(tester, () => syncStore.listCalls == 1);

    await container.read(youtubeMusicAuthControllerProvider.notifier).logout();
    pending.complete(<PlaylistSyncUnresolvedConflict>[_unresolvedConflict()]);

    expect(await conflicts, isEmpty);
  });
}

ProviderContainer _container({
  required YouTubeMusicSessionStore store,
  required _RecordingSyncCoordinator coordinator,
  YouTubeMusicAccountClient? accountClient,
  PlaylistSyncConsentStore? consentStore,
  PlaylistSyncStore? syncStore,
  List<Duration> retryBackoff = const <Duration>[Duration(seconds: 1)],
}) {
  final playlists = _RecordingPlaylistsController();
  return ProviderContainer(
    overrides: [
      youtubeMusicSessionStoreProvider.overrideWithValue(store),
      youtubeMusicPlaylistSyncConsentStoreProvider.overrideWithValue(
        consentStore ?? _MemoryConsentStore(grantedAccounts: {'test-channel'}),
      ),
      youtubeMusicAccountClientProvider.overrideWithValue(
        accountClient ?? const UnconfiguredYouTubeMusicAccountClient(),
      ),
      appStringsProvider.overrideWithValue(
        const AppStrings(AppLanguage.english),
      ),
      playlistsControllerProvider.overrideWith(() => playlists),
      youtubeMusicPlaylistSyncRetryBackoffProvider.overrideWithValue(
        retryBackoff,
      ),
      youtubeMusicPlaylistSyncRuntimeProvider.overrideWithValue(
        YouTubeMusicPlaylistSyncRuntime(
          accountKey: 'test-channel',
          sessionGeneration: 0,
          coordinator: coordinator,
          store: syncStore,
        ),
      ),
    ],
  );
}

Widget _accountButtonHost(
  ProviderContainer container, {
  bool useDefaultFlow = false,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: <Widget>[
            YouTubeMusicAccountButton(
              strings: const AppStrings(AppLanguage.english),
              onPressed: useDefaultFlow ? null : (_, _, _) async {},
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (predicate()) return;
    await tester.pump();
  }
  fail('Condition did not become true.');
}

typedef _SyncHandler =
    Future<PlaylistAccountSyncResult> Function(
      int call,
      PlaylistSyncTrigger trigger,
    );

class _RecordingSyncCoordinator implements PlaylistAccountSyncCoordinator {
  _RecordingSyncCoordinator(this._handler);

  final _SyncHandler _handler;
  final List<PlaylistSyncTrigger> triggers = <PlaylistSyncTrigger>[];

  @override
  Future<PlaylistAccountSyncResult> syncAll(
    String accountKey, {
    PlaylistSyncTrigger trigger = PlaylistSyncTrigger.manual,
    PlaylistSyncMode newBindingMode = PlaylistSyncMode.automatic,
  }) {
    triggers.add(trigger);
    return _handler(triggers.length, trigger);
  }
}

class _RecordingPlaylistsController extends PlaylistsController {
  var reloadCalls = 0;

  @override
  Future<List<Playlist>> build() async => const <Playlist>[];

  @override
  Future<void> reloadFromRepository({bool syncActiveQueue = true}) async {
    reloadCalls += 1;
    state = const AsyncData<List<Playlist>>(<Playlist>[]);
  }
}

typedef _ConflictListHandler =
    Future<List<PlaylistSyncUnresolvedConflict>> Function(String accountKey);

class _ConflictStore implements PlaylistSyncStore {
  _ConflictStore(List<PlaylistSyncUnresolvedConflict> conflicts, {this.onList})
    : conflicts = List<PlaylistSyncUnresolvedConflict>.of(conflicts);

  List<PlaylistSyncUnresolvedConflict> conflicts;
  final _ConflictListHandler? onList;
  final List<PlaylistSyncConflictResolution> resolutions =
      <PlaylistSyncConflictResolution>[];
  var listCalls = 0;

  @override
  Future<List<PlaylistSyncUnresolvedConflict>> listUnresolvedConflicts({
    required String accountKey,
  }) async {
    listCalls += 1;
    final handler = onList;
    if (handler != null) return handler(accountKey);
    return List<PlaylistSyncUnresolvedConflict>.unmodifiable(conflicts);
  }

  @override
  Future<void> resolveConflict({
    required PlaylistSyncKey key,
    required PlaylistSyncConflictResolution resolution,
    required int expectedLocalRevision,
    required DateTime now,
  }) async {
    resolutions.add(resolution);
    conflicts.removeWhere((conflict) => conflict.key == key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryConsentStore implements PlaylistSyncConsentStore {
  _MemoryConsentStore({Iterable<String> grantedAccounts = const <String>[]})
    : grantedAccounts = <String>{...grantedAccounts};

  final Set<String> grantedAccounts;
  var readCalls = 0;
  var grantCalls = 0;

  @override
  Future<void> grantConsent(String accountKey) async {
    grantCalls += 1;
    grantedAccounts.add(accountKey);
  }

  @override
  Future<bool> hasConsent(String accountKey) async {
    readCalls += 1;
    return grantedAccounts.contains(accountKey);
  }
}

class _BlockingConsentStore implements PlaylistSyncConsentStore {
  final Completer<bool> _read = Completer<bool>();
  var readCalls = 0;
  var grantCalls = 0;

  void completeRead(bool value) => _read.complete(value);

  @override
  Future<void> grantConsent(String accountKey) async {
    grantCalls += 1;
  }

  @override
  Future<bool> hasConsent(String accountKey) {
    readCalls += 1;
    return _read.future;
  }
}

class _MemorySessionStore implements YouTubeMusicSessionStore {
  _MemorySessionStore({this.value});

  YouTubeMusicSessionCredential? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<YouTubeMusicSessionCredential?> read() async => value;

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) async {
    value = credential;
  }
}

class _SuccessfulAccountClient implements YouTubeMusicAccountClient {
  @override
  Future<List<YouTubeMusicAccountChannel>> listChannels(
    YouTubeMusicWebAuthData authData,
  ) async => const <YouTubeMusicAccountChannel>[];

  @override
  Future<YouTubeMusicAccountProfile> validateAccount(
    YouTubeMusicWebAuthData authData,
  ) async => _profile();
}

PlaylistAccountSyncResult _successfulResult({int importedRemoteCount = 0}) =>
    PlaylistAccountSyncResult(
      results: const <PlaylistSyncKey, PlaylistSyncResult>{},
      importedRemoteCount: importedRemoteCount,
      linkedLocalCount: 0,
    );

PlaylistAccountSyncResult _deferredResult() => PlaylistAccountSyncResult(
  results: <PlaylistSyncKey, PlaylistSyncResult>{
    const PlaylistSyncKey(
      accountKey: 'test-channel',
      playlistId: 'local-playlist',
    ): const PlaylistSyncResult(
      disposition: PlaylistSyncDisposition.deferred,
    ),
  },
  importedRemoteCount: 0,
  linkedLocalCount: 0,
);

PlaylistAccountSyncResult _bootstrapFailureResult() =>
    PlaylistAccountSyncResult(
      results: const <PlaylistSyncKey, PlaylistSyncResult>{},
      importedRemoteCount: 0,
      linkedLocalCount: 0,
      bootstrapError: StateError('offline'),
    );

PlaylistSyncUnresolvedConflict _unresolvedConflict({
  PlaylistSyncConflictKind kind = PlaylistSyncConflictKind.ambiguousMutation,
  String? message,
}) => PlaylistSyncUnresolvedConflict(
  key: const PlaylistSyncKey(
    accountKey: 'test-channel',
    playlistId: 'local-playlist',
  ),
  playlistTitle: 'Road trip',
  localRevision: 7,
  kind: kind,
  detectedAt: DateTime.utc(2026, 8, 22),
  message: message,
);

YouTubeMusicAccountProfile _profile() => const YouTubeMusicAccountProfile(
  channelId: 'test-channel',
  displayName: 'Test account',
);

YouTubeMusicSessionCredential _credential() => YouTubeMusicSessionCredential(
  cookieHeader: 'SAPISID=test-session-value',
  identity: const YouTubeMusicAuthIdentity(
    visitorData: 'test-visitor-data',
    authUser: '0',
  ),
  profile: _profile(),
  validatedAt: DateTime.utc(2026, 8, 22),
  apiKey: 'test_api_key',
  clientVersion: '1.20260822.00.00',
  clientName: 'WEB_REMIX',
);

YouTubeMusicWebAuthData _webAuthData() => YouTubeMusicWebAuthData(
  cookieHeader: 'SAPISID=test-session-value',
  identity: YouTubeMusicAuthIdentity(
    visitorData: 'test-visitor-data',
    authUser: '0',
  ),
  apiKey: 'test_api_key',
  clientVersion: '1.20260822.00.00',
  clientName: 'WEB_REMIX',
);
