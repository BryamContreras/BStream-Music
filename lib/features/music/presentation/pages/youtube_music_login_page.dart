import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../../../../services/youtube_music/auth/inappwebview_youtube_music_web_auth_port.dart';
import '../../../../services/youtube_music/auth/youtube_music_navigation_policy.dart';
import '../../../../services/youtube_music/auth/youtube_music_web_auth_port.dart';
import '../providers/youtube_music_auth_controller.dart';
import '../widgets/youtube_music_channel_picker_dialog.dart';

enum YouTubeMusicLoginMechanism { embeddedWebView, desktopBrowser, unsupported }

YouTubeMusicLoginMechanism resolveYouTubeMusicLoginMechanism({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return YouTubeMusicLoginMechanism.unsupported;
  return switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.macOS => YouTubeMusicLoginMechanism.embeddedWebView,
    TargetPlatform.windows ||
    TargetPlatform.linux => YouTubeMusicLoginMechanism.desktopBrowser,
    _ => YouTubeMusicLoginMechanism.unsupported,
  };
}

bool get isYouTubeMusicWebLoginSupported =>
    !kIsWeb && isEmbeddedYouTubeMusicWebLoginSupportedOn(defaultTargetPlatform);

@visibleForTesting
bool isEmbeddedYouTubeMusicWebLoginSupportedOn(TargetPlatform platform) =>
    platform == TargetPlatform.android ||
    platform == TargetPlatform.windows ||
    platform == TargetPlatform.macOS;

Future<void> _noOpCleanup() async {}

/// Isolated account page. It exposes no JavaScript bridge and only accepts
/// exact HTTPS Google/YouTube Music main-frame hosts.
class YouTubeMusicLoginPage extends ConsumerStatefulWidget {
  const YouTubeMusicLoginPage({super.key, this.webAuthPort});

  final InAppWebViewYouTubeMusicWebAuthPort? webAuthPort;

  static final WebUri initialLoginUrl = WebUri(
    'https://accounts.google.com/ServiceLogin?service=youtube&continue='
    'https%3A%2F%2Fmusic.youtube.com%2F',
  );

  static InAppWebViewSettings secureWebViewSettings({
    TargetPlatform? platform,
  }) {
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      javaScriptCanOpenWindowsAutomatically: false,
      useShouldOverrideUrlLoading: true,
      // Windows already receives a brand-new WebView2 user-data directory for
      // each login. InPrivate would create a second cookie profile while the
      // stable plugin's CookieManager reads the first one, making the completed
      // Google session invisible. Android keeps its existing private WebView.
      incognito: resolvedPlatform != TargetPlatform.windows,
      cacheEnabled: false,
      allowFileAccess: false,
      allowContentAccess: false,
      allowFileAccessFromFileURLs: false,
      allowUniversalAccessFromFileURLs: false,
      domStorageEnabled: true,
      databaseEnabled: false,
      safeBrowsingEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
      saveFormData: false,
      supportMultipleWindows: false,
      thirdPartyCookiesEnabled: true,
      isInspectable: false,
    );
  }

  @override
  ConsumerState<YouTubeMusicLoginPage> createState() =>
      _YouTubeMusicLoginPageState();
}

