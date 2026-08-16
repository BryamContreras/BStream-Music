import 'dart:async';

import 'auth/ttwid.dart';
import 'cancellation.dart';
import 'connection/url.dart';
import 'connection/wss.dart';
import 'errors.dart';
import 'events/types.dart';
import 'http/api.dart';

const _defaultCdn = 'webcast-ws.tiktok.com';

/// Stops repeated DEVICE_BLOCKED responses from becoming an infinite,
/// battery-draining reconnect loop.
///
/// A successful WebSocket session resets the breaker. [registerFailure]
/// returns whether another retry is still allowed.
class TikTokDeviceBlockCircuitBreaker {
  TikTokDeviceBlockCircuitBreaker({required this.maxRetries}) {
    if (maxRetries < 0) {
      throw ArgumentError.value(
        maxRetries,
        'maxRetries',
        'must be non-negative',
      );
    }
  }

  final int maxRetries;
  int _failures = 0;

  int get failures => _failures;

  bool registerFailure() {
    _failures++;
    return _failures <= maxRetries;
  }

  void reset() => _failures = 0;
}

class TikTokLiveClient {
  final String _username;
  String _cdnHost = _defaultCdn;
  Duration _timeout = const Duration(seconds: 10);
  int _maxRetries = 5;
  Duration _staleTimeout = const Duration(seconds: 60);
  String _proxy = '';
  String? _userAgent;
  String? _cookies;
  String? _language;
  String? _region;
  Set<String>? _decodedMethods;
  bool Function(String message)? _chatMessageFilter;
  CancellationToken? _stop;
  final _listeners = <String, List<void Function(TikTokEvent)>>{};

  TikTokLiveClient(this._username);

  TikTokLiveClient cdnEu() {
    _cdnHost = 'webcast-ws.eu.tiktok.com';
    return this;
  }

  TikTokLiveClient cdnUs() {
    _cdnHost = 'webcast-ws.us.tiktok.com';
    return this;
  }

  TikTokLiveClient cdn(String host) {
    _cdnHost = host;
    return this;
  }

  TikTokLiveClient timeout(Duration d) {
    _timeout = d;
    return this;
  }

  TikTokLiveClient maxRetries(int n) {
    if (n < 0) {
      throw ArgumentError.value(n, 'n', 'must be non-negative');
    }
    _maxRetries = n;
    return this;
  }

  TikTokLiveClient staleTimeout(Duration d) {
    _staleTimeout = d;
    return this;
  }

  TikTokLiveClient proxy(String url) {
    _proxy = url;
    return this;
  }

  /// Override the user agent for all requests (HTTP + WSS).
  ///
  /// When not set, a random UA from the built-in pool is picked on each
  /// reconnect attempt. This is recommended for reducing DEVICE_BLOCKED risk.
  TikTokLiveClient userAgent(String ua) {
    _userAgent = ua;
    return this;
  }

  /// Set session cookies for the WSS connection.
  ///
  /// Only required for fetching room metadata on age-restricted (18+) rooms.
  /// Not required for WSS connection, event streaming, or any other functionality.
  /// Cookie format: `sessionid=xxx; sid_tt=xxx`
  TikTokLiveClient cookies(String c) {
    _cookies = c;
    return this;
  }

  /// Override the language for all requests (HTTP query params, Accept-Language header).
  ///
  /// When not set, detected from the system locale via [systemLanguage()],
  /// falling back to `'en'` if detection fails.
  TikTokLiveClient language(String lang) {
    _language = lang;
    return this;
  }

  /// Override the region for all requests (browser_language param, Accept-Language header).
  ///
  /// When not set, detected from the system locale via [systemRegion()],
  /// falling back to `'US'` if detection fails.
  TikTokLiveClient region(String reg) {
    _region = reg;
    return this;
  }

  /// Restricts protobuf decoding to the methods consumed by the application.
  ///
  /// WebSocket traffic, ACKs, stale detection, and reconnect backoff remain
  /// active for every received response; only construction of unused event
  /// maps is skipped.
  TikTokLiveClient decodedMethods(Iterable<String> methods) {
    _decodedMethods = Set.unmodifiable(
      methods
          .map((method) => method.trim())
          .where((method) => method.isNotEmpty),
    );
    return this;
  }

  /// Filters chat messages before their nested user/profile data is decoded.
  ///
  /// The predicate receives only the chat text. Omitting this filter preserves
  /// the package's default behavior and emits every decoded chat event.
  TikTokLiveClient chatMessageFilter(bool Function(String message) filter) {
    _chatMessageFilter = filter;
    return this;
  }

  /// Register an event listener for the given event type.
  void on(String eventType, void Function(TikTokEvent) handler) {
    _listeners.putIfAbsent(eventType, () => []).add(handler);
  }

