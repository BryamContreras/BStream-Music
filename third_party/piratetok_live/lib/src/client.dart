import 'dart:async';
import 'dart:io';

import 'auth/ttwid.dart';
import 'cancellation.dart';
import 'connection/url.dart';
import 'connection/wss.dart';
import 'errors.dart';
import 'events/types.dart';
import 'http/api.dart';
import 'http/ua.dart';

const _defaultCdn = 'webcast-ws.tiktok.com';
const _usCdn = 'webcast-ws.us.tiktok.com';
const _euCdn = 'webcast-ws.eu.tiktok.com';
const _europeanRegions = <String>{
  'AT',
  'BE',
  'BG',
  'CH',
  'CY',
  'CZ',
  'DE',
  'DK',
  'EE',
  'ES',
  'FI',
  'FR',
  'GB',
  'GR',
  'HR',
  'HU',
  'IE',
  'IS',
  'IT',
  'LI',
  'LT',
  'LU',
  'LV',
  'MT',
  'NL',
  'NO',
  'PL',
  'PT',
  'RO',
  'SE',
  'SI',
  'SK',
};

/// Ordered TikTok WebSocket hosts used for pre-upgrade transport failover.
List<String> tiktokCdnCandidates(String preferred, {String? region}) {
  final normalizedRegion = region?.trim().toUpperCase() ?? '';
  final regional = _europeanRegions.contains(normalizedRegion)
      ? _euCdn
      : _usCdn;
  return List.unmodifiable({preferred, regional, _defaultCdn, _usCdn, _euCdn});
}

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
  /// When not set, one UA from the built-in pool is kept for the complete
  /// session and rotated together with `ttwid` only after credential rejection.
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
      var sessionUserAgent = _userAgent ?? randomUa();
      final sessionLanguage = _language ?? systemLanguage();
      final sessionRegion = _region ?? systemRegion();
      var room = await _checkOnline(
        cancellationToken,
        userAgent: sessionUserAgent,
        language: sessionLanguage,
        region: sessionRegion,
      );
      lastRoom = room;
      String? sessionTtwid = room.ttwid;
      var attempt = 0;
      while (!cancellationToken.isCancelled) {
        // Keep the same UA + cookie pair for the full session. TikTok binds the
        // anonymous device cookie to that browser identity; rotating one side
        // on every retry creates intermittent handshake rejection.
        final attemptUserAgent = sessionUserAgent;
        final ttwid = sessionTtwid ??= await fetchTtwid(
          timeout: _timeout,
          proxy: _proxy,
          userAgent: attemptUserAgent,
          username: _username,
          language: sessionLanguage,
          region: sessionRegion,
          cancellationToken: cancellationToken,
        );
        if (cancellationToken.isCancelled) break;

        var credentialRejected = false;
        var receivedTraffic = false;
        final cdnHosts = tiktokCdnCandidates(_cdnHost, region: sessionRegion);
        for (var cdnIndex = 0; cdnIndex < cdnHosts.length; cdnIndex++) {
          if (cancellationToken.isCancelled) break;
          final wssUrl = buildWssUrl(
            cdnHosts[cdnIndex],
            room.roomId,
            language: sessionLanguage,
            region: sessionRegion,
          );

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
                deviceBlockCircuit.reset();
                final data = {'room_id': room.roomId};
                _emit(TikTokEvent(EventType.connected, data, room.roomId));
                _emit(
                  TikTokEvent(EventType.websocketConnected, data, room.roomId),
                );
              },
              connectTimeout: _timeout,
              staleTimeout: _staleTimeout,
              proxy: _proxy,
              userAgent: attemptUserAgent,
              cookies: _cookies,
              language: sessionLanguage,
              region: sessionRegion,
              decodedMethods: _decodedMethods,
              chatMessageFilter: _chatMessageFilter,
            );
            break;
          } on DeviceBlockedError {
            credentialRejected = true;
            if (!deviceBlockCircuit.registerFailure()) rethrow;
            break;
          } on InvalidTtwidError {
            credentialRejected = true;
            if (!deviceBlockCircuit.registerFailure()) rethrow;
            break;
          } on TimeoutException {
            if (cdnIndex == cdnHosts.length - 1) rethrow;
          } on SocketException {
            if (cdnIndex == cdnHosts.length - 1) rethrow;
          } on HandshakeException {
            if (cdnIndex == cdnHosts.length - 1) rethrow;
          }
        }

        if (cancellationToken.isCancelled) break;
        if (credentialRejected) {
          sessionTtwid = null;
          if (_userAgent == null) sessionUserAgent = randomUa();
        }

        // A successful upgrade alone does not prove that the room is still
        // producing webcast data. Reset backoff only after decoded traffic;
        // otherwise repeated upgrade/close cycles eventually re-resolve the
        // room ID instead of looping forever on a stale room.
        if (receivedTraffic) attempt = 0;
        attempt++;
        if (attempt > _maxRetries) {
          room = await _checkOnline(
            cancellationToken,
            userAgent: sessionUserAgent,
            language: sessionLanguage,
            region: sessionRegion,
          );
          lastRoom = room;
          sessionTtwid = room.ttwid ?? sessionTtwid;
          if (cancellationToken.isCancelled) break;
          attempt = 0;
        }

        final delay = credentialRejected
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

  Future<RoomIdResult> _checkOnline(
    CancellationToken cancellationToken, {
    String? userAgent,
    String? language,
    String? region,
  }) => checkOnline(
    _username,
    timeout: _timeout,
    proxy: _proxy,
    userAgent: userAgent ?? _userAgent,
    language: language ?? _language,
    region: region ?? _region,
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
