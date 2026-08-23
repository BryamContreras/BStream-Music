part of 'music_providers.dart';

final youtubeMusicPlaylistSyncConsentStoreProvider =
    Provider<PlaylistSyncConsentStore>((ref) {
      return const SharedPreferencesPlaylistSyncConsentStore();
    });

final youtubeMusicPlaylistSyncDebounceProvider = Provider<Duration>((ref) {
  return const Duration(seconds: 2);
});

final youtubeMusicPlaylistSyncRetryBackoffProvider = Provider<List<Duration>>((
  ref,
) {
  return const <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 2),
  ];
});

final youtubeMusicPlaylistSyncRuntimeProvider =
    Provider<YouTubeMusicPlaylistSyncRuntime?>((ref) {
      final authState = ref.watch(youtubeMusicAuthControllerProvider);
      if (!authState.isAuthenticated) {
        return null;
      }
      final authController = ref.read(
        youtubeMusicAuthControllerProvider.notifier,
      );
      final credential = authController.credentialForAuthenticatedRequests;
      final accountKey = credential?.profile.accountKey.trim();
      if (credential == null || accountKey == null || accountKey.isEmpty) {
        return null;
      }

      final sessionGeneration = authState.generation;
      var active = true;
      ref.onDispose(() => active = false);
      bool sessionIsCurrent() {
        if (!active) return false;
        final current = ref.read(youtubeMusicAuthControllerProvider);
        return current.isAuthenticated &&
            current.generation == sessionGeneration &&
            current.profile?.accountKey == accountKey;
      }

      final accountGateway = ytm_account.YouTubeMusicAccountGateway(
        transport: ref.watch(youtubeMusicAccountTransportProvider),
        sessionHeaders:
            ytm_account.CredentialYouTubeMusicSessionHeadersProvider(
              readCredential: () async =>
                  sessionIsCurrent() ? credential : null,
            ),
        clientContext: ytm_account
            .buildYouTubeMusicAccountClientContextFromCredential(credential),
      );
      final playlistGateway = YouTubeMusicAccountPlaylistGateway(
        accountGateway: accountGateway,
        accountKey: accountKey,
        isSessionCurrent: sessionIsCurrent,
        onAuthenticationExpired: () {
          if (!sessionIsCurrent()) return;
          unawaited(
            ref
                .read(youtubeMusicAuthControllerProvider.notifier)
                .expireSession(),
          );
        },
      );
      final database = ref.watch(databaseServiceProvider);
      final syncStore = SqlitePlaylistSyncStore(
        database,
        conflictIdFactory: const Uuid().v4,
      );
      final engine = PlaylistSyncEngine(
        store: syncStore,
        gateway: playlistGateway,
        merger: PlaylistThreeWayMerger(itemIdFactory: const Uuid().v4),
        mutationTokenFactory: const Uuid().v4,
        clock: DateTime.now,
        canPersist: sessionIsCurrent,
      );
      final coordinator = PlaylistAccountSyncCoordinator(
        playlists: CatalogPlaylistRepositoryImpl(database),
        store: syncStore,
        engine: engine,
        catalogGateway: playlistGateway,
        localPlaylistIdFactory: const Uuid().v4,
        clock: DateTime.now,
        canPersist: sessionIsCurrent,
      );
      return YouTubeMusicPlaylistSyncRuntime(
        accountKey: accountKey,
        sessionGeneration: sessionGeneration,
        coordinator: coordinator,
        store: syncStore,
      );
    });

enum YouTubeMusicPlaylistSyncPhase { idle, syncing, synchronized, error }

enum YouTubeMusicPlaylistSyncConsentStatus {
  unavailable,
  checking,
  required,
  granted,
}

class YouTubeMusicPlaylistSyncState {
  const YouTubeMusicPlaylistSyncState({
    this.phase = YouTubeMusicPlaylistSyncPhase.idle,
    this.message,
    this.lastSyncAt,
    this.importedRemoteCount = 0,
    this.linkedLocalCount = 0,
    this.conflictCount = 0,
    this.deferredCount = 0,
    this.consentStatus = YouTubeMusicPlaylistSyncConsentStatus.unavailable,
    this.consentAccountKey,
    this.shouldPromptForConsent = false,
  });

  final YouTubeMusicPlaylistSyncPhase phase;
  final String? message;
  final DateTime? lastSyncAt;
  final int importedRemoteCount;
  final int linkedLocalCount;
  final int conflictCount;
  final int deferredCount;
  final YouTubeMusicPlaylistSyncConsentStatus consentStatus;
  final String? consentAccountKey;
  final bool shouldPromptForConsent;

