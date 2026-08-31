import 'dart:async';

import 'package:piratetok_live/piratetok_live.dart';

import 'tiktok_live_models.dart';

typedef TikTokLiveDartClientFactory =
    TikTokLiveDartClient Function(String user);

/// Small boundary around the unofficial TikTok transport.
///
/// Keeping the package behind this interface lets the application test its
/// lifecycle without opening real LIVE rooms and makes replacing or forking the
/// protocol implementation possible without changing the player controller.
abstract interface class TikTokLiveDartClient {
  void on(
    String eventType,
    void Function(TikTokLiveDartRawEvent event) handler,
  );

  Future<String> connect();

  void disconnect();
}

class TikTokLiveDartRawEvent {
  const TikTokLiveDartRawEvent({
    required this.type,
    this.data,
    this.roomId = '',
  });

  final String type;
  final Map<String, dynamic>? data;
  final String roomId;
}

/// Direct Dart implementation of BStream's TikTok LIVE command transport.
///
/// The audited transport reports its `connected` event after the WebSocket
/// handshake. The adapter also accepts the first decoded traffic event as a
/// confirmation fallback for alternate clients and protocol upgrades.
class TikTokLiveDartAdapter {
  TikTokLiveDartAdapter({
    TikTokLiveDartClientFactory? clientFactory,
    this.restartDelay = const Duration(seconds: 2),
    this.maxSessionRestarts = 3,
  }) : _clientFactory = clientFactory ?? PirateTokLiveDartClient.new {
    if (maxSessionRestarts < 0) {
      throw ArgumentError.value(
        maxSessionRestarts,
        'maxSessionRestarts',
        'No puede ser negativo.',
      );
    }
    if (restartDelay.isNegative) {
      throw ArgumentError.value(
        restartDelay,
        'restartDelay',
        'No puede ser negativo.',
      );
    }
  }

  static const _connectedEvent = 'connected';
  static const _websocketConnectedEvent = 'websocket_connected';
  static const _reconnectingEvent = 'reconnecting';
  static const _disconnectedEvent = 'disconnected';
  static const _errorEvent = 'error';
  static const _chatEvent = 'chat';
  static const _liveEndedEvent = 'live_ended';

  // Each of these can only be decoded after the WebSocket is open, so any one
  // of them is sufficient to confirm the connection. Registering several also
  // makes confirmation reliable in quiet rooms where chat may be infrequent.
  static const _trafficEvents = <String>{
    _chatEvent,
    'member',
    'gift',
    'like',
    'social',
    'room_user_seq',
    _liveEndedEvent,
    'follow',
    'share',
    'join',
  };

  final TikTokLiveDartClientFactory _clientFactory;
  final Duration restartDelay;
  final int maxSessionRestarts;
  final _events = StreamController<TikTokLiveEvent>.broadcast();

  TikTokLiveDartClient? _client;
  Future<void>? _worker;
  int _generation = 0;
  int _lifecycleIntent = 0;
  bool _running = false;
  bool _disposeRequested = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  Stream<TikTokLiveEvent> get events => _events.stream;

  bool get isRunning => _running;

  Future<void> connect(String rawUser) async {
    if (_disposeRequested || _disposed) {
      throw StateError('El adaptador TikTok LIVE ya fue cerrado.');
    }

    final user = normalizeCreatorInput(rawUser);
    if (user.isEmpty) {
      throw const FormatException('Ingresa un usuario o link de TikTok LIVE.');
    }

    // Capture the user's intent before yielding. A later connect, disconnect,
    // or dispose must win even if this call is still waiting for an older
    // transport to finish shutting down.
    final lifecycleIntent = ++_lifecycleIntent;
    await _stopCurrent();
    if (!_acceptsLifecycleIntent(lifecycleIntent)) {
      return;
    }
    final generation = ++_generation;
    _running = true;
    _emit(
      TikTokLiveEvent(
        type: 'status',
        status: TikTokLiveStatus.connecting,
        user: user,
        message: 'Conectando directamente a @$user...',
      ),
    );
    final worker = _run(user, generation);
    _worker = worker;
    unawaited(
      worker.then<void>(
        (_) => _clearWorker(generation, worker),
        onError: (Object error, StackTrace stackTrace) {
          _clearWorker(generation, worker);
          if (_accepts(generation)) {
            _running = false;
            _emit(
              TikTokLiveEvent(
                type: _errorEvent,
                status: TikTokLiveStatus.error,
                user: user,
                message: 'Falló la conexión directa con TikTok LIVE: $error',
              ),
            );
          }
        },
      ),
    );
  }

