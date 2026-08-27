import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/youtube_music/auth/cdp_youtube_music_web_auth_port.dart';
import '../../../../services/youtube_music/auth/youtube_music_navigation_policy.dart';
import '../../../../services/youtube_music/auth/youtube_music_web_auth_port.dart';
import '../providers/youtube_music_auth_controller.dart';
import '../widgets/youtube_music_channel_picker_dialog.dart';

typedef DesktopYouTubeMusicWebAuthPortFactory =
    DesktopYouTubeMusicWebAuthPort Function();

/// Desktop login surface backed by a short-lived, external Chromium profile.
///
/// Google does not support authentication in many embedded desktop WebViews.
/// Keeping the browser behind [DesktopYouTubeMusicWebAuthPort] also means this
/// page can coordinate the flow without exposing cookies to presentation code.
class DesktopYouTubeMusicLoginPage extends ConsumerStatefulWidget {
  const DesktopYouTubeMusicLoginPage({super.key, this.webAuthPortFactory});

  final DesktopYouTubeMusicWebAuthPortFactory? webAuthPortFactory;

  static final Uri initialLoginUri = Uri.parse(
    'https://accounts.google.com/ServiceLogin?service=youtube&continue='
    'https%3A%2F%2Fmusic.youtube.com%2F',
  );

  @override
  ConsumerState<DesktopYouTubeMusicLoginPage> createState() =>
      _DesktopYouTubeMusicLoginPageState();
}

