import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../../core/platform/app_platform.dart';
import 'javascript_runtime.dart';

/// CSP applied to every document hosted by the playback JavaScript runtime.
///
/// BotGuard and EJS need inline JavaScript and dynamic compilation, but they do
/// not need network, frame, worker, media, storage, or form capabilities. All
/// remote resources are fetched and validated by Dart before execution.
const youtubeJavaScriptRuntimeCsp =
    "default-src 'none'; "
    "script-src 'unsafe-inline' 'unsafe-eval'; "
    "connect-src 'none'; "
    "img-src 'none'; "
    "media-src 'none'; "
    "font-src 'none'; "
    "style-src 'none'; "
    "frame-src 'none'; "
    "child-src 'none'; "
    "worker-src 'none'; "
    "object-src 'none'; "
    "manifest-src 'none'; "
    "base-uri 'none'; "
    "form-action 'none'; "
    "navigate-to 'none'";

const youtubeJavaScriptRuntimeCspMeta =
    '<meta data-bstream-runtime-csp="true" '
    'http-equiv="Content-Security-Policy" '
    'content="$youtubeJavaScriptRuntimeCsp">';

/// Installs the runtime CSP before any script in [html].
///
/// The checked-in BotGuard harness already contains this tag, but applying the
/// policy here as well prevents a future harness or EJS caller from silently
/// creating a network-capable execution document.
@visibleForTesting
String hardenYoutubeJavaScriptDocument(String html) {
  final firstScript = RegExp(
    r'<script\b',
    caseSensitive: false,
  ).firstMatch(html)?.start;
  final existingPolicy = html.indexOf('data-bstream-runtime-csp="true"');
  if (existingPolicy >= 0) {
    if (firstScript != null && existingPolicy > firstScript) {
      throw const YoutubeJavaScriptRuntimeException(
        'The JavaScript runtime CSP must precede every script.',
      );
    }
    if (!html.contains('http-equiv="Content-Security-Policy"') ||
        !html.contains('content="$youtubeJavaScriptRuntimeCsp"')) {
      throw const YoutubeJavaScriptRuntimeException(
        'The JavaScript runtime document contains an invalid CSP marker.',
      );
    }
    return html;
  }

  final head = RegExp(
    r'<head(?:\s[^>]*)?>',
    caseSensitive: false,
  ).firstMatch(html);
  if (head != null) {
    if (firstScript != null && firstScript < head.end) {
      throw const YoutubeJavaScriptRuntimeException(
        'The JavaScript runtime document contains a script before its head.',
      );
    }
    return html.replaceRange(
      head.end,
      head.end,
      youtubeJavaScriptRuntimeCspMeta,
    );
  }

  final document = RegExp(
    r'<html(?:\s[^>]*)?>',
    caseSensitive: false,
  ).firstMatch(html);
  if (document != null) {
    if (firstScript != null && firstScript < document.end) {
      throw const YoutubeJavaScriptRuntimeException(
        'The JavaScript runtime document contains a script before its root.',
      );
    }
    return html.replaceRange(
      document.end,
      document.end,
      '<head>$youtubeJavaScriptRuntimeCspMeta</head>',
    );
  }

  return '<head>$youtubeJavaScriptRuntimeCspMeta</head>$html';
}

/// Injectable WebView boundary used to exercise lifecycle recovery in tests.
@visibleForTesting
abstract interface class HeadlessJavaScriptRuntimeBackend {
  Future<void> initialize({
    required String html,
    required Uri baseUrl,
    required AppPlatformType platform,
    required String userAgent,
    required void Function(Object cause) onRendererInvalidated,
  });

  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    required Map<String, dynamic> arguments,
  });

  Future<void> dispose();
}

@visibleForTesting
typedef HeadlessJavaScriptRuntimeBackendFactory =
    HeadlessJavaScriptRuntimeBackend Function();

