part of 'music_providers.dart';

final tiktokLiveControllerProvider =
    AsyncNotifierProvider<TikTokLiveController, TikTokLiveState>(
      TikTokLiveController.new,
    );

enum LiveQueueItemStatus { resolving, downloading, ready, failed }

enum TikTokCommandAccess { everyone, moderators }

class _LiveQueueOperationCancelled implements Exception {
  const _LiveQueueOperationCancelled();
}

bool canUseTikTokCommand(
  TikTokCommandAccess access,
  TikTokLiveChatCommand command,
) {
  return access == TikTokCommandAccess.everyone || command.isModerator;
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
    this.commandAccess = TikTokCommandAccess.everyone,
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
  final TikTokCommandAccess commandAccess;
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
        if (item.localTrack case final track?)
          if (seen.add(track.id)) track,
    ];
  }

  List<TrackInfo> get readyRemoteTracks {
    final seen = <String>{};
    return [
      for (final item in liveQueue)
        if (!item.saveToLibrary)
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
    TikTokCommandAccess? commandAccess,
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
      commandAccess: commandAccess ?? this.commandAccess,
      saveRequestsToLibrary:
          saveRequestsToLibrary ?? this.saveRequestsToLibrary,
      commandsHandled: commandsHandled ?? this.commandsHandled,
      liveQueue: liveQueue ?? this.liveQueue,
    );
  }
}

class TikTokLiveController extends AsyncNotifier<TikTokLiveState> {
  /// Bounds both the visible LIVE queue and its serial search/download backlog.
  ///
  /// Keeping the value public makes the product limit explicit to UI and
  /// regression tests instead of relying on an unbounded in-memory queue.
  static const int maxQueueItems = 50;

  static const _creatorInputKey = 'tiktokLive.creatorInput';
  static const _commandAccessKey = 'tiktokLive.commandAccess';
  static const _saveRequestsToLibraryKey = 'tiktokLive.saveRequestsToLibrary';

  final _musicQueue = Queue<LiveQueueItem>();
  bool _processingMusicQueue = false;
  bool _liveQueueActivated = false;
  int _liveQueueGeneration = 0;

  @override
  Future<TikTokLiveState> build() async {
    final service = ref.watch(tiktokLiveCommandServiceProvider);
    final subscription = service.events.listen(_handleBridgeEvent);
    ref.onDispose(subscription.cancel);

    final prefs = await SharedPreferences.getInstance();
    final creatorInput = prefs.getString(_creatorInputKey) ?? '';
    final storedCommandAccess = prefs.getString(_commandAccessKey);
    final commandAccess = TikTokCommandAccess.values.firstWhere(
      (value) => value.name == storedCommandAccess,
      orElse: () => TikTokCommandAccess.everyone,
    );
    final saveRequestsToLibrary =
        prefs.getBool(_saveRequestsToLibraryKey) ?? false;
    return TikTokLiveState(
      creatorInput: creatorInput,
      normalizedCreator: normalizeCreatorInput(creatorInput),
      status: TikTokLiveStatus.idle,
      commandAccess: commandAccess,
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

  Future<void> setCommandAccess(TikTokCommandAccess access) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_commandAccessKey, access.name);
    final current = await future;
    state = AsyncData(current.copyWith(commandAccess: access));
  }

