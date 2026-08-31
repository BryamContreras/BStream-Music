part of 'music_providers.dart';

final tiktokLiveControllerProvider =
    AsyncNotifierProvider<TikTokLiveController, TikTokLiveState>(
      TikTokLiveController.new,
    );

enum LiveQueueItemStatus { resolving, downloading, ready, failed }

enum TikTokLiveCommand {
  play,
  skip,
  revoke,
  stop;

  static TikTokLiveCommand? fromAction(String action) {
    final normalized = action.trim().toLowerCase();
    for (final command in values) {
      if (command.name == normalized) {
        return command;
      }
    }
    return null;
  }
}

enum TikTokCommandAudience { everyone, moderators, subscribers }

const Set<TikTokLiveCommand> allTikTokLiveCommands = {
  TikTokLiveCommand.play,
  TikTokLiveCommand.skip,
  TikTokLiveCommand.revoke,
  TikTokLiveCommand.stop,
};

const defaultTikTokCommandPermissions = TikTokCommandPermissions(
  everyone: allTikTokLiveCommands,
);

class TikTokCommandPermissions {
  const TikTokCommandPermissions({
    this.everyone = const <TikTokLiveCommand>{},
    this.moderators = const <TikTokLiveCommand>{},
    this.subscribers = const <TikTokLiveCommand>{},
  });

  final Set<TikTokLiveCommand> everyone;
  final Set<TikTokLiveCommand> moderators;
  final Set<TikTokLiveCommand> subscribers;

  Set<TikTokLiveCommand> forAudience(TikTokCommandAudience audience) {
    return switch (audience) {
      TikTokCommandAudience.everyone => everyone,
      TikTokCommandAudience.moderators => moderators,
      TikTokCommandAudience.subscribers => subscribers,
    };
  }

  bool isExplicitlyEnabled(
    TikTokCommandAudience audience,
    TikTokLiveCommand command,
  ) {
    return forAudience(audience).contains(command);
  }

  bool allows(TikTokLiveChatCommand command) {
    final liveCommand = TikTokLiveCommand.fromAction(command.action);
    if (liveCommand == null) {
      return false;
    }
    return everyone.contains(liveCommand) ||
        (command.isModerator && moderators.contains(liveCommand)) ||
        (command.isSubscriber && subscribers.contains(liveCommand));
  }

  TikTokCommandPermissions withCommand(
    TikTokCommandAudience audience,
    TikTokLiveCommand command,
    bool enabled,
  ) {
    final updated = <TikTokLiveCommand>{...forAudience(audience)};
    if (enabled) {
      updated.add(command);
    } else {
      updated.remove(command);
    }
    final immutable = Set<TikTokLiveCommand>.unmodifiable(updated);
    return switch (audience) {
      TikTokCommandAudience.everyone => TikTokCommandPermissions(
        everyone: immutable,
        moderators: moderators,
        subscribers: subscribers,
      ),
      TikTokCommandAudience.moderators => TikTokCommandPermissions(
        everyone: everyone,
        moderators: immutable,
        subscribers: subscribers,
      ),
      TikTokCommandAudience.subscribers => TikTokCommandPermissions(
        everyone: everyone,
        moderators: moderators,
        subscribers: immutable,
      ),
    };
  }

  Map<String, Object> toJson() {
    List<String> encode(Set<TikTokLiveCommand> commands) => [
      for (final command in TikTokLiveCommand.values)
        if (commands.contains(command)) command.name,
    ];

    return {
      'version': 3,
      'everyone': encode(everyone),
      'moderators': encode(moderators),
      'subscribers': encode(subscribers),
    };
  }

  static TikTokCommandPermissions? tryFromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final version = value['version'];
    if (version != 2 && version != 3) {
      return null;
    }

    Set<TikTokLiveCommand>? decode(String key) {
      final encoded = value[key];
      if (encoded is! List) {
        return null;
      }
      final commands = <TikTokLiveCommand>{
        ...encoded
            .map((entry) => TikTokLiveCommand.fromAction(entry.toString()))
            .whereType<TikTokLiveCommand>(),
      };
      // Until v2, !stop was an alias of !revoke. Copy that permission only
      // while migrating so v3 can persist both choices independently.
      if (version == 2 && commands.contains(TikTokLiveCommand.revoke)) {
        commands.add(TikTokLiveCommand.stop);
      }
      return Set<TikTokLiveCommand>.unmodifiable(commands);
    }

    final everyone = decode('everyone');
    final moderators = decode('moderators');
    final subscribers = decode('subscribers');
    if (everyone == null || moderators == null || subscribers == null) {
      return null;
    }
    return TikTokCommandPermissions(
      everyone: everyone,
      moderators: moderators,
      subscribers: subscribers,
    );
  }
}

TikTokCommandPermissions _migrateCommandPermissions(String? legacyAccess) {
  if (legacyAccess == 'moderators') {
    return const TikTokCommandPermissions(moderators: allTikTokLiveCommands);
  }
  return defaultTikTokCommandPermissions;
}

class _LiveQueueOperationCancelled implements Exception {
  const _LiveQueueOperationCancelled();
}

class _ScheduledLiveQueueItem {
  _ScheduledLiveQueueItem({
    required this.sequence,
    required this.generation,
    required this.item,
  });