/// Persistent JavaScript runtime backed by a headless system WebView.
///
/// Network access is disabled inside the WebView. YouTube and EJS resources
/// are downloaded by Dart and passed into the runtime explicitly. A renderer
/// failure or execution timeout retires the affected WebView so a later call
/// can recreate a clean document instead of reusing a stale controller.
class HeadlessInAppWebViewJavaScriptRuntime
    implements YoutubeJavaScriptRuntime {
  HeadlessInAppWebViewJavaScriptRuntime({
    AppPlatformType? platform,
    this.initializationTimeout = const Duration(seconds: 20),
    this.executionTimeout = const Duration(seconds: 20),
    this.userAgent = defaultUserAgent,
    HeadlessJavaScriptRuntimeBackendFactory? backendFactory,
  }) : platform = platform ?? AppPlatform.current,
       _backendFactory = backendFactory ?? _InAppWebViewBackend.new {
    if (initializationTimeout <= Duration.zero) {
      throw ArgumentError.value(
        initializationTimeout,
        'initializationTimeout',
        'Must be positive.',
      );
    }
    if (executionTimeout <= Duration.zero) {
      throw ArgumentError.value(
        executionTimeout,
        'executionTimeout',
        'Must be positive.',
      );
    }
  }

  static const defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/131.0.0.0 Safari/537.36';

  final AppPlatformType platform;
  final Duration initializationTimeout;
  final Duration executionTimeout;
  final String userAgent;
  final HeadlessJavaScriptRuntimeBackendFactory _backendFactory;

  HeadlessJavaScriptRuntimeBackend? _backend;
  Future<void>? _initialization;
  Future<void> _retirement = Future<void>.value();
  String? _documentHtml;
  Uri? _documentBaseUrl;
  int _generation = 0;
  bool _disposed = false;

  static bool supportsPlatform(AppPlatformType platform) =>
      platform == AppPlatformType.android ||
      platform == AppPlatformType.ios ||
      platform == AppPlatformType.windows ||
      platform == AppPlatformType.macos;

  bool get isSupported => supportsPlatform(platform);

  /// Headless execution never permits a document-initiated navigation.
  @visibleForTesting
  static bool allowsNavigation(Uri? _) => false;

  @override
  Future<void> initialize({
    String html = YoutubeJavaScriptRuntime.emptyDocument,
    Uri? baseUrl,
  }) {
    if (_disposed) {
      return Future<void>.error(
        StateError('The JavaScript runtime has been disposed.'),
      );
    }
    if (!isSupported) {
      return Future<void>.error(
        UnsupportedYoutubeJavaScriptRuntimeException(platform.name),
      );
    }
    final pending = _initialization;
    if (pending != null) {
      return pending;
    }

    // An implicit initialize after renderer retirement restores the same
    // harness and origin. Explicit initialization still wins on first use.
    final effectiveHtml =
        _documentHtml != null &&
            html == YoutubeJavaScriptRuntime.emptyDocument &&
            baseUrl == null
        ? _documentHtml!
        : hardenYoutubeJavaScriptDocument(html);
    final effectiveBaseUrl =
        baseUrl ?? _documentBaseUrl ?? Uri.parse('https://www.youtube.com/');
    _documentHtml = effectiveHtml;
    _documentBaseUrl = effectiveBaseUrl;

    late final Future<void> next;
    next = _initialize(effectiveHtml, effectiveBaseUrl);
    _initialization = next;
    unawaited(
      next.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_initialization, next)) {
            _initialization = null;
          }
        },
      ),
    );
    return next;
  }

  Future<void> _initialize(String html, Uri baseUrl) async {
    try {
      await _retirement;
    } catch (_) {
      // Disposal failure from a retired renderer must not permanently prevent
      // a fresh backend from being created.
    }
    if (_disposed) {
      throw StateError('The JavaScript runtime has been disposed.');
    }

    final backend = _backendFactory();
    final generation = ++_generation;
    _backend = backend;
    try {
      await backend
          .initialize(
            html: html,
            baseUrl: baseUrl,
            platform: platform,
            userAgent: userAgent,
            onRendererInvalidated: (cause) {
              _onRendererInvalidated(generation, cause);
            },
          )
          .timeout(initializationTimeout);
      if (!_isCurrent(generation, backend)) {
        throw const YoutubeJavaScriptRuntimeException(
          'The headless JavaScript renderer was invalidated during startup.',
        );
      }
    } catch (error, stackTrace) {
      await _retire(generation, backend);
      Error.throwWithStackTrace(
        YoutubeJavaScriptRuntimeException(
          'Could not initialize the headless JavaScript runtime.',
          cause: error,
        ),
        stackTrace,
      );
    }
  }

  void _onRendererInvalidated(int generation, Object cause) {
    final backend = _backend;
    if (backend == null || !_isCurrent(generation, backend)) {
      return;
    }
    unawaited(_retire(generation, backend));
  }

  @override
  Future<Object?> callAsyncJavaScript({
    required String functionBody,
    Map<String, dynamic> arguments = const <String, dynamic>{},
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? executionTimeout;
    if (effectiveTimeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive.');
    }

    await initialize();
    final backend = _backend;
    final generation = _generation;
    if (backend == null) {
      throw const YoutubeJavaScriptRuntimeException(
        'The headless JavaScript controller is unavailable.',
      );
    }

    CallAsyncJavaScriptResult? result;
    try {
      result = await backend
          .callAsyncJavaScript(functionBody: functionBody, arguments: arguments)
          .timeout(effectiveTimeout);
    } catch (error, stackTrace) {
      await _retire(generation, backend);
      Error.throwWithStackTrace(
        YoutubeJavaScriptRuntimeException(
          error is TimeoutException
              ? 'JavaScript execution timed out; the renderer was retired.'
              : 'JavaScript execution failed; the renderer was retired.',
          cause: error,
        ),
        stackTrace,
      );
    }

    if (!_isCurrent(generation, backend)) {
      throw const YoutubeJavaScriptRuntimeException(
        'The headless JavaScript renderer stopped during execution.',
      );
    }
    if (result == null) {
      await _retire(generation, backend);
      throw const YoutubeJavaScriptRuntimeException(
        'The JavaScript runtime returned no result.',
      );
    }
    if (result.error != null) {
      throw YoutubeJavaScriptRuntimeException(
        'JavaScript execution failed: ${result.error}',
      );
    }
    return result.value;
  }

  bool _isCurrent(int generation, HeadlessJavaScriptRuntimeBackend backend) =>
      !_disposed && generation == _generation && identical(_backend, backend);

  Future<void> _retire(
    int generation,
    HeadlessJavaScriptRuntimeBackend backend,
  ) {
    if (generation != _generation || !identical(_backend, backend)) {
      return Future<void>.value();
    }
    _generation++;
    _backend = null;
    _initialization = null;

    final previous = _retirement;
    final next = () async {
      try {
        await previous;
      } catch (_) {
        // Each backend gets its own disposal attempt.
      }
      try {
        await backend.dispose();
      } catch (_) {
        // A dead native renderer can reject disposal. Its controller is
        // already detached, so recovery may continue with a fresh backend.
      }
    }();
    _retirement = next;
    return next;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final backend = _backend;
    if (backend != null) {
      await _retire(_generation, backend);
    } else {
      try {
        await _retirement;
      } catch (_) {
        // The runtime is disposed even if the native controller already died.
      }
    }
  }
}