  Future<void> disconnect() async {
    if (_disposeRequested || _disposed) {
      await (_disposeFuture ?? Future<void>.value());
      return;
    }
    final lifecycleIntent = ++_lifecycleIntent;
    final wasRunning = await _stopCurrent();
    if (_acceptsLifecycleIntent(lifecycleIntent) && wasRunning) {
      _emit(
        const TikTokLiveEvent(
          type: _disconnectedEvent,
          status: TikTokLiveStatus.disconnected,
          message: 'Desconectado.',
        ),
      );
    }
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    _disposeRequested = true;
    final lifecycleIntent = ++_lifecycleIntent;
    final future = _dispose(lifecycleIntent);
    _disposeFuture = future;
    return future;
  }

  Future<void> _dispose(int lifecycleIntent) async {
    await _stopCurrent();
    if (lifecycleIntent != _lifecycleIntent || _disposed) {
      return;
    }
    _disposed = true;
    await _events.close();
  }

  Future<void> _run(String user, int generation) async {
    Object? lastError;

    for (var restart = 0; restart <= maxSessionRestarts; restart++) {
      if (!_accepts(generation)) {
        return;
      }

      var websocketConfirmed = false;
      var liveEnded = false;
      var roomId = '';
      TikTokLiveDartClient? client;

      try {
        final activeClient = _clientFactory(user);
        client = activeClient;
        if (!_accepts(generation)) {
          _disconnectQuietly(activeClient);
          return;
        }
        _client = activeClient;

        bool acceptsActiveClient() =>
            _accepts(generation) && identical(_client, activeClient);

        void confirmWebSocket(TikTokLiveDartRawEvent event) {
          if (!acceptsActiveClient() || websocketConfirmed) {
            return;
          }
          websocketConfirmed = true;
          final eventRoomId = event.roomId.trim();
          if (eventRoomId.isNotEmpty) {
            roomId = eventRoomId;
          }
          _emit(
            TikTokLiveEvent(
              type: _connectedEvent,
              status: TikTokLiveStatus.connected,
              user: user,
              roomId: roomId.isEmpty ? null : roomId,
              message: 'Conectado a @$user',
            ),
          );
        }

        activeClient.on(_connectedEvent, (event) {
          if (!acceptsActiveClient()) {
            return;
          }
          // This is room discovery in PirateTok, not proof of a WSS upgrade.
          final eventRoomId = event.roomId.trim();
          final payloadRoomId = event.data?['room_id']?.toString().trim() ?? '';
          roomId = eventRoomId.isNotEmpty ? eventRoomId : payloadRoomId;
        });

        // The production wrapper maps this private event to the fork's
        // post-handshake `connected` signal. Fakes and alternate transports
        // can omit it; real traffic remains a safe confirmation fallback.
        activeClient.on(_websocketConnectedEvent, confirmWebSocket);

        activeClient.on(_reconnectingEvent, (event) {
          if (!acceptsActiveClient()) {
            return;
          }
          websocketConfirmed = false;
          final attempt = event.data?['attempt']?.toString();
          final suffix = attempt == null || attempt.isEmpty
              ? ''
              : ' (intento $attempt)';
          _emit(
            TikTokLiveEvent(
              type: 'status',
              status: TikTokLiveStatus.connecting,
              user: user,
              roomId: roomId.isEmpty ? null : roomId,
              message: 'Reconectando TikTok LIVE$suffix...',
            ),
          );
        });

        // PirateTok reports this when its entire internal retry loop exits. The
        // outer loop below decides whether it is terminal, avoiding a false
        // disconnected state between automatic restarts.
        activeClient.on(_disconnectedEvent, (_) {});

        activeClient.on(_errorEvent, (event) {
          if (!acceptsActiveClient()) {
            return;
          }
          final message = _rawErrorMessage(event.data);
          if (message != null) {
            _emit(
              TikTokLiveEvent(
                type: 'status',
                user: user,
                roomId: roomId.isEmpty ? null : roomId,
                message: message,
              ),
            );
          }
        });

        for (final eventType in _trafficEvents) {
          activeClient.on(eventType, (event) {
            if (!acceptsActiveClient()) {
              return;
            }
            if (event.type == _liveEndedEvent) {
              liveEnded = true;
              _running = false;
              _emit(
                TikTokLiveEvent(
                  type: _liveEndedEvent,
                  status: TikTokLiveStatus.liveEnded,
                  user: user,
                  roomId: event.roomId.trim().isEmpty
                      ? (roomId.isEmpty ? null : roomId)
                      : event.roomId,
                  message: _liveEndedMessage(event.data),
                ),
              );
              _disconnectQuietly(activeClient);
              return;
            }

            confirmWebSocket(event);
            if (event.type == _chatEvent) {
              final command = _commandFromChatEvent(event.data);
              if (command != null) {
                _emit(
                  TikTokLiveEvent(
                    type: 'command',
                    user: user,
                    roomId: event.roomId.trim().isEmpty
                        ? (roomId.isEmpty ? null : roomId)
                        : event.roomId,
                    command: command,
                  ),
                );
              }
            }
          });
        }

        final resolvedRoomId = await activeClient.connect();
        if (resolvedRoomId.trim().isNotEmpty) {
          roomId = resolvedRoomId.trim();
        }
        lastError = null;
      } on UserNotFoundError catch (error) {
        if (!_accepts(generation)) {
          return;
        }
        _finishAsUnavailable(user, generation, error.toString());
        return;
      } on HostNotOnlineError catch (error) {
        if (!_accepts(generation)) {
          return;
        }
        _finishAsUnavailable(user, generation, error.toString());
        return;
      } on Object catch (error) {
        lastError = error;
      } finally {
        if (identical(_client, client)) {
          _client = null;
        }
        _disconnectQuietly(client);
      }

      if (!_accepts(generation) || liveEnded) {
        return;
      }
      if (restart == maxSessionRestarts) {
        break;
      }

      final attempt = restart + 1;
      _emit(
        TikTokLiveEvent(
          type: 'status',
          status: TikTokLiveStatus.connecting,
          user: user,
          roomId: roomId.isEmpty ? null : roomId,
          message: websocketConfirmed
              ? 'La conexión LIVE se cerró. Reconectando...'
              : 'No se confirmó la conexión LIVE. Reintentando ($attempt/$maxSessionRestarts)...',
        ),
      );
      if (!await _waitWhileActive(_restartDelayFor(attempt), generation)) {
        return;
      }
    }

    if (_accepts(generation)) {
      _running = false;
      _emit(
        TikTokLiveEvent(
          type: _errorEvent,
          status: TikTokLiveStatus.error,
          user: user,
          message: lastError == null
              ? 'No se pudo mantener la conexión con TikTok LIVE.'
              : 'No se pudo conectar a TikTok LIVE: $lastError',
        ),
      );
    }
  }