  final int sequence;
  final int generation;
  final LiveQueueItem item;
  bool searchDeadlineExceeded = false;
}

class _LiveQueueResolution {
  const _LiveQueueResolution.success({
    required this.scheduled,
    required this.remoteTrack,
    this.localTrack,
    this.reusedExisting = false,
  }) : errorMessage = null;

  const _LiveQueueResolution.failure({
    required this.scheduled,
    required this.errorMessage,
  }) : remoteTrack = null,
       localTrack = null,
       reusedExisting = false;

  final _ScheduledLiveQueueItem scheduled;
  final TrackInfo? remoteTrack;
  final LocalTrack? localTrack;
  final bool reusedExisting;
  final String? errorMessage;

  bool get isSuccess => remoteTrack != null && errorMessage == null;
}

bool canUseTikTokCommand(
  TikTokCommandPermissions permissions,
  TikTokLiveChatCommand command,
) {
  return permissions.allows(command);
}

class LiveQueueItem {
  const LiveQueueItem({
    required this.id,
    required this.requestedBy,
    required this.query,
    required this.commandText,
    required this.requestedAt,
    required this.status,
    this.requestedByModerator = false,
    this.message,
    this.remoteTrack,
    this.localTrack,
    this.reusedExisting = false,
    this.saveToLibrary = false,
  });

  factory LiveQueueItem.fromCommand(
    TikTokLiveChatCommand command, {
    required bool saveToLibrary,
  }) {
    return LiveQueueItem(
      id: const Uuid().v4(),
      requestedBy: command.user,
      query: command.query?.trim() ?? '',
      commandText: command.text,
      requestedAt: DateTime.now(),
      status: LiveQueueItemStatus.resolving,
      requestedByModerator: command.isModerator,
      message: 'Buscando...',
      saveToLibrary: saveToLibrary,
    );
  }

  final String id;
  final String requestedBy;
  final String query;
  final String commandText;
  final DateTime requestedAt;
  final LiveQueueItemStatus status;
  final bool requestedByModerator;
  final String? message;
  final TrackInfo? remoteTrack;
  final LocalTrack? localTrack;
  final bool reusedExisting;
  final bool saveToLibrary;

  bool get isPending =>
      status == LiveQueueItemStatus.resolving ||
      status == LiveQueueItemStatus.downloading;

  bool get isReady =>
      status == LiveQueueItemStatus.ready &&
      (localTrack != null || remoteTrack != null);

  String get displayTitle =>
      localTrack?.title ??
      remoteTrack?.title ??
      (query.isEmpty ? commandText : query);

  String get displaySubtitle {
    final local = localTrack;
    if (local != null) {
      return local.artist;
    }
    final remote = remoteTrack;
    if (remote != null) {
      return remote.artist;
    }
    return requestedBy;
  }

  LiveQueueItem copyWith({
    LiveQueueItemStatus? status,
    String? message,
    TrackInfo? remoteTrack,
    LocalTrack? localTrack,
    bool? reusedExisting,
  }) {
    return LiveQueueItem(
      id: id,
      requestedBy: requestedBy,
      query: query,
      commandText: commandText,
      requestedAt: requestedAt,
      status: status ?? this.status,
      requestedByModerator: requestedByModerator,
      message: message ?? this.message,
      remoteTrack: remoteTrack ?? this.remoteTrack,
      localTrack: localTrack ?? this.localTrack,
      reusedExisting: reusedExisting ?? this.reusedExisting,
      saveToLibrary: saveToLibrary,
    );
  }
}

class TikTokLiveState {
  const TikTokLiveState({
    required this.creatorInput,
    required this.status,
    required this.message,
    this.normalizedCreator,
    this.roomId,
    this.lastCommand,
    this.commandPermissions = defaultTikTokCommandPermissions,
    this.saveRequestsToLibrary = false,
    this.commandsHandled = 0,
    this.liveQueue = const [],
  });

  final String creatorInput;
  final TikTokLiveStatus status;
  final String message;
  final String? normalizedCreator;
  final String? roomId;
  final TikTokLiveChatCommand? lastCommand;
  final TikTokCommandPermissions commandPermissions;
  final bool saveRequestsToLibrary;
  final int commandsHandled;
  final List<LiveQueueItem> liveQueue;

  bool get isConnected => status == TikTokLiveStatus.connected;
  bool get isBusy => status == TikTokLiveStatus.connecting;
  int get pendingPlayCommands =>
      liveQueue.where((item) => item.isPending).length;
  int get readyPlayCommands => liveQueue.where((item) => item.isReady).length;
  List<LocalTrack> get readyTracks {
    final seen = <String>{};
    return [
      for (final item in liveQueue)
        if (item.isReady)
          if (item.localTrack case final track?)
            if (seen.add(track.id)) track,
    ];
  }

  List<TrackInfo> get readyRemoteTracks {
    final seen = <String>{};
    return [
      for (final item in liveQueue)
        if (item.isReady && !item.saveToLibrary)
          if (item.remoteTrack case final track?)
            if (seen.add(track.id.trim().isEmpty ? track.url : track.id)) track,
    ];
  }