class _InAppWebViewBackend implements HeadlessJavaScriptRuntimeBackend {
  HeadlessInAppWebView? _webView;
  InAppWebViewController? _controller;
  void Function(Object cause)? _abortInitialization;
  bool _disposed = false;

  @override
  Future<void> initialize({
    required String html,
    required Uri baseUrl,
    required AppPlatformType platform,
    required String userAgent,
    required void Function(Object cause) onRendererInvalidated,
  }) async {
    final created = Completer<InAppWebViewController>();
    final loaded = Completer<void>();

    void rendererFailed(Object cause) {
      onRendererInvalidated(cause);
      if (!created.isCompleted) {
        created.completeError(cause);
      }
      if (!loaded.isCompleted) {
        loaded.completeError(cause);
      }
    }

    _abortInitialization = rendererFailed;

    final view = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
        data: html,
        baseUrl: WebUri(baseUrl.toString()),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        javaScriptCanOpenWindowsAutomatically: false,
        supportMultipleWindows: false,
        useShouldOverrideUrlLoading: true,
        blockNetworkLoads: true,
        cacheEnabled: false,
        databaseEnabled: false,
        domStorageEnabled: false,
        sharedCookiesEnabled: false,
        thirdPartyCookiesEnabled: false,
        saveFormData: false,
        // Android's WebView implementation clears cookies for every WebView
        // in the process when incognito is enabled, including the user's
        // authenticated account view. Windows and macOS provide a genuinely
        // private per-controller store, so use it there.
        incognito:
            platform == AppPlatformType.windows ||
            platform == AppPlatformType.ios ||
            platform == AppPlatformType.macos,
        userAgent: userAgent,
        isInspectable: kDebugMode,
      ),
      shouldOverrideUrlLoading: (_, navigationAction) async {
        final uri = navigationAction.request.url;
        return HeadlessInAppWebViewJavaScriptRuntime.allowsNavigation(uri)
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onCreateWindow: (_, _) async => false,
      onWebViewCreated: (controller) {
        if (_disposed) {
          if (!created.isCompleted) {
            created.completeError(
              StateError('The headless WebView backend was disposed.'),
            );
          }
          return;
        }
        _controller = controller;
        if (!created.isCompleted) {
          created.complete(controller);
        }
      },
      onLoadStop: (_, _) {
        if (!loaded.isCompleted) {
          loaded.complete();
        }
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame == true && !loaded.isCompleted) {
          loaded.completeError(
            YoutubeJavaScriptRuntimeException(
              'The headless document failed to load: ${error.description}',
            ),
          );
        }
      },
      onRenderProcessGone: (_, detail) {
        rendererFailed(
          YoutubeJavaScriptRuntimeException(
            'The headless JavaScript renderer stopped unexpectedly: $detail',
          ),
        );
      },
      onRenderProcessUnresponsive: (_, url) async {
        rendererFailed(
          YoutubeJavaScriptRuntimeException(
            'The headless JavaScript renderer became unresponsive at $url.',
          ),
        );
        return WebViewRenderProcessAction.TERMINATE;
      },
      onWebContentProcessDidTerminate: (_) {
        rendererFailed(
          const YoutubeJavaScriptRuntimeException(
            'The headless WebKit content process terminated unexpectedly.',
          ),
        );
      },
    );
    _webView = view;

    final ready = Future.wait<Object?>(<Future<Object?>>[
      created.future,
      loaded.future,
    ]);
    try {
      await view.run();
      await ready;
    } finally {
      if (identical(_abortInitialization, rendererFailed)) {
        _abortInitialization = null;
      }
    }
  }

  @override
  Future<CallAsyncJavaScriptResult?> callAsyncJavaScript({
    required String functionBody,
    required Map<String, dynamic> arguments,
  }) {
    final controller = _controller;
    if (_disposed || controller == null) {
      return Future<CallAsyncJavaScriptResult?>.error(
        StateError('The headless JavaScript controller is unavailable.'),
      );
    }
    return controller.callAsyncJavaScript(
      functionBody: functionBody,
      arguments: arguments,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final abortInitialization = _abortInitialization;
    _abortInitialization = null;
    abortInitialization?.call(
      StateError('The headless WebView backend was disposed.'),
    );
    final view = _webView;
    _webView = null;
    _controller = null;
    if (view != null) {
      await view.dispose();
    }
  }
}
