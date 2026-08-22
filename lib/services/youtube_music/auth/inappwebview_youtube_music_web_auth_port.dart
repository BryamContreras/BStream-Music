import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'youtube_music_auth_models.dart';
import 'youtube_music_cookie_codec.dart';
import 'youtube_music_navigation_policy.dart';
import 'youtube_music_web_auth_port.dart';

class InAppWebViewYouTubeMusicWebAuthPort implements YouTubeMusicWebAuthPort {
  InAppWebViewYouTubeMusicWebAuthPort({
    this.cookieCodec = const YouTubeMusicCookieCodec(),
    this.navigationPolicy = const YouTubeMusicNavigationPolicy(),
    this.cookieManager,
    this.webStorageManager,
    this.authenticationCookieCleaner,
    this.webStorageCleaner,
    this.cacheCleaner,
  });

  static final WebUri musicUrl = WebUri('https://music.youtube.com/');
  static final List<WebUri> _authenticationCookieUrls = <WebUri>[
    WebUri('https://accounts.google.com/'),
    WebUri('https://consent.google.com/'),
    WebUri('https://accounts.youtube.com/'),
    WebUri('https://consent.youtube.com/'),
    WebUri('https://www.youtube.com/'),
    WebUri('https://youtube.com/'),
    musicUrl,
  ];

  static const String _configurationScript = r'''
(() => {
  const read = (name) => {
    try {
      if (window.ytcfg && typeof window.ytcfg.get === 'function') {
        const value = window.ytcfg.get(name);
        if (value !== undefined && value !== null) return value;
      }
    } catch (_) {}
    try {
      if (window.yt && window.yt.config_) return window.yt.config_[name];
    } catch (_) {}
    return null;
  };
  const context = read('INNERTUBE_CONTEXT');
  const client = context && context.client ? context.client : {};
  return JSON.stringify({
    visitorData: read('VISITOR_DATA') ?? client.visitorData,
    dataSyncId: read('DATASYNC_ID'),
    authUser: String(read('SESSION_INDEX') ?? '0'),
    delegatedPageId: read('DELEGATED_SESSION_ID'),
    apiKey: read('INNERTUBE_API_KEY'),
    clientVersion: read('INNERTUBE_CLIENT_VERSION') ?? client.clientVersion,
    clientName: read('INNERTUBE_CLIENT_NAME') ?? client.clientName
  });
})()
''';

  final YouTubeMusicCookieCodec cookieCodec;
  final YouTubeMusicNavigationPolicy navigationPolicy;
  final CookieManager? cookieManager;
  final WebStorageManager? webStorageManager;
  final Future<bool> Function()? authenticationCookieCleaner;
  final Future<void> Function()? webStorageCleaner;
  final Future<void> Function()? cacheCleaner;
  InAppWebViewController? _controller;
  Future<void>? _prepareInFlight;
  Future<YouTubeMusicWebCleanupResult>? _cleanupInFlight;
  bool _sessionClosed = false;
  bool _cleanupCompleted = false;

  void attachController(InAppWebViewController controller) {
    if (_sessionClosed) {
      throw StateError('The YouTube Music WebView session is closed.');
    }
    _controller = controller;
  }

  @override
  Future<void> prepare() async {
    _ensureActive();
    final existing = _prepareInFlight;
    if (existing != null) return existing;

    final operation = _preparePrivateSession();
    _prepareInFlight = operation;
    try {
      await operation;
    } finally {
      if (identical(_prepareInFlight, operation)) _prepareInFlight = null;
    }
  }

  Future<void> _preparePrivateSession() async {
    // Android's cookie jar is app-global. Login sessions are serialized and
    // begin by deleting only Google/YouTube cookies visible to BStream's
    // WebView profile. Browser and system cookies are not touched.
    final result = await _clearPrivateBrowserData();
    // Cookies are the authentication boundary. DOM storage and cache are
    // best-effort on Android/WebView2 and are retried during cleanup; they
    // must not make a valid fresh login impossible.
    if (!result.cookiesCleared) {
      throw const YouTubeMusicWebAuthException(
        'No se pudieron limpiar las cookies de la sesión anterior de '
        'YouTube Music.',
      );
    }
  }