  TikTokLiveState copyWith({
    String? creatorInput,
    TikTokLiveStatus? status,
    String? message,
    String? normalizedCreator,
    String? roomId,
    TikTokLiveChatCommand? lastCommand,
    TikTokCommandPermissions? commandPermissions,
    bool? saveRequestsToLibrary,
    int? commandsHandled,
    List<LiveQueueItem>? liveQueue,
  }) {
    return TikTokLiveState(
      creatorInput: creatorInput ?? this.creatorInput,
      status: status ?? this.status,
      message: message ?? this.message,
      normalizedCreator: normalizedCreator ?? this.normalizedCreator,
      roomId: roomId ?? this.roomId,
      lastCommand: lastCommand ?? this.lastCommand,
      commandPermissions: commandPermissions ?? this.commandPermissions,
      saveRequestsToLibrary:
          saveRequestsToLibrary ?? this.saveRequestsToLibrary,
      commandsHandled: commandsHandled ?? this.commandsHandled,
      liveQueue: liveQueue ?? this.liveQueue,
    );
  }
}

class TikTokLiveController extends AsyncNotifier<TikTokLiveState> {
  TikTokLiveController({this.searchDeadline = const Duration(seconds: 30)})
    : assert(searchDeadline > Duration.zero);

  /// Bounds both the visible LIVE queue and its pending resolution backlog.
  ///
  /// Keeping the value public makes the product limit explicit to UI and
  /// regression tests instead of relying on an unbounded in-memory queue.
  static const int maxQueueItems = 50;

  /// Search/download work may overlap, but completed requests are still
  /// published to the player in the exact order in which chat accepted them.
  static const int maxConcurrentResolutions = 3;

  /// A timed-out search is published as failed so it cannot block FIFO commits
  /// forever. Its underlying non-cancellable operation keeps occupying its
  /// worker slot until it really settles, preventing runaway processes.
  /// Downloads begin only after search settles and are not subject to this
  /// deadline.
  final Duration searchDeadline;

  static const _creatorInputKey = 'tiktokLive.creatorInput';
  static const _commandAccessKey = 'tiktokLive.commandAccess';
  static const _commandPermissionsKey = 'tiktokLive.commandPermissions.v3';
  static const _legacyCommandPermissionsKey =
      'tiktokLive.commandPermissions.v2';
  static const _saveRequestsToLibraryKey = 'tiktokLive.saveRequestsToLibrary';

  final _pendingMusicQueue = Queue<_ScheduledLiveQueueItem>();
  final _completedMusicResolutions = <int, _LiveQueueResolution>{};
  final _committingMusicQueueGenerations = <int>{};
  final _scheduledMusicItems = <String, _ScheduledLiveQueueItem>{};
  final _cancelledMusicSequences = <int>{};
  int _activeMusicResolutions = 0;
  int _nextMusicSequence = 0;
  int _nextMusicSequenceToCommit = 0;
  bool _liveQueueActivated = false;
  int _liveQueueGeneration = 0;
  Future<void> _immediateCommandTail = Future<void>.value();
  Future<void> _liveQueueSyncTail = Future<void>.value();
  LiveQueueItem? _revokedPlayingItem;
  int _revokedPlayingReadyIndex = -1;

  @override
  Future<TikTokLiveState> build() async {
    final service = ref.watch(tiktokLiveCommandServiceProvider);
    final subscription = service.events.listen(_handleBridgeEvent);
    ref.onDispose(() {
      _cancelMusicQueueOperations();
      unawaited(subscription.cancel());
    });
    ref.listen<AsyncValue<PlayerSnapshot>>(playerControllerProvider, (_, next) {
      _handlePlaybackSnapshotForRevokedItem(next.value);
    });

    final prefs = await SharedPreferences.getInstance();
    final creatorInput = prefs.getString(_creatorInputKey) ?? '';
    TikTokCommandPermissions? decodePermissions(String? encoded) {
      if (encoded == null) {
        return null;
      }
      try {
        return TikTokCommandPermissions.tryFromJson(jsonDecode(encoded));
      } on FormatException {
        return null;
      }
    }

    final storedPermissions = decodePermissions(
      prefs.getString(_commandPermissionsKey),
    );
    final restoredStoredPermissions = storedPermissions != null;
    var commandPermissions =
        storedPermissions ??
        decodePermissions(prefs.getString(_legacyCommandPermissionsKey));
    commandPermissions ??= _migrateCommandPermissions(
      prefs.getString(_commandAccessKey),
    );
    if (!restoredStoredPermissions) {
      await prefs.setString(
        _commandPermissionsKey,
        jsonEncode(commandPermissions.toJson()),
      );
    }
    final saveRequestsToLibrary =
        prefs.getBool(_saveRequestsToLibraryKey) ?? false;
    return TikTokLiveState(
      creatorInput: creatorInput,
      normalizedCreator: normalizeCreatorInput(creatorInput),
      status: TikTokLiveStatus.idle,
      commandPermissions: commandPermissions,
      saveRequestsToLibrary: saveRequestsToLibrary,
      message: creatorInput.trim().isEmpty
          ? 'Ingresa un usuario o link de TikTok LIVE.'
          : 'Listo para conectar.',
    );
  }