class _DesktopYouTubeMusicLoginPageState
    extends ConsumerState<DesktopYouTubeMusicLoginPage> {
  static const _successfulCleanup = YouTubeMusicWebCleanupResult(
    cookiesCleared: true,
    webStorageCleared: true,
    cacheCleared: true,
  );

  DesktopYouTubeMusicWebAuthPort? _webAuthPort;
  StreamSubscription<Uri>? _navigationSubscription;
  StreamSubscription<void>? _browserClosedSubscription;
  final Set<DesktopYouTubeMusicWebAuthPort> _verifiedCleanPorts =
      <DesktopYouTubeMusicWebAuthPort>{};
  final Set<DesktopYouTubeMusicWebAuthPort> _portsPendingCleanup =
      <DesktopYouTubeMusicWebAuthPort>{};
  final Map<
    DesktopYouTubeMusicWebAuthPort,
    Future<YouTubeMusicWebCleanupResult>
  >
  _cleanupInFlight =
      <DesktopYouTubeMusicWebAuthPort, Future<YouTubeMusicWebCleanupResult>>{};
  final Map<DesktopYouTubeMusicWebAuthPort, Future<void>>
  _cleanupRecoveryInFlight = <DesktopYouTubeMusicWebAuthPort, Future<void>>{};
  var _preparing = false;
  var _prepared = false;
  var _busy = false;
  var _tearingDown = false;
  var _allowPop = false;
  String _visibleHost = 'accounts.google.com';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_beginLoginAndPrepare());
    });
  }

  Future<void> _beginLoginAndPrepare() async {
    // The controller may still be reading secure storage. Starting a login in
    // that window would let the late restore overwrite `authenticating` with
    // `anonymous`, so wait until restoration reaches a terminal state first.
    while (mounted &&
        !_tearingDown &&
        ref.read(youtubeMusicAuthControllerProvider).phase ==
            YouTubeMusicAuthPhase.restoring) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (!mounted || _tearingDown) return;
    ref.read(youtubeMusicAuthControllerProvider.notifier).beginLogin();
    await _prepare();
  }

  DesktopYouTubeMusicWebAuthPort _createWebAuthPort() {
    final factory = widget.webAuthPortFactory;
    if (factory != null) return factory();
    return CdpYouTubeMusicWebAuthPort(
      initialLoginUri: DesktopYouTubeMusicLoginPage.initialLoginUri,
    );
  }

  Future<void> _prepare() async {
    if (_preparing || _tearingDown) return;
    setState(() {
      _preparing = true;
      _prepared = false;
      _errorMessage = null;
    });
    try {
      final port = _webAuthPort ??= _createWebAuthPort();
      _listenTo(port);
      await port.prepare();
      if (!mounted || _tearingDown) return;
      final currentUri = port.currentUri;
      setState(() {
        _preparing = false;
        _prepared = port.isPrepared;
        _visibleHost = _safeVisibleHost(currentUri) ?? _visibleHost;
      });
    } on YouTubeMusicWebAuthException catch (error) {
      await _discardFailedPort();
      _publishPreparationError(error.message);
    } on Object {
      await _discardFailedPort();
      _publishPreparationError(
        'No se pudo abrir una ventana segura del navegador para iniciar '
        'sesión.',
      );
    }
  }

  Future<void> _discardFailedPort() async {
    final port = _webAuthPort;
    if (port == null) return;
    _detachSubscriptions();
    final cleanup = await _cleanupPort(port).timeout(
      const Duration(seconds: 4),
      onTimeout: () => const YouTubeMusicWebCleanupResult(
        cookiesCleared: false,
        webStorageCleared: false,
        cacheCleared: false,
      ),
    );
    if (!cleanup.completed) unawaited(_ensureCleanupRecovery(port));
    if (!identical(_webAuthPort, port)) return;
    _webAuthPort = null;
  }

  void _listenTo(DesktopYouTubeMusicWebAuthPort port) {
    _navigationSubscription ??= port.navigationStream.listen(
      _onNavigation,
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted || _tearingDown) return;
        setState(() {
          _errorMessage =
              'Se perdió la comunicación con la ventana del navegador.';
        });
      },
    );
    _browserClosedSubscription ??= port.browserClosedStream.listen(
      (_) => unawaited(_onBrowserClosed()),
    );
  }

  void _publishPreparationError(String message) {
    if (!mounted || _tearingDown) return;
    setState(() {
      _preparing = false;
      _prepared = false;
      _errorMessage = message;
    });
  }

  void _onNavigation(Uri uri) {
    if (!mounted || _tearingDown) return;
    final host = _safeVisibleHost(uri);
    if (host != null) {
      setState(() {
        _visibleHost = host;
        _errorMessage = null;
      });
    }
    if ((_webAuthPort?.navigationPolicy ?? const YouTubeMusicNavigationPolicy())
        .isYouTubeAuthDocument(uri)) {
      unawaited(_completeAuthentication());
    }
  }

  String? _safeVisibleHost(Uri? uri) {
    final navigationPolicy =
        _webAuthPort?.navigationPolicy ?? const YouTubeMusicNavigationPolicy();
    if (uri == null ||
        navigationPolicy.evaluate(uri, isMainFrame: true) !=
            YouTubeMusicNavigationDecision.allow) {
      return null;
    }
    return uri.host.toLowerCase();
  }

  Future<void> _onBrowserClosed() async {
    if (_tearingDown) return;
    ref.read(youtubeMusicAuthControllerProvider.notifier).cancelLogin();
    await _finishAndPop(false);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(youtubeMusicAuthControllerProvider);
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_close());
      },
      child: Scaffold(
        key: const Key('youtube-music-desktop-login-page'),
        appBar: AppBar(
          leading: IconButton(
            key: const Key('youtube-music-desktop-login-close'),
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
                  const Icon(Icons.open_in_browser_outlined, size: 13),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _visibleHost,
                      key: const Key(
                        'youtube-music-desktop-login-visible-host',
                      ),
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
    if (_tearingDown) {
      return const _DesktopLoginStatusView(
        icon: Icons.cleaning_services_outlined,
        message: 'Cerrando el navegador y limpiando la sesión temporal…',
        showProgress: true,
      );
    }
    final error = _errorMessage ?? authState.message;
    if (error != null) {
      return _DesktopLoginStatusView(
        icon: Icons.error_outline,
        message: error,
        primaryActionLabel: _prepared ? 'Volver al navegador' : 'Reintentar',
        onPrimaryAction: _prepared ? _bringBrowserToForeground : _prepare,
        secondaryActionLabel: _prepared ? 'Reiniciar acceso' : null,
        onSecondaryAction: _prepared ? _retryAuthentication : null,
      );
    }
    if (_preparing || !_prepared) {
      return const _DesktopLoginStatusView(
        icon: Icons.security_outlined,
        message:
            'Abriendo una ventana privada del navegador para iniciar sesión…',
        showProgress: true,
      );
    }
    if (_busy) {
      return const _DesktopLoginStatusView(
        icon: Icons.verified_user_outlined,
        message: 'Verificando de forma segura tu sesión de YouTube Music…',
        showProgress: true,
      );
    }
    return _DesktopLoginStatusView(
      icon: Icons.open_in_browser_outlined,
      message:
          'Completa el inicio de sesión en la ventana del navegador.\n\n'
          'BStream detectará cuando regreses a YouTube Music. La ventana usa '
          'un perfil temporal que se eliminará al terminar o cancelar.',
      primaryActionLabel: 'Mostrar navegador',
      onPrimaryAction: _bringBrowserToForeground,
      secondaryActionLabel: 'Cancelar',
      onSecondaryAction: _close,
    );
  }

  Future<void> _bringBrowserToForeground() async {
    final port = _webAuthPort;
    if (port == null || _tearingDown) return;
    try {
      await port.bringToForeground();
      if (mounted) setState(() => _errorMessage = null);
    } on YouTubeMusicWebAuthException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage = 'No se pudo mostrar la ventana del navegador.';
        });
      }
    }
  }

  Future<void> _completeAuthentication() async {
    final port = _webAuthPort;
    if (port == null || _busy || _tearingDown || !mounted) return;
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      final authData = await port.waitForAuthenticatedSession();
      await ref
          .read(youtubeMusicAuthControllerProvider.notifier)
          .submitWebAuthentication(authData);
      if (!mounted || _tearingDown) return;

      var authState = ref.read(youtubeMusicAuthControllerProvider);
      if (authState.phase == YouTubeMusicAuthPhase.selectingChannel) {
        await _bestEffort(port.minimize);
        if (!mounted || _tearingDown) return;
        final channel = await YouTubeMusicChannelPickerDialog.show(
          context,
          authState.channels,
        );
        if (!mounted || _tearingDown) return;
        if (channel == null) {
          setState(() {
            _errorMessage = 'Selecciona un canal para continuar.';
          });
          await _bestEffort(port.bringToForeground);
          return;
        }

        final nextUri = await ref
            .read(youtubeMusicAuthControllerProvider.notifier)
            .chooseChannel(channel);
        if (!mounted || _tearingDown) return;
        if (nextUri != null) {
          await port.navigate(nextUri);
          await _bestEffort(port.bringToForeground);
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
          'Desktop YouTube Music auth completion failed: '
          '${error.runtimeType}',
        );
      }
      if (mounted && !_tearingDown) {
        setState(() => _errorMessage = error.message);
      }
    } on Object {
      if (kDebugMode) {
        debugPrint(
          'Desktop YouTube Music auth completion failed: unknown-error',
        );
      }
      if (mounted && !_tearingDown) {
        setState(() {
          _errorMessage =
              'No se pudo completar el inicio de sesión de forma segura.';
        });
      }
    } finally {
      if (mounted && !_tearingDown) setState(() => _busy = false);
    }
  }

  Future<void> _retryAuthentication() async {
    final port = _webAuthPort;
    if (port == null || _busy || _tearingDown) return;
    ref.read(youtubeMusicAuthControllerProvider.notifier).beginLogin();
    setState(() {
      _busy = true;
      _errorMessage = null;
    });
    try {
      await port.navigate(DesktopYouTubeMusicLoginPage.initialLoginUri);
      await port.bringToForeground();
    } on YouTubeMusicWebAuthException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } on Object {
      if (mounted) {
        setState(() {
          _errorMessage = 'No se pudo reiniciar el acceso en el navegador.';
        });
      }
    } finally {
      if (mounted && !_tearingDown) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_tearingDown) return;
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
      await WidgetsBinding.instance.endOfFrame;
    }

    _detachSubscriptions();
    final port = _webAuthPort;
    final cleanup = port == null
        ? _successfulCleanup
        : await _cleanupPort(port).timeout(
            const Duration(seconds: 4),
            onTimeout: () => const YouTubeMusicWebCleanupResult(
              cookiesCleared: false,
              webStorageCleared: false,
              cacheCleared: false,
            ),
          );
    if (port != null && !cleanup.completed) {
      unawaited(_ensureCleanupRecovery(port));
    }
    _recoverEveryPendingPort();
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(result);
    });
  }

  void _detachSubscriptions() {
    final navigationSubscription = _navigationSubscription;
    final browserClosedSubscription = _browserClosedSubscription;
    _navigationSubscription = null;
    _browserClosedSubscription = null;
    if (navigationSubscription != null) {
      _cancelSubscription(navigationSubscription);
    }
    if (browserClosedSubscription != null) {
      _cancelSubscription(browserClosedSubscription);
    }
  }

  void _cancelSubscription<T>(StreamSubscription<T> subscription) {
    try {
      final cancellation = subscription.cancel();
      unawaited(
        cancellation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } on Object {
      // A browser or protocol stream may already be tearing itself down. Its
      // port cleanup remains the authoritative process/profile boundary.
    }
  }

  Future<YouTubeMusicWebCleanupResult> _cleanupPort(
    DesktopYouTubeMusicWebAuthPort port,
  ) {
    if (_verifiedCleanPorts.contains(port)) {
      return Future<YouTubeMusicWebCleanupResult>.value(_successfulCleanup);
    }
    _portsPendingCleanup.add(port);
    final existing = _cleanupInFlight[port];
    if (existing != null) return existing;
    final operation = _runPortCleanup(port);
    _cleanupInFlight[port] = operation;
    unawaited(
      operation.then<void>((_) {
        if (identical(_cleanupInFlight[port], operation)) {
          _cleanupInFlight.remove(port);
        }
      }),
    );
    return operation;
  }

  Future<YouTubeMusicWebCleanupResult> _runPortCleanup(
    DesktopYouTubeMusicWebAuthPort port,
  ) async {
    final result = await _safeCleanup(port);
    if (result.completed) {
      _portsPendingCleanup.remove(port);
      _verifiedCleanPorts.add(port);
    }
    return result;
  }

  Future<void> _ensureCleanupRecovery(DesktopYouTubeMusicWebAuthPort port) {
    if (_verifiedCleanPorts.contains(port)) return Future<void>.value();
    final existing = _cleanupRecoveryInFlight[port];
    if (existing != null) return existing;
    final operation = _retryPortCleanup(port);
    _cleanupRecoveryInFlight[port] = operation;
    unawaited(
      operation.then<void>((_) {
        if (identical(_cleanupRecoveryInFlight[port], operation)) {
          _cleanupRecoveryInFlight.remove(port);
        }
      }),
    );
    return operation;
  }

  Future<void> _retryPortCleanup(DesktopYouTubeMusicWebAuthPort port) async {
    var result = await _cleanupPort(port);
    for (var attempt = 1; attempt < 3 && !result.completed; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      result = await _cleanupPort(port);
    }
  }

  void _recoverEveryPendingPort() {
    for (final port in _portsPendingCleanup.toList(growable: false)) {
      unawaited(_ensureCleanupRecovery(port));
    }
  }

  Future<YouTubeMusicWebCleanupResult> _safeCleanup(
    DesktopYouTubeMusicWebAuthPort port,
  ) async {
    try {
      return await port.cleanup();
    } on Object {
      return const YouTubeMusicWebCleanupResult(
        cookiesCleared: false,
        webStorageCleared: false,
        cacheCleared: false,
      );
    }
  }

  Future<void> _bestEffort(Future<void> Function() operation) async {
    try {
      await operation();
    } on Object {
      // Foreground/minimize is only window coordination; authentication and
      // cleanup remain authoritative if the compositor rejects the request.
    }
  }

  @override
  void dispose() {
    _detachSubscriptions();
    final port = _webAuthPort;
    if (port != null && !_verifiedCleanPorts.contains(port)) {
      _portsPendingCleanup.add(port);
    }
    _recoverEveryPendingPort();
    super.dispose();
  }
}