  void _finishAsUnavailable(String user, int generation, String detail) {
    if (!_accepts(generation)) {
      return;
    }
    _running = false;
    _emit(
      TikTokLiveEvent(
        type: _liveEndedEvent,
        status: TikTokLiveStatus.liveEnded,
        user: user,
        message: 'No encontré un LIVE activo para @$user. $detail',
      ),
    );
  }

  Future<bool> _stopCurrent() async {
    final wasRunning = _running || _client != null || _worker != null;
    _generation++;
    _running = false;
    final client = _client;
    final worker = _worker;
    _client = null;
    _worker = null;
    _disconnectQuietly(client);

    if (worker != null) {
      await worker.timeout(const Duration(seconds: 4), onTimeout: () {});
    }
    return wasRunning;
  }

  bool _accepts(int generation) =>
      !_disposeRequested && !_disposed && _running && generation == _generation;

  bool _acceptsLifecycleIntent(int lifecycleIntent) =>
      !_disposeRequested && !_disposed && lifecycleIntent == _lifecycleIntent;

  Future<bool> _waitWhileActive(Duration delay, int generation) async {
    if (delay == Duration.zero) return _accepts(generation);
    final stopwatch = Stopwatch()..start();
    const cancellationPoll = Duration(milliseconds: 100);
    while (_accepts(generation)) {
      final elapsed = stopwatch.elapsed;
      if (elapsed >= delay) break;
      final remaining = delay - elapsed;
      await Future<void>.delayed(
        remaining < cancellationPoll ? remaining : cancellationPoll,
      );
    }
    return _accepts(generation);
  }

  Duration _restartDelayFor(int attempt) {
    // Preserve the proven Python bridge cadence (2s, 5s, 10s) while allowing
    // tests to inject a much smaller base delay.
    final multiplier = switch (attempt) {
      <= 1 => 1.0,
      2 => 2.5,
      _ => 5.0,
    };
    return restartDelay * multiplier;
  }

  void _clearWorker(int generation, Future<void> worker) {
    if (generation == _generation && identical(_worker, worker)) {
      _worker = null;
    }
  }

  void _disconnectQuietly(TikTokLiveDartClient? client) {
    try {
      client?.disconnect();
    } on Object {
      // Cancellation is best effort. Generation checks still reject late data.
    }
  }