  Future<void> setSaveRequestsToLibrary(bool value) async {
    final current = state.value ?? await future;
    if (current.saveRequestsToLibrary == value) {
      return;
    }
    if (current.liveQueue.isNotEmpty) {
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
    _liveQueueGeneration++;
    _musicQueue.clear();
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
    _liveQueueGeneration++;
    _musicQueue.clear();
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

  Future<void> playLiveQueueItem(String itemId) async {
    final current = await future;
    final item = current.liveQueue
        .where((entry) => entry.id == itemId && entry.isReady)
        .firstOrNull;
    if (item == null) {
      return;
    }

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

    if (!canUseTikTokCommand(current.commandAccess, command)) {
      state = AsyncData(
        current.copyWith(
          lastCommand: command,
          message:
              'Comando ignorado de ${command.user}: solo se permiten moderadores.',
        ),
      );
      return;
    }

    if (command.action == 'play' && current.liveQueue.length >= maxQueueItems) {
      state = AsyncData(
        current.copyWith(
          lastCommand: command,
          message:
              'Cola LIVE llena (maximo $maxQueueItems). Limpiala antes de agregar mas pedidos.',
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
      _musicQueue.add(liveItem);
      unawaited(_processMusicQueue());
      return;
    }

    unawaited(_handleImmediateCommand(command));
  }

  String _commandMessage(TikTokLiveChatCommand command) {
    return switch (command.action) {
      'play' => '${command.user}: !play ${command.query ?? ''}',
      'skip' => '${command.user}: !skip',
      'revoke' => '${command.user}: revoke!',
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
          await clearLiveQueue();
      }
    } catch (error) {
      _setMessage('No se pudo ejecutar ${command.text}: $error');
    }
  }

  Future<void> _processMusicQueue() async {
    if (_processingMusicQueue) {
      return;
    }
    _processingMusicQueue = true;

    try {
      while (_musicQueue.isNotEmpty) {
        final item = _musicQueue.removeFirst();
        final generation = _liveQueueGeneration;
        await _handlePlayCommand(item, generation);
      }
    } finally {
      _processingMusicQueue = false;
    }
  }

  Future<void> _handlePlayCommand(LiveQueueItem item, int generation) async {
    final query = item.query.trim();
    if (query.isEmpty || !_isLiveQueueOperationCurrent(item.id, generation)) {
      return;
    }

    try {
      _updateLiveQueueItem(
        item.id,
        (entry) => entry.copyWith(
          status: LiveQueueItemStatus.resolving,
          message: 'Buscando...',
        ),
      );
      _setMessage('Buscando pedido de ${item.requestedBy}: $query');
      final tracks = await ref.read(searchTracksProvider).call(query);
      if (!_isLiveQueueOperationCurrent(item.id, generation)) {
        return;
      }
      if (tracks.isEmpty) {
        _updateLiveQueueItem(
          item.id,
          (entry) => entry.copyWith(
            status: LiveQueueItemStatus.failed,
            message: 'Sin resultados',
          ),
        );
        _setMessage('No encontre resultados para: $query');
        return;
      }

      if (!item.saveToLibrary) {
        final remoteTrack = tracks.first;
        _updateLiveQueueItem(
          item.id,
          (entry) => entry.copyWith(
            status: LiveQueueItemStatus.ready,
            remoteTrack: remoteTrack,
            message: 'Lista para reproducir en streaming',
          ),
        );
        await _syncLiveQueuePlayback(saveToLibrary: false);
        if (_isLiveQueueOperationCurrent(item.id, generation)) {
          _setMessage(
            'Agregado para reproduccion remota: ${remoteTrack.title}',
          );
        }
        return;
      }

      final result = await ref
          .read(localTrackDownloadHelperProvider)
          .resolveForLibrary(
            tracks.first,
            onResolved: (track) {
              if (!_isLiveQueueOperationCurrent(item.id, generation)) {
                throw const _LiveQueueOperationCancelled();
              }
              _updateLiveQueueItem(
                item.id,
                (entry) => entry.copyWith(
                  remoteTrack: track,
                  message: 'Coincidencia: ${track.title}',
                ),
              );
              _setMessage('Preparando pedido: ${track.title}');
            },
            onDownloadStarted: () {
              if (!_isLiveQueueOperationCurrent(item.id, generation)) {
                throw const _LiveQueueOperationCancelled();
              }
              _updateLiveQueueItem(
                item.id,
                (entry) => entry.copyWith(
                  status: LiveQueueItemStatus.downloading,
                  message: 'Descargando...',
                ),
              );
              _setMessage('Descargando pedido de ${item.requestedBy}...');
            },
          );

      if (!_isLiveQueueOperationCurrent(item.id, generation)) {
        return;
      }

      _updateLiveQueueItem(
        item.id,
        (entry) => entry.copyWith(
          status: LiveQueueItemStatus.ready,
          remoteTrack: result.remoteTrack,
          localTrack: result.track,
          reusedExisting: result.reusedExisting,
          message: result.reusedExisting
              ? 'Lista desde Biblioteca'
              : 'Descargada',
        ),
      );
      await _syncLiveQueuePlayback(saveToLibrary: true);
      if (_isLiveQueueOperationCurrent(item.id, generation)) {
        _setMessage(
          result.reusedExisting
              ? 'Agregado desde Biblioteca: ${result.track.title}'
              : 'Descargado y agregado: ${result.track.title}',
        );
      }
    } catch (error) {
      if (!_isLiveQueueOperationCurrent(item.id, generation)) {
        return;
      }
      _updateLiveQueueItem(
        item.id,
        (entry) => entry.copyWith(
          status: LiveQueueItemStatus.failed,
          message: error.toString(),
        ),
      );
      _setMessage('No se pudo reproducir "$query": $error');
    }
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

    final readyTracks = current.readyTracks;
    if (readyTracks.isEmpty) {
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
      return;
    }

    player.replaceLocalQueue(readyTracks, currentTrackId: currentTrackId);
    final playbackFinished =
        playerState?.status == PlayerStatus.stopped ||
        playerState?.status == PlayerStatus.failed ||
        _isPausedAtEnd(playerState);
    if (playbackFinished && readyTracks.length > 1) {
      await player.playNext();
    }
  }

  Future<void> _syncRemoteLiveQueuePlayback(TikTokLiveState current) async {
    final readyTracks = current.readyRemoteTracks;
    if (readyTracks.isEmpty) {
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
      return;
    }

    await player.syncRemoteQueueSource(
      PlayerController.liveQueueSourceId,
      readyTracks,
    );
    final playbackFinished =
        playerState?.status == PlayerStatus.stopped ||
        playerState?.status == PlayerStatus.failed ||
        _isPausedAtEnd(playerState);
    if (playbackFinished && readyTracks.length > 1) {
      await player.playNext();
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