class _DesktopLoginStatusView extends StatelessWidget {
  const _DesktopLoginStatusView({
    required this.icon,
    required this.message,
    this.showProgress = false,
    this.primaryActionLabel,
    this.onPrimaryAction,
    this.secondaryActionLabel,
    this.onSecondaryAction,
  });

  final IconData icon;
  final String message;
  final bool showProgress;
  final String? primaryActionLabel;
  final FutureOr<void> Function()? onPrimaryAction;
  final String? secondaryActionLabel;
  final FutureOr<void> Function()? onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 52),
              const SizedBox(height: 20),
              Text(message, textAlign: TextAlign.center),
              if (showProgress) ...<Widget>[
                const SizedBox(height: 24),
                const CircularProgressIndicator(),
              ],
              if (primaryActionLabel != null && onPrimaryAction != null) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('youtube-music-desktop-login-primary-action'),
                  onPressed: onPrimaryAction,
                  icon: const Icon(Icons.open_in_browser_outlined),
                  label: Text(primaryActionLabel!),
                ),
              ],
              if (secondaryActionLabel != null &&
                  onSecondaryAction != null) ...<Widget>[
                const SizedBox(height: 8),
                TextButton(
                  key: const Key(
                    'youtube-music-desktop-login-secondary-action',
                  ),
                  onPressed: onSecondaryAction,
                  child: Text(secondaryActionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