  void _emit(TikTokLiveEvent event) {
    if (!_disposed && !_events.isClosed) {
      _events.add(event);
    }
  }
}

/// Production client backed by the pure-Dart PirateTok connector.
class PirateTokLiveDartClient implements TikTokLiveDartClient {
  PirateTokLiveDartClient(String user)
    : _client = TikTokLiveClient(user)
          .decodedMethods(const {'WebcastChatMessage', 'WebcastControlMessage'})
          .chatMessageFilter(isPotentialTikTokLiveCommandText)
          .timeout(const Duration(seconds: 15))
          .maxRetries(5)
          .staleTimeout(const Duration(seconds: 90));

  final TikTokLiveClient _client;

  @override
  Future<String> connect() => _client.connect();

  @override
  void disconnect() => _client.disconnect();

  @override
  void on(
    String eventType,
    void Function(TikTokLiveDartRawEvent event) handler,
  ) {
    final transportEvent = eventType == 'websocket_connected'
        ? EventType.websocketConnected
        : eventType;
    _client.on(transportEvent, (event) {
      handler(
        TikTokLiveDartRawEvent(
          type: event.type,
          data: event.data,
          roomId: event.roomId,
        ),
      );
    });
  }
}

/// Cheap pre-filter used before PirateTok decodes a chat user's full profile.
///
/// Exact command validation remains in [parseTikTokLiveCommand]. This only
/// rejects ordinary chat lines that cannot possibly be a BStream command.
bool isPotentialTikTokLiveCommandText(String text) {
  final message = text.trim();
  return message.startsWith('!') || message.toLowerCase() == 'revoke!';
}

TikTokLiveChatCommand? parseTikTokLiveCommand(
  String text, {
  required String user,
  bool isModerator = false,
  bool isSubscriber = false,
}) {
  final message = text.trim();
  if (message.isEmpty) {
    return null;
  }

  if (message.toLowerCase() == 'revoke!') {
    return TikTokLiveChatCommand(
      action: 'revoke',
      user: user,
      text: message,
      isModerator: isModerator,
      isSubscriber: isSubscriber,
    );
  }
  if (!message.startsWith('!')) {
    return null;
  }

  final payload = message.substring(1).trim();
  if (payload.isEmpty) {
    return null;
  }
  final separator = payload.indexOf(RegExp(r'\s'));
  final action = (separator < 0 ? payload : payload.substring(0, separator))
      .toLowerCase();
  final query = separator < 0 ? '' : payload.substring(separator).trim();

  if (action == 'play' && query.isNotEmpty) {
    return TikTokLiveChatCommand(
      action: 'play',
      query: query,
      user: user,
      text: message,
      isModerator: isModerator,
      isSubscriber: isSubscriber,
    );
  }
  final normalizedAction = switch (action) {
    'skip' || 'next' => 'skip',
    'revoke' => 'revoke',
    'stop' => 'stop',
    _ => null,
  };
  if (normalizedAction == null) {
    return null;
  }
  return TikTokLiveChatCommand(
    action: normalizedAction,
    user: user,
    text: message,
    isModerator: isModerator,
    isSubscriber: isSubscriber,
  );
}

/// Reads moderator status from current and forward-compatible PirateTok maps.
///
/// PirateTok 0.1.5 exposes badge scene 1 (TikTok's ADMIN badge) but does not
/// currently surface `UserIdentity.isModeratorOfAnchor` in `User.toJson()`.
/// Supporting both forms preserves moderator-only mode if that field is added
/// upstream while retaining correct behavior with the pinned release.
bool isTikTokLiveModerator(
  Map<String, dynamic>? user, {
  Map<String, dynamic>? eventData,
}) {
  final candidates = <Map<String, dynamic>>[
    ?user,
    ?eventData,
    ?_mapAt(user, 'userIdentity'),
    ?_mapAt(user, 'user_identity'),
    ?_mapAt(eventData, 'userIdentity'),
    ?_mapAt(eventData, 'user_identity'),
  ];

  const moderatorKeys = <String>[
    'isModeratorOfAnchor',
    'is_moderator_of_anchor',
    'isModerator',
    'is_moderator',
  ];
  for (final candidate in candidates) {
    for (final key in moderatorKeys) {
      if (_boolValue(candidate[key])) {
        return true;
      }
    }
  }

  final badges = <Object?>[
    ...?_listAt(user, 'badgeList'),
    ...?_listAt(user, 'badge_list'),
    ...?_listAt(user, 'badges'),
  ];
  for (final badgeValue in badges) {
    final badge = _stringKeyedMap(badgeValue);
    if (badge == null) {
      continue;
    }
    final scene =
        badge['badgeScene'] ??
        badge['badge_scene'] ??
        badge['badgeSceneType'] ??
        badge['badge_scene_type'];
    if (scene is num && scene.toInt() == 1) {
      return true;
    }
    final normalized = scene?.toString().trim().toUpperCase() ?? '';
    if (normalized == '1' ||
        normalized == 'ADMIN' ||
        normalized.endsWith('_ADMIN')) {
      return true;
    }
  }
  return false;
}