  bool get isSyncing => phase == YouTubeMusicPlaylistSyncPhase.syncing;

  bool get requiresConsent =>
      consentStatus == YouTubeMusicPlaylistSyncConsentStatus.required &&
      consentAccountKey != null;
}

final youtubeMusicPlaylistSyncControllerProvider =
    NotifierProvider<
      YouTubeMusicPlaylistSyncController,
      YouTubeMusicPlaylistSyncState
    >(YouTubeMusicPlaylistSyncController.new);

class YouTubeMusicPlaylistSyncController
    extends Notifier<YouTubeMusicPlaylistSyncState> {
  Timer? _automaticTimer;
  Timer? _retryTimer;
  AppLifecycleListener? _lifecycleListener;
  Future<PlaylistAccountSyncResult?>? _inFlight;
  PlaylistSyncTrigger? _pendingTrigger;
  Completer<PlaylistAccountSyncResult?>? _pendingCompleter;
  Future<void>? _sessionInitialization;
  String? _sessionInitializationAccountKey;
  Future<PlaylistAccountSyncResult?>? _consentAcceptance;
  String? _consentAcceptanceAccountKey;
  Future<PlaylistAccountSyncResult?>? _initialSync;
  String? _initialSyncAccountKey;
  String? _consentedAccountKey;
  var _sessionEpoch = 0;
  var _retryAttempt = 0;
  var _disposed = false;

  @override
  YouTubeMusicPlaylistSyncState build() {
    ref.listen<YouTubeMusicAuthState>(youtubeMusicAuthControllerProvider, (
      previous,
      next,
    ) {
      _sessionEpoch++;
      _cancelTimers(resetRetryBudget: true);
      if (!next.isAuthenticated) {
        _consentedAccountKey = null;
        _initialSync = null;
        _initialSyncAccountKey = null;
        _sessionInitialization = null;
        _sessionInitializationAccountKey = null;
        _consentAcceptance = null;
        _consentAcceptanceAccountKey = null;
        if (previous != null) {
          state = const YouTubeMusicPlaylistSyncState();
        }
        return;
      }
      if (previous?.generation == next.generation &&
          previous?.isAuthenticated == true) {
        return;
      }
      _consentedAccountKey = null;
      _initialSync = null;
      _initialSyncAccountKey = null;
      final epoch = _sessionEpoch;
      unawaited(
        Future<void>.microtask(() async {
          await _initializeSessionConsent(epoch);
        }),
      );
    }, fireImmediately: true);
    _lifecycleListener = AppLifecycleListener(onResume: _handleAppResume);
    ref.onDispose(() {
      _disposed = true;
      _sessionEpoch++;
      _consentedAccountKey = null;
      _initialSync = null;
      _initialSyncAccountKey = null;
      _sessionInitialization = null;
      _sessionInitializationAccountKey = null;
      _consentAcceptance = null;
      _consentAcceptanceAccountKey = null;
      _cancelTimers(resetRetryBudget: true);
      _lifecycleListener?.dispose();
      _lifecycleListener = null;
      final pending = _pendingCompleter;
      if (pending != null && !pending.isCompleted) {
        pending.complete(null);
      }
    });
    return const YouTubeMusicPlaylistSyncState();
  }

  Future<PlaylistAccountSyncResult?> syncNow() async {
    _cancelTimers(resetRetryBudget: true);
    YouTubeMusicPlaylistSyncRuntime? runtime = _readRuntime();
    if (runtime == null) {
      // The account page can be opened in the same frame that auth finishes.
      // In that window the runtime provider is rebuilt asynchronously; do not
      // turn an explicit "Sync now" tap into a silent no-op.
      final initialization = _sessionInitialization;
      if (initialization != null) {
        await initialization;
        runtime = _readRuntime();
      }
    }
    if (runtime == null) return null;
    final operationEpoch = _sessionEpoch;
    final initialization = _sessionInitialization;
    if (initialization != null &&
        _sessionInitializationAccountKey == runtime.accountKey) {
      await initialization;
    }
    runtime = _readRuntime();
    if (runtime == null) return null;
    if (!_isCurrent(runtime, operationEpoch)) return null;
    if (!_hasConsent(runtime.accountKey)) {
      // Keep the manual action reliable even if the in-memory consent marker
      // was reset while restoring the account. The durable opt-in is the
      // source of truth; a failed read remains fail-closed and prompts again.
      var granted = false;
      try {
        granted = await ref
            .read(youtubeMusicPlaylistSyncConsentStoreProvider)
            .hasConsent(runtime.accountKey);
      } on Object {
        granted = false;
      }
      runtime = _readRuntime();
      if (runtime == null || !_isCurrent(runtime, operationEpoch)) return null;
      if (!granted) {
        _publishConsentState(
          status: YouTubeMusicPlaylistSyncConsentStatus.required,
          accountKey: runtime.accountKey,
          shouldPrompt: true,
        );
        return null;
      }
      _consentedAccountKey = runtime.accountKey;
      _publishConsentState(
        status: YouTubeMusicPlaylistSyncConsentStatus.granted,
        accountKey: runtime.accountKey,
        shouldPrompt: false,
      );
    }
    return _enqueue(PlaylistSyncTrigger.manual);
  }

  Future<PlaylistAccountSyncResult?> acceptConsentAndSync(String accountKey) {
    final normalizedAccountKey = accountKey.trim();
    if (normalizedAccountKey.isEmpty) {
      return Future<PlaylistAccountSyncResult?>.value(null);
    }
    final active = _consentAcceptance;
    if (active != null &&
        _consentAcceptanceAccountKey == normalizedAccountKey) {
      return active;
    }
    final operation = _acceptConsentAndSync(normalizedAccountKey);
    _consentAcceptance = operation;
    _consentAcceptanceAccountKey = normalizedAccountKey;
    unawaited(
      operation.then<void>(
        (_) => _clearConsentAcceptance(operation),
        onError: (Object _, StackTrace _) => _clearConsentAcceptance(operation),
      ),
    );
    return operation;
  }

  void _clearConsentAcceptance(Future<PlaylistAccountSyncResult?> operation) {
    if (!identical(_consentAcceptance, operation)) return;
    _consentAcceptance = null;
    _consentAcceptanceAccountKey = null;
  }

  void markConsentPromptPresented(String accountKey) {
    final normalizedAccountKey = accountKey.trim();
    if (state.consentAccountKey != normalizedAccountKey ||
        !state.requiresConsent) {
      return;
    }
    _publishConsentState(
      status: YouTubeMusicPlaylistSyncConsentStatus.required,
      accountKey: normalizedAccountKey,
      shouldPrompt: false,
    );
  }

  Future<void> _initializeSessionConsent(int epoch) async {
    if (_disposed || epoch != _sessionEpoch) return;
    final runtime = ref.read(youtubeMusicPlaylistSyncRuntimeProvider);
    if (runtime == null) return;
    final accountKey = runtime.accountKey;
    final existing = _sessionInitialization;
    if (existing != null && _sessionInitializationAccountKey == accountKey) {
      await existing;
      return;
    }

    final operation = _readConsentAndScheduleInitialSync(runtime, epoch);
    _sessionInitialization = operation;
    _sessionInitializationAccountKey = accountKey;
    try {
      await operation;
    } finally {
      if (identical(_sessionInitialization, operation)) {
        _sessionInitialization = null;
        _sessionInitializationAccountKey = null;
      }
    }
  }

  Future<void> _readConsentAndScheduleInitialSync(
    YouTubeMusicPlaylistSyncRuntime runtime,
    int epoch,
  ) async {
    _consentedAccountKey = null;
    _publishConsentState(
      status: YouTubeMusicPlaylistSyncConsentStatus.checking,
      accountKey: runtime.accountKey,
      shouldPrompt: false,
    );
    var granted = false;
    try {
      granted = await ref
          .read(youtubeMusicPlaylistSyncConsentStoreProvider)
          .hasConsent(runtime.accountKey);
    } on Object {
      granted = false;
    }
    if (!_isCurrent(runtime, epoch)) return;
    if (_hasConsent(runtime.accountKey)) {
      unawaited(_scheduleInitialSync(runtime.accountKey));
      return;
    }
    if (!granted) {
      _publishConsentState(
        status: YouTubeMusicPlaylistSyncConsentStatus.required,
        accountKey: runtime.accountKey,
        shouldPrompt: true,
      );
      return;
    }

    _consentedAccountKey = runtime.accountKey;
    _publishConsentState(
      status: YouTubeMusicPlaylistSyncConsentStatus.granted,
      accountKey: runtime.accountKey,
      shouldPrompt: false,
    );
    unawaited(_scheduleInitialSync(runtime.accountKey));
  }

  Future<PlaylistAccountSyncResult?> _acceptConsentAndSync(
    String accountKey,
  ) async {
    final runtime = ref.read(youtubeMusicPlaylistSyncRuntimeProvider);
    if (runtime == null || runtime.accountKey != accountKey) return null;
    if (_hasConsent(accountKey)) return _inFlight;
    final epoch = _sessionEpoch;
    try {
      await ref
          .read(youtubeMusicPlaylistSyncConsentStoreProvider)
          .grantConsent(accountKey);
    } on Object {
      if (_isCurrent(runtime, epoch)) {
        _publishConsentState(
          status: YouTubeMusicPlaylistSyncConsentStatus.required,
          accountKey: accountKey,
          shouldPrompt: false,
          message: ref.read(appStringsProvider).playlistSyncConsentSaveFailed,
        );
      }
      return null;
    }
    if (!_isCurrent(runtime, epoch)) return null;
    _consentedAccountKey = accountKey;
    _publishConsentState(
      status: YouTubeMusicPlaylistSyncConsentStatus.granted,
      accountKey: accountKey,
      shouldPrompt: false,
    );
    return _scheduleInitialSync(accountKey);
  }

  Future<PlaylistAccountSyncResult?> _scheduleInitialSync(String accountKey) {
    final current = _initialSync;
    if (current != null && _initialSyncAccountKey == accountKey) {
      return current;
    }
    final operation = _enqueue(PlaylistSyncTrigger.appStart);
    _initialSync = operation;
    _initialSyncAccountKey = accountKey;
    return operation;
  }

  bool _hasActiveConsent() {
    final runtime = ref.read(youtubeMusicPlaylistSyncRuntimeProvider);
    return runtime != null && _hasConsent(runtime.accountKey);
  }

  bool _hasConsent(String accountKey) =>
      _consentedAccountKey == accountKey &&
      state.consentStatus == YouTubeMusicPlaylistSyncConsentStatus.granted &&
      state.consentAccountKey == accountKey;

  void _publishConsentState({
    required YouTubeMusicPlaylistSyncConsentStatus status,
    required String accountKey,
    required bool shouldPrompt,
    String? message,
  }) {
    final current = state.consentAccountKey == accountKey
        ? state
        : const YouTubeMusicPlaylistSyncState();
    state = YouTubeMusicPlaylistSyncState(
      phase: current.phase,
      message: message ?? current.message,
      lastSyncAt: current.lastSyncAt,
      importedRemoteCount: current.importedRemoteCount,
      linkedLocalCount: current.linkedLocalCount,
      conflictCount: current.conflictCount,
      deferredCount: current.deferredCount,
      consentStatus: status,
      consentAccountKey: accountKey,
      shouldPromptForConsent: shouldPrompt,
    );
  }

  void requestAutomaticSync() {
    if (_disposed ||
        !ref.read(youtubeMusicAuthControllerProvider).isAuthenticated ||
        !_hasActiveConsent()) {
      return;
    }
    _cancelTimers(resetRetryBudget: true);
    _automaticTimer = Timer(
      ref.read(youtubeMusicPlaylistSyncDebounceProvider),
      () {
        _automaticTimer = null;
        unawaited(_enqueue(PlaylistSyncTrigger.localMutation));
      },
    );
  }

  Future<List<PlaylistSyncUnresolvedConflict>> unresolvedConflicts() async {
    final runtime = ref.read(youtubeMusicPlaylistSyncRuntimeProvider);
    final store = runtime?.store;
    if (runtime == null || store == null) {
      return const <PlaylistSyncUnresolvedConflict>[];
    }
    final operationEpoch = _sessionEpoch;
    final conflicts = await store.listUnresolvedConflicts(
      accountKey: runtime.accountKey,
    );
    return _isCurrent(runtime, operationEpoch)
        ? conflicts
        : const <PlaylistSyncUnresolvedConflict>[];
  }

  Future<bool> resolveConflict(
    PlaylistSyncUnresolvedConflict conflict,
    PlaylistSyncConflictResolution resolution,
  ) async {
    final runtime = ref.read(youtubeMusicPlaylistSyncRuntimeProvider);
    final store = runtime?.store;
    if (runtime == null ||
        store == null ||
        conflict.key.accountKey != runtime.accountKey) {
      return false;
    }
    final operationEpoch = _sessionEpoch;
    await store.resolveConflict(
      key: conflict.key,
      resolution: resolution,
      expectedLocalRevision: conflict.localRevision,
      now: DateTime.now(),
    );
    if (!_isCurrent(runtime, operationEpoch)) return false;
    await _enqueue(PlaylistSyncTrigger.manual);
    if (!_isCurrent(runtime, operationEpoch)) return false;
    final remaining = await store.listUnresolvedConflicts(
      accountKey: runtime.accountKey,
    );
    if (!_isCurrent(runtime, operationEpoch)) return false;
    return !remaining.any((item) => item.key == conflict.key);
  }

  void _handleAppResume() {
    if (_disposed ||
        !ref.read(youtubeMusicAuthControllerProvider).isAuthenticated ||
        !_hasActiveConsent()) {
      return;
    }
    _cancelTimers(resetRetryBudget: true);
    unawaited(_enqueue(PlaylistSyncTrigger.automatic));
  }

  Future<PlaylistAccountSyncResult?> _enqueue(PlaylistSyncTrigger trigger) {
    if (_disposed || !_hasActiveConsent()) {
      return Future<PlaylistAccountSyncResult?>.value(null);
    }
    final active = _inFlight;
    if (active == null) {
      return _start(trigger);
    }
    _pendingTrigger = _strongerTrigger(_pendingTrigger, trigger);
    return (_pendingCompleter ??= Completer<PlaylistAccountSyncResult?>())
        .future;
  }

  Future<PlaylistAccountSyncResult?> _start(PlaylistSyncTrigger trigger) {
    final operation = _perform(trigger);
    _inFlight = operation;
    unawaited(
      operation.then<void>(
        (_) => _finish(operation),
        onError: (Object _, StackTrace _) => _finish(operation),
      ),
    );
    return operation;
  }

  void _finish(Future<PlaylistAccountSyncResult?> operation) {
    if (!identical(_inFlight, operation)) return;
    _inFlight = null;
    final nextTrigger = _pendingTrigger;
    final pending = _pendingCompleter;
    _pendingTrigger = null;
    _pendingCompleter = null;
    if (_disposed || nextTrigger == null) {
      if (pending != null && !pending.isCompleted) pending.complete(null);
      return;
    }
    final next = _start(nextTrigger);
    if (pending != null) {
      unawaited(
        next.then<void>(pending.complete, onError: pending.completeError),
      );
    }
  }

  Future<PlaylistAccountSyncResult?> _perform(
    PlaylistSyncTrigger trigger,
  ) async {
    final runtime = ref.read(youtubeMusicPlaylistSyncRuntimeProvider);
    if (runtime == null || !_hasConsent(runtime.accountKey)) {
      return null;
    }
    final operationEpoch = _sessionEpoch;
    final strings = ref.read(appStringsProvider);
    state = YouTubeMusicPlaylistSyncState(
      phase: YouTubeMusicPlaylistSyncPhase.syncing,
      message: strings.syncingPlaylists,
      lastSyncAt: state.lastSyncAt,
      consentStatus: state.consentStatus,
      consentAccountKey: state.consentAccountKey,
      shouldPromptForConsent: state.shouldPromptForConsent,
    );
    try {
      final result = await runtime.coordinator.syncAll(
        runtime.accountKey,
        trigger: trigger,
        newBindingMode: PlaylistSyncMode.automatic,
      );
      if (!_isCurrent(runtime, operationEpoch)) return result;

      await ref
          .read(playlistsControllerProvider.notifier)
          .reloadFromRepository();
      if (!_isCurrent(runtime, operationEpoch)) return result;

      final values = result.results.values;
      final conflictCount = values
          .where(
            (value) =>
                value.disposition == PlaylistSyncDisposition.conflict ||
                value.disposition == PlaylistSyncDisposition.remoteDeleted,
          )
          .length;
      final deferredCount = values
          .where(
            (value) => value.disposition == PlaylistSyncDisposition.deferred,
          )
          .length;
      final bootstrapFailed = result.bootstrapError != null;
      if (bootstrapFailed || deferredCount > 0) {
        _scheduleRetry();
      } else {
        _retryTimer?.cancel();
        _retryTimer = null;
        _retryAttempt = 0;
      }
      final message = bootstrapFailed
          ? strings.choose(
              'La sincronización terminó parcialmente; YouTube Music no '
                  'devolvió toda la biblioteca.',
              'Sync finished partially; YouTube Music did not return the '
                  'entire library.',
            )
          : conflictCount > 0
          ? strings.choose(
              'Sincronización completada con $conflictCount conflicto(s) '
                  'pendiente(s).',
              'Sync completed with $conflictCount unresolved conflict(s).',
            )
          : result.importedRemoteCount > 0
          ? strings.playlistsImported(result.importedRemoteCount)
          : strings.playlistsSynchronized;
      state = YouTubeMusicPlaylistSyncState(
        phase: bootstrapFailed && result.results.isEmpty
            ? YouTubeMusicPlaylistSyncPhase.error
            : YouTubeMusicPlaylistSyncPhase.synchronized,
        message: message,
        lastSyncAt: DateTime.now(),
        importedRemoteCount: result.importedRemoteCount,
        linkedLocalCount: result.linkedLocalCount,
        conflictCount: conflictCount,
        deferredCount: deferredCount,
        consentStatus: state.consentStatus,
        consentAccountKey: state.consentAccountKey,
        shouldPromptForConsent: state.shouldPromptForConsent,
      );
      return result;
    } on Object catch (error, stackTrace) {
      // Keep the user-facing message intentionally generic, but retain a
      // diagnostic breadcrumb in debug builds.  Never print the exception
      // itself: transport/auth errors can contain request URLs or headers.
      if (kDebugMode) {
        debugPrint(
          'YouTube Music playlist sync failed (${error.runtimeType}).',
        );
        debugPrintStack(stackTrace: stackTrace);
      }
      if (_isCurrent(runtime, operationEpoch)) {
        _scheduleRetry();
        state = YouTubeMusicPlaylistSyncState(
          phase: YouTubeMusicPlaylistSyncPhase.error,
          message: strings.choose(
            'No se pudieron sincronizar las playlists. Tus datos locales se '
                'conservaron sin cambios destructivos.',
            'Playlists could not be synchronized. Your local data was kept '
                'without destructive changes.',
          ),
          lastSyncAt: state.lastSyncAt,
          consentStatus: state.consentStatus,
          consentAccountKey: state.consentAccountKey,
          shouldPromptForConsent: state.shouldPromptForConsent,
        );
      }
      return null;
    }
  }

  YouTubeMusicPlaylistSyncRuntime? _readRuntime() =>
      ref.read(youtubeMusicPlaylistSyncRuntimeProvider);

  bool _isCurrent(YouTubeMusicPlaylistSyncRuntime runtime, int epoch) {
    if (_disposed || epoch != _sessionEpoch) return false;
    final current = ref.read(youtubeMusicPlaylistSyncRuntimeProvider);
    return current != null &&
        current.accountKey == runtime.accountKey &&
        current.sessionGeneration == runtime.sessionGeneration;
  }

  void _scheduleRetry() {
    if (_disposed || _pendingTrigger != null) return;
    final backoff = ref.read(youtubeMusicPlaylistSyncRetryBackoffProvider);
    if (_retryAttempt >= backoff.length) return;
    final delay = backoff[_retryAttempt++];
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_disposed ||
          !ref.read(youtubeMusicAuthControllerProvider).isAuthenticated ||
          !_hasActiveConsent()) {
        return;
      }
      unawaited(_enqueue(PlaylistSyncTrigger.automatic));
    });
  }

  void _cancelTimers({required bool resetRetryBudget}) {
    _automaticTimer?.cancel();
    _automaticTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    if (resetRetryBudget) {
      _retryAttempt = 0;
    }
  }
}

class YouTubeMusicPlaylistSyncRuntime {
  const YouTubeMusicPlaylistSyncRuntime({
    required this.accountKey,
    required this.sessionGeneration,
    required this.coordinator,
    this.store,
  });

  final String accountKey;
  final int sessionGeneration;
  final PlaylistAccountSyncCoordinator coordinator;
  final PlaylistSyncStore? store;
}

PlaylistSyncTrigger _strongerTrigger(
  PlaylistSyncTrigger? current,
  PlaylistSyncTrigger incoming,
) {
  if (current == null) return incoming;
  int rank(PlaylistSyncTrigger value) => switch (value) {
    PlaylistSyncTrigger.manual => 3,
    PlaylistSyncTrigger.localMutation => 2,
    PlaylistSyncTrigger.automatic => 1,
    PlaylistSyncTrigger.appStart => 0,
  };
  return rank(incoming) > rank(current) ? incoming : current;
}
