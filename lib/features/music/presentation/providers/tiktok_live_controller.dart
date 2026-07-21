part of 'music_providers.dart';

final tiktokLiveControllerProvider =
    AsyncNotifierProvider<TikTokLiveController, TikTokLiveState>(
      TikTokLiveController.new,
    );

enum LiveQueueItemStatus { resolving, downloading, ready, failed }

enum TikTokCommandAccess { everyone, moderators }

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
  });

  factory LiveQueueItem.fromCommand(TikTokLiveChatCommand command) {
    return LiveQueueItem(
      id: const Uuid().v4(),
      requestedBy: command.user,
      query: command.query?.trim() ?? '',
      commandText: command.text,
      requestedAt: DateTime.now(),
      status: LiveQueueItemStatus.resolving,
      requestedByModerator: command.isModerator,
      message: 'Buscando...',
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

  bool get isPending =>
      status == LiveQueueItemStatus.resolving ||
      status == LiveQueueItemStatus.downloading;

  bool get isReady => status == LiveQueueItemStatus.ready && localTrack != null;

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
    this.commandsHandled = 0,
    this.liveQueue = const [],
  });

  final String creatorInput;
  final TikTokLiveBridgeStatus status;
  final String message;
  final String? normalizedCreator;
  final String? roomId;
  final TikTokLiveChatCommand? lastCommand;
  final TikTokCommandAccess commandAccess;
  final int commandsHandled;
  final List<LiveQueueItem> liveQueue;

  bool get isConnected => status == TikTokLiveBridgeStatus.connected;
  bool get isBusy => status == TikTokLiveBridgeStatus.connecting;
  int get pendingPlayCommands =>
      liveQueue.where((item) => item.isPending).length;
  int get readyPlayCommands => liveQueue.where((item) => item.isReady).length;
  List<LocalTrack> get readyTracks => liveQueue
      .map((item) => item.localTrack)
      .whereType<LocalTrack>()
      .toList(growable: false);

  TikTokLiveState copyWith({
    String? creatorInput,
    TikTokLiveBridgeStatus? status,
    String? message,
    String? normalizedCreator,
    String? roomId,
    TikTokLiveChatCommand? lastCommand,
    TikTokCommandAccess? commandAccess,
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
      commandsHandled: commandsHandled ?? this.commandsHandled,
      liveQueue: liveQueue ?? this.liveQueue,
    );
  }
}

class TikTokLiveController extends AsyncNotifier<TikTokLiveState> {
  static const _creatorInputKey = 'tiktokLive.creatorInput';
  static const _commandAccessKey = 'tiktokLive.commandAccess';

  final _musicQueue = Queue<LiveQueueItem>();
  bool _processingMusicQueue = false;
  bool _liveQueueActivated = false;

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
    return TikTokLiveState(
      creatorInput: creatorInput,
      normalizedCreator: normalizeCreatorInput(creatorInput),
      status: TikTokLiveBridgeStatus.idle,
      commandAccess: commandAccess,
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

  Future<void> connect([String? value]) async {
    final current = await future;
    final input = (value ?? current.creatorInput).trim();
    await setCreatorInput(input);
    final normalized = normalizeCreatorInput(input);
    if (normalized.isEmpty) {
      state = AsyncData(
        current.copyWith(
          creatorInput: input,
          status: TikTokLiveBridgeStatus.error,
          message: 'Ingresa @usuario o el link del live.',
        ),
      );
      return;
    }

    state = AsyncData(
      current.copyWith(
        creatorInput: input,
        normalizedCreator: normalized,
        status: TikTokLiveBridgeStatus.connecting,
        message: 'Conectando a @$normalized...',
      ),
    );

    try {
      await ref.read(tiktokLiveCommandServiceProvider).connect(normalized);
    } catch (error) {
      final latest = await future;
      state = AsyncData(
        latest.copyWith(
          status: TikTokLiveBridgeStatus.error,
          message: error.toString(),
        ),
      );
    }
  }

  Future<void> disconnect() async {
    await ref.read(tiktokLiveCommandServiceProvider).disconnect();
    final current = await future;
    _musicQueue.clear();
    _liveQueueActivated = false;
    state = AsyncData(
      current.copyWith(
        status: TikTokLiveBridgeStatus.disconnected,
        message: 'Desconectado.',
        liveQueue: const [],
      ),
    );
  }

  Future<void> clearLiveQueue({bool stopPlayback = true}) async {
    _musicQueue.clear();
    _liveQueueActivated = false;
    final current = await future;
    state = AsyncData(
      current.copyWith(liveQueue: const [], message: 'Cola LIVE limpia.'),
    );
    ref.read(playerControllerProvider.notifier).replaceLocalQueue(const []);
    if (stopPlayback) {
      await ref.read(playerControllerProvider.notifier).stop();
    }
  }

  Future<void> playLiveQueueItem(String itemId) async {
    final current = await future;
    final readyTracks = current.readyTracks;
    if (readyTracks.isEmpty) {
      return;
    }
    final item = current.liveQueue
        .where((entry) => entry.id == itemId && entry.localTrack != null)
        .firstOrNull;
    final track = item?.localTrack;
    if (track == null) {
      return;
    }

    _liveQueueActivated = true;
    await ref
        .read(playerControllerProvider.notifier)
        .playLocal(track, queue: readyTracks, useNativeQueue: false);
    _setMessage('Reproduciendo cola LIVE: ${track.title}');
  }

  void _handleBridgeEvent(TikTokLiveBridgeEvent event) {
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

    final liveItem = command.action == 'play'
        ? LiveQueueItem.fromCommand(command)
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
          await ref.read(playerControllerProvider.notifier).playNext();
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
        await _handlePlayCommand(item);
      }
    } finally {
      _processingMusicQueue = false;
    }
  }

  Future<void> _handlePlayCommand(LiveQueueItem item) async {
    final query = item.query.trim();
    if (query.isEmpty) {
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

      final result = await ref
          .read(localTrackDownloadHelperProvider)
          .resolveForLibrary(
            tracks.first,
            reuseExisting: true,
            onResolved: (track) {
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
      await _syncLiveQueuePlayback();
      _setMessage(
        result.reusedExisting
            ? 'Agregado desde Biblioteca: ${result.track.title}'
            : 'Descargado y agregado: ${result.track.title}',
      );
    } catch (error) {
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

  Future<void> _syncLiveQueuePlayback() async {
    final current = state.value;
    if (current == null) {
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