/// Reads subscriber status from the identity attached to a chat message.
///
/// `UserIdentity.isSubscriberOfAnchor` is the most specific signal because it
/// is explicitly relative to the active LIVE creator. Alternate field names
/// keep the adapter compatible with transports that normalize protobuf maps.
/// PirateTok's older `User.isSubscribe` field is retained as a final fallback.
bool isTikTokLiveSubscriber(
  Map<String, dynamic>? user, {
  Map<String, dynamic>? eventData,
}) {
  final identityCandidates = <Map<String, dynamic>>[
    ?_mapAt(user, 'userIdentity'),
    ?_mapAt(user, 'user_identity'),
    ?_mapAt(eventData, 'userIdentity'),
    ?_mapAt(eventData, 'user_identity'),
    ?user,
    ?eventData,
  ];
  final anchorSubscriber = _firstKnownBool(identityCandidates, const [
    'isSubscriberOfAnchor',
    'is_subscriber_of_anchor',
  ]);
  if (anchorSubscriber != null) {
    return anchorSubscriber;
  }

  final normalizedSubscriber = _firstKnownBool(identityCandidates, const [
    'isSubscriber',
    'is_subscriber',
  ]);
  if (normalizedSubscriber != null) {
    return normalizedSubscriber;
  }

  return _firstKnownBool([?user], const ['isSubscribe', 'is_subscribe']) ??
      false;
}

TikTokLiveChatCommand? _commandFromChatEvent(Map<String, dynamic>? data) {
  if (data == null) {
    return null;
  }
  final user = _stringKeyedMap(data['user']);
  final username = _firstNonEmpty([
    user?['uniqueId'],
    user?['unique_id'],
    user?['displayId'],
    user?['display_id'],
    user?['nickname'],
    user?['id'],
  ]);
  final content = _firstNonEmpty([
    data['content'],
    data['comment'],
    data['text'],
  ]);
  if (content.isEmpty) {
    return null;
  }
  return parseTikTokLiveCommand(
    content,
    user: username.isEmpty ? 'unknown' : username,
    isModerator: isTikTokLiveModerator(user, eventData: data),
    isSubscriber: isTikTokLiveSubscriber(user, eventData: data),
  );
}

String? _rawErrorMessage(Map<String, dynamic>? data) {
  if (data == null) {
    return null;
  }
  final message = _firstNonEmpty([data['message'], data['error']]);
  return message.isEmpty ? null : 'TikTok LIVE: $message';
}

String _liveEndedMessage(Map<String, dynamic>? data) {
  final message = _firstNonEmpty([
    data?['message'],
    data?['reason'],
    data?['describe'],
  ]);
  return message.isEmpty ? 'El LIVE finalizó.' : message;
}

String _firstNonEmpty(Iterable<Object?> values) {
  for (final value in values) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty) {
      return text;
    }
  }
  return '';
}

bool _boolValue(Object? value) {
  if (value is bool) {
    return value;
  }
  final normalized = value?.toString().trim().toLowerCase();
  return normalized == 'true' || normalized == '1';
}

bool? _firstKnownBool(
  Iterable<Map<String, dynamic>> candidates,
  Iterable<String> keys,
) {
  var found = false;
  for (final candidate in candidates) {
    for (final key in keys) {
      if (!candidate.containsKey(key)) {
        continue;
      }
      found = true;
      if (_boolValue(candidate[key])) {
        return true;
      }
    }
  }
  return found ? false : null;
}

Map<String, dynamic>? _mapAt(Map<String, dynamic>? map, String key) =>
    _stringKeyedMap(map?[key]);

List<Object?>? _listAt(Map<String, dynamic>? map, String key) {
  final value = map?[key];
  return value is List ? value.cast<Object?>() : null;
}

Map<String, dynamic>? _stringKeyedMap(Object? value) {
  if (value is! Map) {
    return null;
  }
  return value.map((key, item) => MapEntry(key.toString(), item));
}