  void _emit(TikTokEvent event) {
    final handlers = _listeners[event.type];
    if (handlers != null) {
      for (final fn in handlers) {
        fn(event);
      }
    }
  }

  /// Connect to TikTok Live with auto-reconnection. Returns room_id.
  Future<String> connect() async {
    _stop?.cancel();
    final cancellationToken = CancellationToken();
    _stop = cancellationToken;
    RoomIdResult? lastRoom;
    final deviceBlockCircuit = TikTokDeviceBlockCircuitBreaker(
      maxRetries: _maxRetries,
    );
    try {
      var room = await _checkOnline(cancellationToken);
      lastRoom = room;
      var attempt = 0;
      while (!cancellationToken.isCancelled) {
        final ttwid = await fetchTtwid(
          timeout: _timeout,
          proxy: _proxy,
          userAgent: _userAgent,
          cancellationToken: cancellationToken,
        );
        if (cancellationToken.isCancelled) break;
        final wssUrl = buildWssUrl(
          _cdnHost,
          room.roomId,
          language: _language,
          region: _region,
        );

        var isDeviceBlocked = false;
        var receivedTraffic = false;
        try {
          await connectWss(
            wssUrl: wssUrl,
            ttwid: ttwid,
            roomId: room.roomId,
            onEvent: (event) {
              receivedTraffic = true;
              _emit(event);
            },
            onTraffic: () => receivedTraffic = true,
            onError: (e) => _emit(TikTokEvent('error', {'error': '$e'})),
            cancellationToken: cancellationToken,
            onConnected: () {
              final data = {'room_id': room.roomId};
              _emit(TikTokEvent(EventType.connected, data, room.roomId));
              _emit(
                TikTokEvent(EventType.websocketConnected, data, room.roomId),
              );
            },
            connectTimeout: _timeout,
            staleTimeout: _staleTimeout,
            proxy: _proxy,
            userAgent: _userAgent,
            cookies: _cookies,
            language: _language,
            region: _region,
            decodedMethods: _decodedMethods,
            chatMessageFilter: _chatMessageFilter,
          );
          deviceBlockCircuit.reset();
        } on DeviceBlockedError {
          isDeviceBlocked = true;
          if (!deviceBlockCircuit.registerFailure()) {
            rethrow;
          }
        }

        if (cancellationToken.isCancelled) break;

        // A successful upgrade alone does not prove that the room is still
        // producing webcast data. Reset backoff only after decoded traffic;
        // otherwise repeated upgrade/close cycles eventually re-resolve the
        // room ID instead of looping forever on a stale room.
        if (receivedTraffic) attempt = 0;
        attempt++;
        if (attempt > _maxRetries) {
          room = await _checkOnline(cancellationToken);
          lastRoom = room;
          if (cancellationToken.isCancelled) break;
          attempt = 0;
        }

        final delay = isDeviceBlocked
            ? 2
            : _backoffSeconds(attempt).clamp(2, 30);
        _emit(
          TikTokEvent(EventType.reconnecting, {
            'attempt': attempt,
            'max_retries': _maxRetries,
            'delay': delay,
          }, room.roomId),
        );
        final stopped = await _waitOrStop(
          Duration(seconds: delay),
          cancellationToken,
        );
        if (stopped) break;
      }

      return room.roomId;
    } finally {
      if (lastRoom != null) {
        _emit(TikTokEvent(EventType.disconnected, null, lastRoom.roomId));
      }
      if (identical(_stop, cancellationToken)) {
        _stop = null;
      }
    }
  }

  /// Clean disconnect — exits the reconnect loop.
  void disconnect() {
    _stop?.cancel();
  }

  Future<RoomIdResult> _checkOnline(CancellationToken cancellationToken) =>
      checkOnline(
        _username,
        timeout: _timeout,
        proxy: _proxy,
        userAgent: _userAgent,
        language: _language,
        region: _region,
        cancellationToken: cancellationToken,
      );

  Future<bool> _waitOrStop(
    Duration delay,
    CancellationToken cancellationToken,
  ) async {
    if (cancellationToken.isCancelled) return true;
    final timer = Completer<void>();
    final handle = Timer(delay, timer.complete);
    final cancellation = Completer<void>();
    final subscription = cancellationToken.onCancel.listen((_) {
      if (!cancellation.isCompleted) cancellation.complete();
    });
    try {
      if (cancellationToken.isCancelled && !cancellation.isCompleted) {
        cancellation.complete();
      }
      await Future.any<void>([cancellation.future, timer.future]);
      return cancellationToken.isCancelled;
    } finally {
      handle.cancel();
      await subscription.cancel();
    }
  }

  static int _backoffSeconds(int attempt) => 1 << attempt; // 2,4,8,16,...
}