  @override
  Future<YouTubeMusicWebAuthData> waitForAuthenticatedSession({
    int maximumAttempts = 20,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    if (maximumAttempts <= 0 || retryDelay.isNegative) {
      throw ArgumentError('Invalid WebView authentication retry policy.');
    }
    final controller = _requireController();
    for (var attempt = 0; attempt < maximumAttempts; attempt++) {
      final currentUrl = await controller.getUrl();
      final currentUri = currentUrl == null
          ? null
          : Uri.tryParse(currentUrl.toString());
      if (navigationPolicy.isYouTubeMusicDocument(currentUri)) {
        final authData = await _tryReadAuthData(controller);
        if (authData != null) return authData;
      }
      if (attempt + 1 < maximumAttempts) await Future<void>.delayed(retryDelay);
    }
    throw const YouTubeMusicWebAuthException(
      'No se pudo verificar una sesión completa de YouTube Music.',
    );
  }

  Future<YouTubeMusicWebAuthData?> _tryReadAuthData(
    InAppWebViewController controller,
  ) async {
    try {
      final configResult = await controller.evaluateJavascript(
        source: _configurationScript,
      );
      final config = _decodeConfiguration(configResult);
      final visitorData = _nonEmptyString(config['visitorData']);
      final authUser = _nonEmptyString(config['authUser']);
      final apiKey = _nonEmptyString(config['apiKey']);
      final clientVersion = _nonEmptyString(config['clientVersion']);
      final clientName = _nonEmptyString(config['clientName']);
      if (visitorData == null ||
          authUser == null ||
          apiKey == null ||
          clientVersion == null ||
          clientName == null) {
        return null;
      }

      final cookies = await _effectiveCookieManager.getCookies(
        url: musicUrl,
        webViewController: controller,
      );
      final values = <String, String>{};
      for (final cookie in cookies) {
        if (!_isYouTubeDomain(cookie.domain)) continue;
        final value = cookie.value?.toString();
        if (value == null || value.isEmpty) continue;
        final previous = values[cookie.name];
        if (previous != null && previous != value) {
          throw const FormatException('Ambiguous YouTube Music cookie.');
        }
        if (_isSigningCookie(cookie.name) && cookie.isSecure == false) {
          throw const FormatException('Insecure YouTube Music cookie.');
        }
        values[cookie.name] = value;
      }
      if (!cookieCodec.hasSigningCookie(values)) return null;
      final cookieHeader = cookieCodec.encode(values);
      final identity = YouTubeMusicAuthIdentity.fromJson(<String, Object?>{
        'visitorData': visitorData,
        'authUser': authUser,
        'dataSyncId': _nonEmptyString(config['dataSyncId']),
        'delegatedPageId': _nonEmptyString(config['delegatedPageId']),
      });
      return YouTubeMusicWebAuthData(
        cookieHeader: cookieHeader,
        identity: identity,
        apiKey: apiKey,
        clientVersion: clientVersion,
        clientName: clientName,
      );
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> _decodeConfiguration(Object? raw) {
    Object? decoded = raw;
    for (var depth = 0; depth < 2 && decoded is String; depth++) {
      try {
        decoded = jsonDecode(decoded);
      } on Object {
        break;
      }
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    throw const FormatException('Invalid YouTube Music page configuration.');
  }

  String? _nonEmptyString(Object? value) {
    if (value == null) return null;
    final normalized = value.toString().trim();
    return normalized.isEmpty ? null : normalized;
  }

  bool _isSigningCookie(String name) =>
      name == 'SAPISID' ||
      name == '__Secure-1PAPISID' ||
      name == '__Secure-3PAPISID';

  bool _isYouTubeDomain(String? domain) {
    if (domain == null || domain.isEmpty) return true;
    final normalized = domain.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    return normalized == 'youtube.com' || normalized == 'music.youtube.com';
  }

  @override
  Future<void> navigate(Uri uri) async {
    _ensureActive();
    if (navigationPolicy.evaluate(uri, isMainFrame: true) !=
        YouTubeMusicNavigationDecision.allow) {
      throw const YouTubeMusicWebAuthException(
        'YouTube Music intentó abrir una dirección no permitida.',
      );
    }
    await _requireController().loadUrl(
      urlRequest: URLRequest(url: WebUri(uri.toString())),
    );
  }

  @override
  Future<bool> canGoBack() => _requireController().canGoBack();

  @override
  Future<void> goBack() => _requireController().goBack();

  @override
  Future<YouTubeMusicWebCleanupResult> cleanup() {
    if (_cleanupCompleted) {
      return Future<YouTubeMusicWebCleanupResult>.value(
        const YouTubeMusicWebCleanupResult(
          cookiesCleared: true,
          webStorageCleared: true,
          cacheCleared: true,
        ),
      );
    }
    final existing = _cleanupInFlight;
    if (existing != null) return existing;

    // Prevent any new navigation or controller attachment before the first
    // asynchronous cleanup operation yields.
    _sessionClosed = true;
    final operation = _cleanupWebSession();
    _cleanupInFlight = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_cleanupInFlight, operation)) _cleanupInFlight = null;
      }),
    );
    return operation;
  }

  Future<YouTubeMusicWebCleanupResult> _cleanupWebSession() async {
    final preparing = _prepareInFlight;
    if (preparing != null) {
      try {
        await preparing;
      } on Object {
        // The pass below remains authoritative when preparation failed.
      }
    }

    final controller = _controller;
    if (controller != null) {
      await _bestEffort(controller.stopLoading);
      await _bestEffort(controller.clearHistory);
      await _bestEffort(controller.clearFormData);
    }
    _controller = null;

    // Retry every store after a partial failure. The platform view may still
    // have been shutting down during the earlier pass, so retaining a partial
    // success result could report a false clean session.
    final result = await _clearPrivateBrowserData();
    _cleanupCompleted = result.completed;
    return result;
  }

  Future<YouTubeMusicWebCleanupResult> _clearPrivateBrowserData() async {
    final cookiesCleared = await _bestEffortBool(
      authenticationCookieCleaner ?? _clearAuthenticationCookies,
    );
    final webStorageCleared = await _bestEffortResult(
      webStorageCleaner ??
          (webStorageManager ?? WebStorageManager.instance()).deleteAllData,
    );
    final cacheCleared = await _bestEffortResult(
      cacheCleaner ?? InAppWebViewController.clearAllCache,
    );
    return YouTubeMusicWebCleanupResult(
      cookiesCleared: cookiesCleared,
      webStorageCleared: webStorageCleared,
      cacheCleared: cacheCleared,
    );
  }

  InAppWebViewController _requireController() {
    _ensureActive();
    final controller = _controller;
    if (controller == null) {
      throw StateError('The YouTube Music WebView is not attached.');
    }
    return controller;
  }

  void _ensureActive() {
    if (_sessionClosed) {
      throw StateError('The YouTube Music WebView session is closed.');
    }
  }

  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      // Cleanup is retried by the caller and must never leak plugin errors or
      // credential-bearing platform diagnostics into the UI/logs.
    }
  }

  Future<bool> _bestEffortResult(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _bestEffortBool(Future<bool> Function() action) async {
    try {
      return await action();
    } on Object {
      return false;
    }
  }

  Future<bool> _clearAuthenticationCookies() async {
    try {
      final cookieManager = _effectiveCookieManager;
      // On Android this is the same app-scoped WebView jar used by the login
      // page. On Windows the manager belongs to the dedicated per-login
      // WebView2 profile. Both OpenTune and Metrolist use the platform-wide
      // deletion primitive because it is more reliable than deleting cookies
      // one by one (especially HttpOnly/domain cookies).
      try {
        if (await cookieManager.deleteAllCookies()) {
          return true;
        }
      } on Object {
        // Some plugin/platform versions do not implement this primitive;
        // retain the exact-origin fallback below.
      }

      // Android shares a WebView cookie jar inside the app. Avoid the global
      // deleteAllCookies API when it is unavailable so unrelated embedded
      // sessions stay untouched; system browsers use a different profile and
      // are never affected.
      for (final url in _authenticationCookieUrls) {
        final cookies = await cookieManager.getCookies(url: url);
        for (final cookie in cookies) {
          await cookieManager.deleteCookie(
            url: url,
            name: cookie.name,
            path: cookie.path ?? '/',
            domain: cookie.domain,
          );
        }
      }

      // Platform deletion booleans differ when a cookie disappears
      // concurrently. Read-back from every trusted origin is authoritative.
      for (final url in _authenticationCookieUrls) {
        if ((await cookieManager.getCookies(url: url)).isNotEmpty) {
          return false;
        }
      }
      return true;
    } on Object {
      return false;
    }
  }

  CookieManager get _effectiveCookieManager =>
      cookieManager ?? CookieManager.instance();
}