  Future<void> setCreatorInput(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_creatorInputKey, value.trim());
    final current = await future;
    state = AsyncData(
      current.copyWith(
        creatorInput: value.trim(),
        normalizedCreator: normalizeCreatorInput(value),
      ),
    );
  }

  Future<void> setCommandPermission(
    TikTokCommandAudience audience,
    TikTokLiveCommand command,
    bool enabled,
  ) async {
    final current = state.value ?? await future;
    if (current.commandPermissions.isExplicitlyEnabled(audience, command) ==
        enabled) {
      return;
    }
    final commandPermissions = current.commandPermissions.withCommand(
      audience,
      command,
      enabled,
    );
    state = AsyncData(current.copyWith(commandPermissions: commandPermissions));
    final prefs = await SharedPreferences.getInstance();
    final latestPermissions =
        state.value?.commandPermissions ?? commandPermissions;
    await prefs.setString(
      _commandPermissionsKey,
      jsonEncode(latestPermissions.toJson()),
    );
  }

  Future<void> setSaveRequestsToLibrary(bool value) async {
    final current = state.value ?? await future;
    if (current.saveRequestsToLibrary == value) {
      return;
    }
    if (current.liveQueue.isNotEmpty || _revokedPlayingItem != null) {
      state = AsyncData(
        current.copyWith(
          message: 'Limpia la cola LIVE antes de cambiar el modo.',
        ),
      );
      return;
    }

    state = AsyncData(current.copyWith(saveRequestsToLibrary: value));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_saveRequestsToLibraryKey, value);
  }

  Future<void> connect([String? value]) async {
    final current = await future;
    final input = (value ?? current.creatorInput).trim();
    await setCreatorInput(input);
    final normalized = normalizeCreatorInput(input);
    if (normalized.isEmpty) {
      state = AsyncData(
        current.copyWith(
          creatorInput: input,
          status: TikTokLiveStatus.error,
          message: 'Ingresa @usuario o el link del live.',
        ),
      );
      return;
    }

    state = AsyncData(
      current.copyWith(
        creatorInput: input,
        normalizedCreator: normalized,
        status: TikTokLiveStatus.connecting,
        message: 'Conectando a @$normalized...',
      ),
    );

    try {
      await ref.read(tiktokLiveCommandServiceProvider).connect(normalized);
    } catch (error) {
      final latest = await future;
      state = AsyncData(
        latest.copyWith(
          status: TikTokLiveStatus.error,
          message: error.toString(),
        ),
      );
    }
  }

  Future<void> disconnect() async {
    _cancelMusicQueueOperations();
    _liveQueueActivated = false;
    await ref.read(tiktokLiveCommandServiceProvider).disconnect();
    final current = await future;
    final player = ref.read(playerControllerProvider.notifier);
    if (player.isLiveQueueActive) {
      await player.clearQueueSource(PlayerController.liveQueueSourceId);
      await player.stop();
    }
    state = AsyncData(
      current.copyWith(
        status: TikTokLiveStatus.disconnected,
        message: 'Desconectado.',
        liveQueue: const [],
      ),
    );
  }

  Future<void> clearLiveQueue({bool stopPlayback = true}) async {
    final player = ref.read(playerControllerProvider.notifier);
    final liveWasActive = player.isLiveQueueActive;
    _cancelMusicQueueOperations();
    _liveQueueActivated = false;
    final current = await future;
    state = AsyncData(
      current.copyWith(liveQueue: const [], message: 'Cola LIVE limpia.'),
    );
    if (liveWasActive) {
      await player.clearQueueSource(PlayerController.liveQueueSourceId);
      if (stopPlayback) {
        await player.stop();
      }
    }
  }

  Future<void> revokeLastLiveQueueItem() async {
    final current = await future;
    if (current.liveQueue.isEmpty) {
      _setMessage('No hay pedidos en la cola LIVE para retirar.');
      return;
    }

    final removed = current.liveQueue.last;
    final remaining = List<LiveQueueItem>.unmodifiable(
      current.liveQueue.take(current.liveQueue.length - 1),
    );
    final player = ref.read(playerControllerProvider.notifier);
    final playback = ref.read(playerControllerProvider).value;
    final removesPlayingItem =
        removed.isReady &&
        player.isLiveQueueActive &&
        _snapshotMatchesLiveQueueItem(playback, removed);

    if (removesPlayingItem) {
      _revokedPlayingItem = removed;
      _revokedPlayingReadyIndex = removed.saveToLibrary
          ? remaining.where((item) => item.localTrack != null).length
          : remaining.where((item) => item.remoteTrack != null).length;
    }
    _cancelScheduledLiveQueueItem(removed.id);
    state = AsyncData(current.copyWith(liveQueue: remaining));

    if (removed.isReady && player.isLiveQueueActive) {
      await _syncLiveQueuePlaybackInOrder(saveToLibrary: removed.saveToLibrary);
    }
    _setMessage('Último pedido retirado: ${removed.query}');
  }

  Future<void> playLiveQueueItem(String itemId) async {
    final current = await future;
    final item = current.liveQueue
        .where((entry) => entry.id == itemId && entry.isReady)
        .firstOrNull;
    if (item == null) {
      return;
    }

    _clearRevokedPlayingItem();
    _liveQueueActivated = true;
    final player = ref.read(playerControllerProvider.notifier);
    if (item.saveToLibrary) {
      final track = item.localTrack;
      final readyTracks = current.readyTracks;
      if (track == null || readyTracks.isEmpty) {
        return;
      }
      await player.playLocal(
        track,
        queue: readyTracks,
        useNativeQueue: false,
        queueSourceId: PlayerController.liveQueueSourceId,
      );
      _setMessage('Reproduciendo cola LIVE: ${track.title}');
      return;
    }

    final track = item.remoteTrack;
    final readyTracks = current.readyRemoteTracks;
    if (track == null || readyTracks.isEmpty) {
      return;
    }
    await player.playRemote(
      track,
      queue: readyTracks,
      queueSourceId: PlayerController.liveQueueSourceId,
    );
    _setMessage('Reproduciendo cola LIVE: ${track.title}');
  }

  void _handleBridgeEvent(TikTokLiveEvent event) {
    final current = state.value;
    if (current == null) {
      return;
    }

    final nextStatus = event.status ?? current.status;
    state = AsyncData(
      current.copyWith(
        status: nextStatus,
        normalizedCreator: event.user ?? current.normalizedCreator,
        roomId: event.roomId ?? current.roomId,
        message: event.message ?? current.message,
      ),
    );

    final command = event.command;
    if (command != null) {
      _enqueueCommand(command);
    }
  }

  void _enqueueCommand(TikTokLiveChatCommand command) {
    final current = state.value;
    if (current == null) {
      return;
    }

    if (!canUseTikTokCommand(current.commandPermissions, command)) {
      state = AsyncData(
        current.copyWith(
          lastCommand: command,
          message: 'Comando no permitido para ${command.user}: ${command.text}',
        ),
      );
      return;
    }

    if (command.action == 'play' && current.liveQueue.length >= maxQueueItems) {
      state = AsyncData(
        current.copyWith(
          lastCommand: command,
          message:
              'Cola LIVE llena (máximo $maxQueueItems). Límpiala antes de agregar más pedidos.',
        ),
      );
      return;
    }

    final liveItem = command.action == 'play'
        ? LiveQueueItem.fromCommand(
            command,
            saveToLibrary: current.saveRequestsToLibrary,
          )
        : null;
    state = AsyncData(
      current.copyWith(
        lastCommand: command,
        commandsHandled: current.commandsHandled + 1,
        liveQueue: liveItem == null
            ? current.liveQueue
            : [...current.liveQueue, liveItem],
        message: _commandMessage(command),
      ),
    );

    if (liveItem != null) {
      final scheduled = _ScheduledLiveQueueItem(
        sequence: _nextMusicSequence++,
        generation: _liveQueueGeneration,
        item: liveItem,
      );
      _scheduledMusicItems[liveItem.id] = scheduled;
      _pendingMusicQueue.add(scheduled);
      _pumpMusicQueue();
      return;
    }

    final operation = _immediateCommandTail.then(
      (_) => _handleImmediateCommand(command),
    );
    _immediateCommandTail = operation;
    unawaited(operation);
  }

  String _commandMessage(TikTokLiveChatCommand command) {
    return switch (command.action) {
      'play' => '${command.user}: !play ${command.query ?? ''}',
      'skip' => '${command.user}: !skip',
      'revoke' => '${command.user}: ${command.text}',
      'stop' => '${command.user}: !stop',
      _ => '${command.user}: ${command.text}',
    };
  }

  Future<void> _handleImmediateCommand(TikTokLiveChatCommand command) async {
    try {
      switch (command.action) {
        case 'skip':
          if (ref.read(playerControllerProvider.notifier).isLiveQueueActive) {
            await ref.read(playerControllerProvider.notifier).playNext();
          }
        case 'revoke':
          await revokeLastLiveQueueItem();
        case 'stop':
          final player = ref.read(playerControllerProvider.notifier);
          if (!player.isLiveQueueActive) {
            _setMessage('No hay una canción LIVE reproduciéndose.');
            return;
          }
          await player.pause();
          _setMessage('Reproducción LIVE pausada.');
      }
    } catch (error) {
      _setMessage('No se pudo ejecutar ${command.text}: $error');
    }
  }

  void _pumpMusicQueue() {
    while (_activeMusicResolutions < maxConcurrentResolutions &&
        _pendingMusicQueue.isNotEmpty) {
      final scheduled = _pendingMusicQueue.removeFirst();
      _activeMusicResolutions++;
      unawaited(_runMusicResolution(scheduled));
    }
  }

  void _cancelScheduledLiveQueueItem(String itemId) {
    final scheduled = _scheduledMusicItems.remove(itemId);
    if (scheduled == null || scheduled.generation != _liveQueueGeneration) {
      return;
    }
    _pendingMusicQueue.remove(scheduled);
    _completedMusicResolutions.remove(scheduled.sequence);
    _cancelledMusicSequences.add(scheduled.sequence);
    _scheduleMusicQueueCommit(scheduled.generation);
    _pumpMusicQueue();
  }

  Future<void> _runMusicResolution(_ScheduledLiveQueueItem scheduled) async {
    final deadline = Completer<_LiveQueueResolution>();
    Timer? deadlineTimer;
    final operation = _resolvePlayCommand(
      scheduled,
      onSearchStarted: () {
        deadlineTimer = Timer(searchDeadline, () {
          scheduled.searchDeadlineExceeded = true;
          if (!deadline.isCompleted) {
            deadline.complete(
              _LiveQueueResolution.failure(
                scheduled: scheduled,
                errorMessage:
                    'La búsqueda excedió ${searchDeadline.inSeconds} segundos.',
              ),
            );
          }
        });
      },
      onSearchSettled: () => deadlineTimer?.cancel(),
    );

    try {
      final resolution = await Future.any([operation, deadline.future]);
      if (_isLiveQueueOperationCurrent(
        scheduled.item.id,
        scheduled.generation,
      )) {
        _completedMusicResolutions[scheduled.sequence] = resolution;
        _scheduleMusicQueueCommit(scheduled.generation);
      }

      if (scheduled.searchDeadlineExceeded) {
        // Search APIs are not cancellable on every platform. Keep the
        // slot occupied until the real search Future settles, but ignore its
        // late result. Download never starts after this deadline.
        await operation;
      }
    } finally {
      deadlineTimer?.cancel();
      _activeMusicResolutions--;
      _pumpMusicQueue();
    }
  }

  Future<_LiveQueueResolution> _resolvePlayCommand(
    _ScheduledLiveQueueItem scheduled, {
    required void Function() onSearchStarted,
    required void Function() onSearchSettled,
  }) async {
    final item = scheduled.item;
    final query = item.query.trim();
    if (query.isEmpty) {
      return _LiveQueueResolution.failure(
        scheduled: scheduled,
        errorMessage: 'El pedido no contiene una búsqueda.',
      );
    }
    if (!_isLiveQueueResolutionActive(scheduled)) {
      return _LiveQueueResolution.failure(
        scheduled: scheduled,
        errorMessage: 'Pedido cancelado.',
      );
    }

    try {
      _updateLiveQueueItem(
        item.id,
        (entry) => entry.copyWith(
          status: LiveQueueItemStatus.resolving,
          message: 'Buscando...',
        ),
      );
      onSearchStarted();
      late final List<TrackInfo> tracks;
      try {
        tracks = await ref.read(searchTracksProvider).call(query);
      } finally {
        onSearchSettled();
      }
      if (!_isLiveQueueResolutionActive(scheduled)) {
        throw const _LiveQueueOperationCancelled();
      }
      if (tracks.isEmpty) {
        return _LiveQueueResolution.failure(
          scheduled: scheduled,
          errorMessage: 'Sin resultados',
        );
      }

      if (!item.saveToLibrary) {
        return _LiveQueueResolution.success(
          scheduled: scheduled,
          remoteTrack: tracks.first,
        );
      }

      final result = await ref
          .read(localTrackDownloadHelperProvider)
          .resolveForLibrary(
            tracks.first,
            onResolved: (track) {
              if (!_isLiveQueueResolutionActive(scheduled)) {
                throw const _LiveQueueOperationCancelled();
              }
              _updateLiveQueueItem(
                item.id,
                (entry) => entry.copyWith(
                  remoteTrack: track,
                  message: 'Coincidencia: ${track.title}',
                ),
              );
            },
            onDownloadStarted: () {
              if (!_isLiveQueueResolutionActive(scheduled)) {
                throw const _LiveQueueOperationCancelled();
              }
              _updateLiveQueueItem(
                item.id,
                (entry) => entry.copyWith(
                  status: LiveQueueItemStatus.downloading,
                  message: 'Descargando...',
                ),
              );
            },
          );

      if (!_isLiveQueueResolutionActive(scheduled)) {
        throw const _LiveQueueOperationCancelled();
      }
      return _LiveQueueResolution.success(
        scheduled: scheduled,
        remoteTrack: result.remoteTrack,
        localTrack: result.track,
        reusedExisting: result.reusedExisting,
      );
    } catch (error) {
      return _LiveQueueResolution.failure(
        scheduled: scheduled,
        errorMessage: error.toString(),
      );
    }
  }

  void _scheduleMusicQueueCommit(int generation) {
    if (generation != _liveQueueGeneration ||
        !_committingMusicQueueGenerations.add(generation)) {
      return;
    }
    unawaited(_commitCompletedMusicQueue(generation));
  }

  Future<void> _commitCompletedMusicQueue(int generation) async {
    try {
      while (generation == _liveQueueGeneration) {
        if (_cancelledMusicSequences.remove(_nextMusicSequenceToCommit)) {
          _nextMusicSequenceToCommit++;
          continue;
        }
        final resolution = _completedMusicResolutions.remove(
          _nextMusicSequenceToCommit,
        );
        if (resolution == null) {
          return;
        }
        _nextMusicSequenceToCommit++;

        final item = resolution.scheduled.item;
        _scheduledMusicItems.remove(item.id);
        if (!_isLiveQueueOperationCurrent(item.id, generation)) {
          continue;
        }
        if (!resolution.isSuccess) {
          final errorMessage = resolution.errorMessage ?? 'Error desconocido';
          _updateLiveQueueItem(
            item.id,
            (entry) => entry.copyWith(
              status: LiveQueueItemStatus.failed,
              message: errorMessage,
            ),
          );
          _setMessage('No se pudo reproducir "${item.query}": $errorMessage');
          continue;
        }

        final remoteTrack = resolution.remoteTrack!;
        _updateLiveQueueItem(
          item.id,
          (entry) => entry.copyWith(
            status: LiveQueueItemStatus.ready,
            remoteTrack: remoteTrack,
            localTrack: resolution.localTrack,
            reusedExisting: resolution.reusedExisting,
            message: item.saveToLibrary
                ? (resolution.reusedExisting
                      ? 'Lista desde Biblioteca'
                      : 'Descargada')
                : 'Lista para reproducir en streaming',
          ),
        );

        try {
          await _syncLiveQueuePlaybackInOrder(
            saveToLibrary: item.saveToLibrary,
          );
          if (_isLiveQueueOperationCurrent(item.id, generation)) {
            _setMessage(
              item.saveToLibrary
                  ? (resolution.reusedExisting
                        ? 'Agregado desde Biblioteca: ${resolution.localTrack!.title}'
                        : 'Descargado y agregado: ${resolution.localTrack!.title}')
                  : 'Agregado para reproducción remota: ${remoteTrack.title}',
            );
          }
        } catch (error) {
          if (_isLiveQueueOperationCurrent(item.id, generation)) {
            _updateLiveQueueItem(
              item.id,
              (entry) => entry.copyWith(
                status: LiveQueueItemStatus.failed,
                message: error.toString(),
              ),
            );
            _setMessage('No se pudo reproducir "${item.query}": $error');
          }
        }
      }
    } finally {
      _committingMusicQueueGenerations.remove(generation);
      if (generation == _liveQueueGeneration &&
          _completedMusicResolutions.containsKey(_nextMusicSequenceToCommit)) {
        _scheduleMusicQueueCommit(generation);
      }
    }
  }

  Future<void> _syncLiveQueuePlaybackInOrder({required bool saveToLibrary}) {
    final operation = _liveQueueSyncTail.then(
      (_) => _syncLiveQueuePlayback(saveToLibrary: saveToLibrary),
    );
    _liveQueueSyncTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }

  Future<void> _syncLiveQueuePlayback({required bool saveToLibrary}) async {
    final current = state.value;
    if (current == null) {
      return;
    }

    if (!saveToLibrary) {
      await _syncRemoteLiveQueuePlayback(current);
      return;
    }

    final readyTracks = _localPlaybackTracks(current);
    if (readyTracks.isEmpty) {
      final player = ref.read(playerControllerProvider.notifier);
      if (player.isLiveQueueActive) {
        _liveQueueActivated = false;
        await player.clearQueueSource(PlayerController.liveQueueSourceId);
      }
      return;
    }

    final playerState = ref.read(playerControllerProvider).value;
    final currentTrackId = playerState?.trackId;
    final currentIsLiveTrack =
        currentTrackId != null &&
        readyTracks.any((track) => track.id == currentTrackId);
    final player = ref.read(playerControllerProvider.notifier);

    if (!_liveQueueActivated || !currentIsLiveTrack) {
      _liveQueueActivated = true;
      await player.playLocal(
        readyTracks.first,
        queue: readyTracks,
        useNativeQueue: false,
        queueSourceId: PlayerController.liveQueueSourceId,
      );
      _throwIfLivePlaybackFailed();
      return;
    }

    player.replaceLocalQueue(readyTracks, currentTrackId: currentTrackId);
    final playbackFinished =
        playerState?.status == PlayerStatus.stopped ||
        playerState?.status == PlayerStatus.completed ||
        playerState?.status == PlayerStatus.failed ||
        _isPausedAtEnd(playerState);
    if (playbackFinished && readyTracks.length > 1) {
      await player.playNext();
    }
    _throwIfLivePlaybackFailed();
  }

  Future<void> _syncRemoteLiveQueuePlayback(TikTokLiveState current) async {
    final readyTracks = _remotePlaybackTracks(current);
    if (readyTracks.isEmpty) {
      final player = ref.read(playerControllerProvider.notifier);
      if (player.isLiveQueueActive) {
        _liveQueueActivated = false;
        await player.clearQueueSource(PlayerController.liveQueueSourceId);
      }
      return;
    }

    final playerState = ref.read(playerControllerProvider).value;
    final currentIsLiveTrack = readyTracks.any(
      (track) => _snapshotMatchesRemoteTrack(playerState, track),
    );
    final player = ref.read(playerControllerProvider.notifier);

    if (!_liveQueueActivated || !currentIsLiveTrack) {
      _liveQueueActivated = true;
      await player.playRemote(
        readyTracks.first,
        queue: readyTracks,
        queueSourceId: PlayerController.liveQueueSourceId,
      );
      _throwIfLivePlaybackFailed();
      return;
    }

    await player.syncRemoteQueueSource(
      PlayerController.liveQueueSourceId,
      readyTracks,
    );
    final playbackFinished =
        playerState?.status == PlayerStatus.stopped ||
        playerState?.status == PlayerStatus.completed ||
        playerState?.status == PlayerStatus.failed ||
        _isPausedAtEnd(playerState);
    if (playbackFinished && readyTracks.length > 1) {
      await player.playNext();
    }
    _throwIfLivePlaybackFailed();
  }

  List<LocalTrack> _localPlaybackTracks(TikTokLiveState current) {
    final tracks = current.readyTracks.toList(growable: true);
    final revoked = _revokedPlayingItem;
    final revokedTrack = revoked?.saveToLibrary == true
        ? revoked?.localTrack
        : null;
    if (revokedTrack != null) {
      final index = _revokedPlayingReadyIndex.clamp(0, tracks.length).toInt();
      tracks.insert(index, revokedTrack);
    }
    return List<LocalTrack>.unmodifiable(tracks);
  }

  List<TrackInfo> _remotePlaybackTracks(TikTokLiveState current) {
    final tracks = current.readyRemoteTracks.toList(growable: true);
    final revoked = _revokedPlayingItem;
    final revokedTrack = revoked?.saveToLibrary == false
        ? revoked?.remoteTrack
        : null;
    if (revokedTrack != null) {
      final index = _revokedPlayingReadyIndex.clamp(0, tracks.length).toInt();
      tracks.insert(index, revokedTrack);
    }
    return List<TrackInfo>.unmodifiable(tracks);
  }

  bool _snapshotMatchesLiveQueueItem(
    PlayerSnapshot? snapshot,
    LiveQueueItem item,
  ) {
    if (snapshot == null) {
      return false;
    }
    if (item.saveToLibrary) {
      final track = item.localTrack;
      return track != null &&
          (snapshot.trackId == track.id ||
              (!snapshot.isRemote && snapshot.sourceUrl == track.filePath));
    }
    final track = item.remoteTrack;
    return track != null && _snapshotMatchesRemoteTrack(snapshot, track);
  }

  void _handlePlaybackSnapshotForRevokedItem(PlayerSnapshot? snapshot) {
    final revoked = _revokedPlayingItem;
    if (revoked == null ||
        snapshot == null ||
        _snapshotMatchesLiveQueueItem(snapshot, revoked)) {
      return;
    }

    final saveToLibrary = revoked.saveToLibrary;
    _clearRevokedPlayingItem();
    final current = state.value;
    if (current == null ||
        !ref.read(playerControllerProvider.notifier).isLiveQueueActive) {
      return;
    }
    unawaited(_syncLiveQueuePlaybackInOrder(saveToLibrary: saveToLibrary));
  }

  void _clearRevokedPlayingItem() {
    _revokedPlayingItem = null;
    _revokedPlayingReadyIndex = -1;
  }

  void _throwIfLivePlaybackFailed() {
    final playback = ref.read(playerControllerProvider);
    if (playback.hasError) {
      throw playback.error ?? StateError('El reproductor falló sin detalle.');
    }
    final snapshot = playback.value;
    if (snapshot?.status == PlayerStatus.failed) {
      throw StateError(
        snapshot?.errorMessage ?? 'El reproductor no pudo iniciar la pista.',
      );
    }
  }

  bool _snapshotMatchesRemoteTrack(PlayerSnapshot? snapshot, TrackInfo track) {
    if (snapshot == null) {
      return false;
    }
    final trackId = track.id.trim();
    if (trackId.isNotEmpty && snapshot.trackId == trackId) {
      return true;
    }
    final sourceUrl = snapshot.sourceUrl?.trim();
    return sourceUrl != null &&
        sourceUrl.isNotEmpty &&
        (sourceUrl == track.url || sourceUrl == track.streamUrl);
  }

  void _cancelMusicQueueOperations() {
    _liveQueueGeneration++;
    _pendingMusicQueue.clear();
    _completedMusicResolutions.clear();
    _scheduledMusicItems.clear();
    _cancelledMusicSequences.clear();
    _clearRevokedPlayingItem();
    // Existing non-cancellable Futures keep their worker slots until they
    // settle, but their sequence numbers must never block the new generation.
    _nextMusicSequenceToCommit = _nextMusicSequence;
  }

  bool _isLiveQueueResolutionActive(_ScheduledLiveQueueItem scheduled) {
    return !scheduled.searchDeadlineExceeded &&
        _isLiveQueueOperationCurrent(scheduled.item.id, scheduled.generation);
  }

  bool _isLiveQueueOperationCurrent(String itemId, int generation) {
    if (generation != _liveQueueGeneration) {
      return false;
    }
    final current = state.value;
    return current != null &&
        current.liveQueue.any((item) => item.id == itemId);
  }

  bool _isPausedAtEnd(PlayerSnapshot? snapshot) {
    if (snapshot?.status != PlayerStatus.paused || snapshot?.duration == null) {
      return false;
    }
    return snapshot!.duration! - snapshot.position <=
        const Duration(seconds: 1);
  }

  void _updateLiveQueueItem(
    String itemId,
    LiveQueueItem Function(LiveQueueItem item) update,
  ) {
    final current = state.value;
    if (current == null) {
      return;
    }

    state = AsyncData(
      current.copyWith(
        liveQueue: [
          for (final item in current.liveQueue)
            item.id == itemId ? update(item) : item,
        ],
      ),
    );
  }

  void _setMessage(String message) {
    final current = state.value;
    if (current == null) {
      return;
    }
    state = AsyncData(current.copyWith(message: message));
  }
}