class _YouTubeMusicLoginPageState extends ConsumerState<YouTubeMusicLoginPage> {
  late InAppWebViewYouTubeMusicWebAuthPort _webAuthPort;
  var _webAuthPortInitialized = false;
  WebViewEnvironment? _webViewEnvironment;
  String? _windowsWebViewDataRoot;
  String? _windowsWebViewSessionDirectory;
  Future<YouTubeMusicWebCleanupResult>? _cleanupFuture;
  Future<void>? _cleanupRecoveryFuture;
  YouTubeMusicWebCleanupResult? _verifiedCleanup;
  var _prepared = false;
  var _preparing = false;
  var _busy = false;
  var _tearingDown = false;
  var _allowPop = false;
  var _safeRedirectInFlight = false;
  String _visibleHost = 'accounts.google.com';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final injectedPort = widget.webAuthPort;
    if (injectedPort != null) {
      _webAuthPort = injectedPort;
      _webAuthPortInitialized = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(youtubeMusicAuthControllerProvider.notifier).beginLogin();
      unawaited(_prepare());
    });
  }

  Future<void> _prepare() async {
    if (!isYouTubeMusicWebLoginSupported || _preparing || _tearingDown) return;
    setState(() {
      _preparing = true;
      _prepared = false;
      _errorMessage = null;
    });
    try {
      if (!_webAuthPortInitialized) {
        CookieManager? cookieManager;
        if (defaultTargetPlatform == TargetPlatform.windows) {
          final availableVersion =
              await WebViewEnvironment.getAvailableVersion();
          if (availableVersion == null) {
            throw const YouTubeMusicWebAuthException(
              'Microsoft WebView2 no está instalado en este equipo.',
            );
          }
          final supportDirectory = await getApplicationSupportDirectory();
          final dataRoot = Directory(
            path.join(
              supportDirectory.path,
              'youtube_music_auth_webview2_sessions',
            ),
          );
          await dataRoot.create(recursive: true);
          final sessionDirectory = await dataRoot.createTemp('session_');
          _windowsWebViewDataRoot = dataRoot.absolute.path;
          _windowsWebViewSessionDirectory = sessionDirectory.absolute.path;
          WebViewEnvironment environment;
          try {
            environment = await WebViewEnvironment.create(
              settings: WebViewEnvironmentSettings(
                userDataFolder: sessionDirectory.path,
                allowSingleSignOnUsingOSPrimaryAccount: false,
              ),
            );
          } on Object {
            await _deleteWindowsWebViewSessionDirectory();
            rethrow;
          }
          _webViewEnvironment = environment;
          try {
            cookieManager = CookieManager.instance(
              webViewEnvironment: environment,
            );
          } on Object {
            await _disposeWebViewEnvironment();
            rethrow;
          }
        }
        _webAuthPort = InAppWebViewYouTubeMusicWebAuthPort(
          cookieManager: cookieManager,
          // Each Windows login gets a brand-new WebView2 profile. There is no
          // prior cookie jar to clear before the controller is attached; the
          // profile directory itself is the isolation/cleanup boundary.
          authenticationCookieCleaner:
              defaultTargetPlatform == TargetPlatform.windows
              ? () async => true
              : null,
          // WebStorageManager.deleteAllData and clearAllCache are not
          // implemented by flutter_inappwebview_windows 0.6. The Windows
          // surface instead uses an InPrivate controller in a brand-new,
          // single-login WebView2 data directory. Deleting that directory
          // after disposing its environment is the stronger cleanup boundary.
          webStorageCleaner: defaultTargetPlatform == TargetPlatform.windows
              ? _noOpCleanup
              : null,
          cacheCleaner: defaultTargetPlatform == TargetPlatform.windows
              ? _noOpCleanup
              : null,
        );
        _webAuthPortInitialized = true;
      }
      await _webAuthPort.prepare();
      if (!mounted || _tearingDown) return;
      setState(() {
        _prepared = true;
        _preparing = false;
      });
    } on YouTubeMusicWebAuthException catch (error) {
      if (!mounted || _tearingDown) return;
      setState(() {
        _preparing = false;
        _errorMessage = error.message;
      });
    } on Object {
      if (!mounted || _tearingDown) return;
      setState(() {
        _preparing = false;
        _errorMessage =
            'No se pudo preparar una sesión privada para iniciar sesión.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(youtubeMusicAuthControllerProvider);
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_handleBack());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('youtube-music-login-close'),
            tooltip: 'Cerrar',
            onPressed: _busy || _tearingDown ? null : _close,
            icon: const Icon(Icons.close),
          ),
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('Iniciar sesión', maxLines: 1),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.lock_outline, size: 13),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _visibleHost,
                      key: const Key('youtube-music-visible-host'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        body: _buildBody(authState),
      ),
    );
  }

  Widget _buildBody(YouTubeMusicAuthState authState) {
    if (!isYouTubeMusicWebLoginSupported) {
      return const _LoginStatusView(
        icon: Icons.desktop_windows_outlined,
        message:
            'El inicio de sesión integrado está disponible en Android, '
            'Windows y macOS. '
            'Puedes seguir usando BStream sin una cuenta.',
      );
    }
    if (_tearingDown) {
      return _LoginStatusView(
        icon: Icons.cleaning_services_outlined,
        message: 'Cerrando y limpiando la sesión temporal…',
        showProgress: true,
      );
    }
    final error = _errorMessage ?? authState.message;
    if (error != null) {
      return _LoginStatusView(
        icon: Icons.error_outline,
        message: error,
        actionLabel: _prepared ? 'Volver a intentar' : 'Reintentar preparación',
        onAction: _prepared ? _retryAuthentication : _prepare,
      );
    }
    if (!_prepared) {
      return const _LoginStatusView(
        icon: Icons.security_outlined,
        message: 'Preparando una sesión privada…',
        showProgress: true,
      );
    }
    return Stack(
      children: <Widget>[
        InAppWebView(
          key: const Key('youtube-music-login-webview'),
          webViewEnvironment: _webViewEnvironment,
          initialUrlRequest: URLRequest(
            url: YouTubeMusicLoginPage.initialLoginUrl,
          ),
          initialSettings: YouTubeMusicLoginPage.secureWebViewSettings(),
          onWebViewCreated: _webAuthPort.attachController,
          shouldOverrideUrlLoading: _shouldOverrideNavigation,
          onLoadStart: (controller, url) {
            _logNavigation('load-start', url);
            _publishVisibleUrl(url);
          },
          onLoadStop: (controller, url) {
            _logNavigation('load-stop', url);
            _publishVisibleUrl(url);
            final uri = url == null ? null : Uri.tryParse(url.toString());
            if (_webAuthPort.navigationPolicy.isYouTubeAuthDocument(uri)) {
              unawaited(_completeAuthentication());
            }
          },
          onCreateWindow: (controller, action) async => false,
          onPermissionRequest: (controller, request) async =>
              PermissionResponse(
                action: PermissionResponseAction.DENY,
                resources: request.resources,
              ),
          onReceivedServerTrustAuthRequest: (controller, challenge) async =>
              ServerTrustAuthResponse(
                action: ServerTrustAuthResponseAction.CANCEL,
              ),
          onReceivedHttpAuthRequest: (controller, challenge) async =>
              HttpAuthResponse(action: HttpAuthResponseAction.CANCEL),
          onReceivedClientCertRequest: (controller, challenge) async =>
              ClientCertResponse(
                certificatePath: '',
                action: ClientCertResponseAction.CANCEL,
              ),
        ),
        if (_busy)
          const ColoredBox(
            color: Color(0x66000000),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );
  }

  Future<NavigationActionPolicy> _shouldOverrideNavigation(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final rawUrl = action.request.url;
    final uri = rawUrl == null ? null : Uri.tryParse(rawUrl.toString());
    if (action.isForMainFrame) {
      final policy = _webAuthPort.navigationPolicy;
      if (policy.safeIntentDestination(rawUrl?.toString()) != null ||
          policy.isSafeAuthContinuation(uri)) {
        final destination = policy.safeIntentDestination(rawUrl?.toString());
        _logNavigation(
          'handoff',
          destination ?? uri,
          decision: 'redirect-to-music',
        );
        unawaited(_resumeAfterGoogleHandOff(controller));
        return NavigationActionPolicy.CANCEL;
      }
    }
    final decision = _webAuthPort.navigationPolicy.evaluate(
      uri,
      isMainFrame: action.isForMainFrame,
    );
    if (kDebugMode && action.isForMainFrame && uri != null) {
      debugPrint(
        'YouTube Music login navigation: ${uri.scheme}://${uri.host}${uri.path} '
        '-> ${decision.name}',
      );
    }
    if (decision == YouTubeMusicNavigationDecision.cancel &&
        action.isForMainFrame &&
        mounted) {
      setState(() {
        _errorMessage =
            'Se bloqueó una dirección que no pertenece al acceso permitido '
            'de Google o YouTube Music.';
      });
    }
    return decision == YouTubeMusicNavigationDecision.allow
        ? NavigationActionPolicy.ALLOW
        : NavigationActionPolicy.CANCEL;
  }

  Future<void> _resumeAfterGoogleHandOff(
    InAppWebViewController controller,
  ) async {
    if (_safeRedirectInFlight || !mounted || _tearingDown) return;
    _safeRedirectInFlight = true;
    try {
      if (mounted) setState(() => _errorMessage = null);
      await controller.loadUrl(
        urlRequest: URLRequest(
          url: InAppWebViewYouTubeMusicWebAuthPort.musicUrl,
        ),
      );
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage =
              'No se pudo volver a YouTube Music después de la verificación.';
        });
      }
    } finally {
      _safeRedirectInFlight = false;
    }
  }

  void _publishVisibleUrl(WebUri? value) {
    final uri = value == null ? null : Uri.tryParse(value.toString());
    if (uri == null ||
        _webAuthPort.navigationPolicy.evaluate(uri, isMainFrame: true) !=
            YouTubeMusicNavigationDecision.allow ||
        !mounted) {
      return;
    }
    setState(() {
      _visibleHost = uri.host.toLowerCase();
      _errorMessage = null;
    });
  }

  void _logNavigation(String phase, Object? value, {String? decision}) {
    if (!kDebugMode || value == null) return;
    final uri = Uri.tryParse(value.toString());
    if (uri == null) return;
    debugPrint(
      'YouTube Music login $phase: ${uri.scheme}://${uri.host}${uri.path}'
      '${decision == null ? '' : ' -> $decision'}',
    );
  }

  Future<void> _completeAuthentication() async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final authData = await _webAuthPort.waitForAuthenticatedSession();
      await ref
          .read(youtubeMusicAuthControllerProvider.notifier)
          .submitWebAuthentication(authData);
      if (!mounted) return;
      var authState = ref.read(youtubeMusicAuthControllerProvider);
      if (authState.phase == YouTubeMusicAuthPhase.selectingChannel) {
        final channel = await YouTubeMusicChannelPickerDialog.show(
          context,
          authState.channels,
        );
        if (!mounted) return;
        if (channel == null) {
          setState(() {
            _errorMessage = 'Selecciona un canal para continuar.';
          });
          return;
        }
        final nextUrl = await ref
            .read(youtubeMusicAuthControllerProvider.notifier)
            .chooseChannel(channel);
        if (!mounted) return;
        if (nextUrl != null) {
          await _webAuthPort.navigate(nextUrl);
          return;
        }
        authState = ref.read(youtubeMusicAuthControllerProvider);
      }
      if (authState.isAuthenticated) {
        await _finishAndPop(true);
        return;
      }
      if (authState.phase == YouTubeMusicAuthPhase.error) {
        setState(() => _errorMessage = authState.message);
      }
    } on YouTubeMusicWebAuthException catch (error) {
      if (kDebugMode) {
        debugPrint(
          'YouTube Music auth completion failed: ${error.runtimeType}',
        );
      }
      if (mounted) setState(() => _errorMessage = error.message);
    } on Object {
      if (kDebugMode) {
        debugPrint('YouTube Music auth completion failed: unknown-error');
      }
      if (mounted) {
        setState(() {
          _errorMessage =
              'No se pudo completar el inicio de sesión de forma segura.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _retryAuthentication() {
    ref.read(youtubeMusicAuthControllerProvider.notifier).beginLogin();
    setState(() => _errorMessage = null);
    unawaited(
      _webAuthPort.navigate(
        Uri.parse(YouTubeMusicLoginPage.initialLoginUrl.toString()),
      ),
    );
  }

  Future<void> _handleBack() async {
    if (_busy) return;
    if (_tearingDown) return;
    try {
      if (_prepared && await _webAuthPort.canGoBack()) {
        await _webAuthPort.goBack();
        return;
      }
    } on Object {
      // A closed platform view falls through to a normal cancel.
    }
    await _close();
  }

  Future<void> _close() async {
    ref.read(youtubeMusicAuthControllerProvider.notifier).cancelLogin();
    await _finishAndPop(false);
  }

  Future<void> _finishAndPop(bool result) async {
    if (_tearingDown) return;
    if (mounted) {
      setState(() {
        _tearingDown = true;
        _busy = true;
        _errorMessage = null;
      });
      // Let Flutter detach the platform view before asking WebView2 to close
      // its environment and release the private data directory.
      await WidgetsBinding.instance.endOfFrame;
    }

    final cleanup = await _cleanup().timeout(
      const Duration(seconds: 3),
      onTimeout: () => const YouTubeMusicWebCleanupResult(
        cookiesCleared: false,
        webStorageCleared: false,
        cacheCleared: false,
      ),
    );
    if (!mounted) return;
    if (!cleanup.completed) {
      // Never trap the user in the login route because a platform WebView
      // store is temporarily locked. The session is already closed; retry
      // cleanup after the route is gone and dispose the private profile when
      // the platform releases its handles.
      unawaited(_ensureCleanupRecovery());
    }
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  Future<YouTubeMusicWebCleanupResult> _cleanup() async {
    final verified = _verifiedCleanup;
    if (verified != null) return verified;
    final existing = _cleanupFuture;
    if (existing != null) return existing;
    final operation = _cleanupWebSession();
    _cleanupFuture = operation;
    try {
      final result = await operation;
      if (result.completed) _verifiedCleanup = result;
      return result;
    } finally {
      if (identical(_cleanupFuture, operation)) _cleanupFuture = null;
    }
  }

  Future<YouTubeMusicWebCleanupResult> _cleanupWebSession() async {
    var result = const YouTubeMusicWebCleanupResult(
      cookiesCleared: true,
      webStorageCleared: true,
      cacheCleared: true,
    );
    if (_webAuthPortInitialized) {
      try {
        result = await _webAuthPort.cleanup();
      } on Object {
        result = const YouTubeMusicWebCleanupResult(
          cookiesCleared: false,
          webStorageCleared: false,
          cacheCleared: false,
        );
      }
    }

    final ownsWindowsProfile =
        _webViewEnvironment != null || _windowsWebViewSessionDirectory != null;
    if (defaultTargetPlatform == TargetPlatform.windows && ownsWindowsProfile) {
      final profileDeleted = await _disposeWebViewEnvironment();
      // The whole per-login WebView2 profile is the read-back boundary on
      // Windows. It covers cookies, DOM storage and cache together.
      return YouTubeMusicWebCleanupResult(
        cookiesCleared: profileDeleted,
        webStorageCleared: profileDeleted,
        cacheCleared: profileDeleted,
      );
    }
    return result;
  }

  Future<bool> _deleteWindowsWebViewSessionDirectory() async {
    final rootValue = _windowsWebViewDataRoot;
    final sessionValue = _windowsWebViewSessionDirectory;
    if (rootValue == null && sessionValue == null) return true;
    if (rootValue == null || sessionValue == null) return false;

    final root = path.normalize(path.absolute(rootValue));
    final session = path.normalize(path.absolute(sessionValue));
    if (!path.isWithin(root, session) ||
        !path.basename(session).startsWith('session_')) {
      return false;
    }

    try {
      final type = await FileSystemEntity.type(session, followLinks: false);
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(session).delete(recursive: true);
        case FileSystemEntityType.link:
          await Link(session).delete();
        case FileSystemEntityType.file:
          await File(session).delete();
        case FileSystemEntityType.notFound:
          break;
        default:
          return false;
      }
      if (await FileSystemEntity.type(session, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      _windowsWebViewSessionDirectory = null;
      _windowsWebViewDataRoot = null;
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _disposeWebViewEnvironment() async {
    final environment = _webViewEnvironment;
    if (environment != null) {
      try {
        await environment.dispose();
        _webViewEnvironment = null;
      } on Object {
        return false;
      }
    }
    return _deleteWindowsWebViewSessionDirectory();
  }

  Future<void> _cleanupBeforeEnvironmentDispose() async {
    var result = await _cleanup();
    for (var attempt = 1; attempt < 3 && !result.completed; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      result = await _cleanup();
    }
    if (_webViewEnvironment != null ||
        _windowsWebViewSessionDirectory != null) {
      await _disposeWebViewEnvironment();
    }
  }

  Future<void> _ensureCleanupRecovery() {
    final existing = _cleanupRecoveryFuture;
    if (existing != null) return existing;
    final operation = _cleanupBeforeEnvironmentDispose();
    _cleanupRecoveryFuture = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_cleanupRecoveryFuture, operation)) {
          _cleanupRecoveryFuture = null;
        }
      }),
    );
    return operation;
  }

  @override
  void dispose() {
    unawaited(_ensureCleanupRecovery());
    super.dispose();
  }
}

class _LoginStatusView extends StatelessWidget {
  const _LoginStatusView({
    required this.icon,
    required this.message,
    this.showProgress = false,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String message;
  final bool showProgress;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 44),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              if (showProgress) ...<Widget>[
                const SizedBox(height: 20),
                const CircularProgressIndicator(),
              ],
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: 20),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
