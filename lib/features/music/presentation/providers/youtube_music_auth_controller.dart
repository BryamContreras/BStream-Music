import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../services/youtube_music/account/youtube_music_account.dart'
    hide YouTubeMusicAccountException;
import '../../../../services/youtube_music/auth/youtube_music_account_client.dart';
import '../../../../services/youtube_music/auth/youtube_music_auth_coordinator.dart';
import '../../../../services/youtube_music/auth/youtube_music_auth_models.dart';
import '../../../../services/youtube_music/auth/youtube_music_session_store.dart';
import '../../../../services/youtube_music/auth/youtube_music_web_auth_port.dart';

final youtubeMusicSessionStoreProvider = Provider<YouTubeMusicSessionStore>(
  (ref) => SecureYouTubeMusicSessionStore(),
);

final youtubeMusicAccountTransportProvider =
    Provider<IoYouTubeMusicAccountTransport>((ref) {
      final transport = IoYouTubeMusicAccountTransport();
      ref.onDispose(transport.close);
      return transport;
    });

final youtubeMusicAccountClientProvider = Provider<YouTubeMusicAccountClient>((
  ref,
) {
  final transport = ref.watch(youtubeMusicAccountTransportProvider);
  return GatewayYouTubeMusicAccountClient(
    createGateway: (authData) => YouTubeMusicAccountGateway(
      transport: transport,
      sessionHeaders: WebAuthDataYouTubeMusicSessionHeadersProvider(
        authData: authData,
      ),
      clientContext: buildYouTubeMusicAccountClientContextFromWebAuthData(
        authData,
      ),
    ),
  );
});

final youtubeMusicAuthCoordinatorProvider =
    Provider<YouTubeMusicAuthCoordinator>(
      (ref) => YouTubeMusicAuthCoordinator(
        sessionStore: ref.watch(youtubeMusicSessionStoreProvider),
        accountClient: ref.watch(youtubeMusicAccountClientProvider),
      ),
    );

final youtubeMusicAuthControllerProvider =
    NotifierProvider<YouTubeMusicAuthController, YouTubeMusicAuthState>(
      YouTubeMusicAuthController.new,
    );

/// Shared authenticated account gateway for read/mutation feature adapters.
///
/// Keeping this construction in one provider lets Home and artist
/// subscriptions share the same credential boundary and transport without
/// exposing the credential through presentation state.
final youtubeMusicAuthenticatedAccountGatewayProvider =
    Provider<YouTubeMusicAccountGateway?>((ref) {
      final authState = ref.watch(youtubeMusicAuthControllerProvider);
      if (!authState.isAuthenticated) return null;
      final authController = ref.read(
        youtubeMusicAuthControllerProvider.notifier,
      );
      final credential = authController.credentialForAuthenticatedRequests;
      if (credential == null) return null;
      return YouTubeMusicAccountGateway(
        transport: ref.watch(youtubeMusicAccountTransportProvider),
        sessionHeaders: CredentialYouTubeMusicSessionHeadersProvider(
          readCredential: () async =>
              authController.credentialForAuthenticatedRequests,
        ),
        clientContext: buildYouTubeMusicAccountClientContextFromCredential(
          credential,
        ),
      );
    });

enum YouTubeMusicAuthPhase {
  unsupported,
  restoring,
  anonymous,
  authenticating,
  selectingChannel,
  authenticated,
  expired,
  error,
}

class YouTubeMusicAuthState {
  const YouTubeMusicAuthState({
    required this.phase,
    required this.generation,
    this.profile,
    this.channels = const <YouTubeMusicAccountChannel>[],
    this.message,
  });

  const YouTubeMusicAuthState.restoring({required int generation})
    : this(phase: YouTubeMusicAuthPhase.restoring, generation: generation);

  final YouTubeMusicAuthPhase phase;
  final int generation;
  final YouTubeMusicAccountProfile? profile;
  final List<YouTubeMusicAccountChannel> channels;
  final String? message;

  bool get isAuthenticated =>
      phase == YouTubeMusicAuthPhase.authenticated && profile != null;

  @override
  String toString() =>
      'YouTubeMusicAuthState(phase: $phase, generation: $generation, '
      'profile: $profile, channels: ${channels.length})';
}

class YouTubeMusicAuthController extends Notifier<YouTubeMusicAuthState> {
  YouTubeMusicSessionCredential? _credential;
  YouTubeMusicWebAuthData? _pendingAuthData;
  YouTubeMusicAccountChannel? _expectedChannel;
  var _generation = 0;
  var _disposed = false;

  /// Credential access for authenticated service factories only.
  ///
  /// Presentation state intentionally exposes only [YouTubeMusicAccountProfile].
  YouTubeMusicSessionCredential? get credentialForAuthenticatedRequests =>
      state.isAuthenticated ? _credential : null;

  @override
  YouTubeMusicAuthState build() {
    ref.onDispose(() => _disposed = true);
    final initial = YouTubeMusicAuthState.restoring(generation: _generation);
    unawaited(Future<void>.microtask(() => _restore(_generation)));
    return initial;
  }

  Future<void> retryRestore() async {
    final generation = ++_generation;
    _clearPending();
    state = YouTubeMusicAuthState.restoring(generation: generation);
    await _restore(generation);
  }

  Future<void> _restore(int generation) async {
    try {
      final credential = await ref
          .read(youtubeMusicAuthCoordinatorProvider)
          .restore();
      if (!_isCurrent(generation)) return;
      _credential = credential;
      state = credential == null
          ? YouTubeMusicAuthState(
              phase: YouTubeMusicAuthPhase.anonymous,
              generation: generation,
            )
          : YouTubeMusicAuthState(
              phase: YouTubeMusicAuthPhase.authenticated,
              generation: generation,
              profile: credential.profile,
            );
    } on Object {
      if (!_isCurrent(generation)) return;
      _credential = null;
      state = YouTubeMusicAuthState(
        phase: YouTubeMusicAuthPhase.error,
        generation: generation,
        message: 'No se pudo leer de forma segura la sesión guardada.',
      );
    }
  }

  void beginLogin() {
    final generation = ++_generation;
    _clearPending();
    state = YouTubeMusicAuthState(
      phase: YouTubeMusicAuthPhase.authenticating,
      generation: generation,
      profile: _credential?.profile,
    );
  }

  Future<void> submitWebAuthentication(YouTubeMusicWebAuthData authData) async {
    final generation = _generation;
    if (state.phase != YouTubeMusicAuthPhase.authenticating &&
        state.phase != YouTubeMusicAuthPhase.selectingChannel) {
      return;
    }
    final coordinator = ref.read(youtubeMusicAuthCoordinatorProvider);
    try {
      final expectedChannel = _expectedChannel;
      if (expectedChannel != null) {
        await _finishAuthentication(
          coordinator,
          authData,
          generation,
          expectedChannel: expectedChannel,
        );
        return;
      }

      final normalized = coordinator.normalize(authData);
      List<YouTubeMusicAccountChannel> channels;
      try {
        channels = await coordinator.discoverChannels(normalized);
      } on YouTubeMusicAccountException catch (error) {
        // Channel enumeration is an optional UX enhancement. Some accounts
        // (and some Google hand-offs) expose a valid profile before the
        // accounts-list endpoint is available. Do not reject an otherwise
        // valid login for that secondary request; authentication validation
        // below remains authoritative and still rejects 401/403.
        if (error.kind == YouTubeMusicAccountFailureKind.unauthenticated) {
          rethrow;
        }
        channels = const <YouTubeMusicAccountChannel>[];
      }
      if (!_isCurrent(generation)) return;
      if (channels.length > 1) {
        _pendingAuthData = normalized;
        state = YouTubeMusicAuthState(
          phase: YouTubeMusicAuthPhase.selectingChannel,
          generation: generation,
          profile: _credential?.profile,
          channels: channels,
        );
        return;
      }

      await _finishAuthentication(
        coordinator,
        normalized,
        generation,
        expectedChannel: channels.firstOrNull,
      );
    } on Object catch (error) {
      _publishAuthenticationError(error, generation);
    }
  }

  /// Returns a validated navigation target when the WebView must switch to a
  /// different Brand/channel identity. A selected channel is finalized here.
  Future<Uri?> chooseChannel(YouTubeMusicAccountChannel channel) async {
    final generation = _generation;
    final authData = _pendingAuthData;
    if (state.phase != YouTubeMusicAuthPhase.selectingChannel ||
        authData == null) {
      return null;
    }
    final coordinator = ref.read(youtubeMusicAuthCoordinatorProvider);
    try {
      final matches = state.channels
          .where(
            (candidate) =>
                candidate.profile.channelId == channel.profile.channelId,
          )
          .toList(growable: false);
      if (matches.length != 1) {
        throw const YouTubeMusicAccountException(
          YouTubeMusicAccountFailureKind.invalidResponse,
          'El canal seleccionado ya no está disponible.',
        );
      }
      final selectedChannel = matches.single;
      if (selectedChannel.isSelected) {
        await _finishAuthentication(
          coordinator,
          authData,
          generation,
          expectedChannel: selectedChannel,
        );
        return null;
      }
      final signInUrl = selectedChannel.signInUrl;
      if (signInUrl == null) {
        throw const YouTubeMusicAccountException(
          YouTubeMusicAccountFailureKind.invalidResponse,
          'El canal seleccionado no ofrece un enlace de acceso válido.',
        );
      }
      final validatedUrl = coordinator.validateChannelSignInUrl(signInUrl);
      if (!_isCurrent(generation)) return null;
      _expectedChannel = selectedChannel;
      state = YouTubeMusicAuthState(
        phase: YouTubeMusicAuthPhase.authenticating,
        generation: generation,
        profile: _credential?.profile,
      );
      return validatedUrl;
    } on Object catch (error) {
      _publishAuthenticationError(error, generation);
      return null;
    }
  }

  Future<void> _finishAuthentication(
    YouTubeMusicAuthCoordinator coordinator,
    YouTubeMusicWebAuthData authData,
    int generation, {
    YouTubeMusicAccountChannel? expectedChannel,
  }) async {
    final credential = await coordinator.validate(
      authData,
      expectedChannel: expectedChannel,
    );
    if (!_isCurrent(generation)) return;
    // Persistence happens only after network validation and a generation
    // check. If logout starts while the write is running, its serialized
    // delete is queued after this write.
    await coordinator.persist(credential);
    if (!_isCurrent(generation)) {
      final activeCredential = _credential;
      if (activeCredential == null) {
        await coordinator.logout();
      } else {
        await coordinator.persist(activeCredential);
      }
      return;
    }
    _credential = credential;
    _clearPending();
    state = YouTubeMusicAuthState(
      phase: YouTubeMusicAuthPhase.authenticated,
      generation: generation,
      profile: credential.profile,
    );
  }

  void cancelLogin() {
    final generation = ++_generation;
    _clearPending();
    final credential = _credential;
    state = credential == null
        ? YouTubeMusicAuthState(
            phase: YouTubeMusicAuthPhase.anonymous,
            generation: generation,
          )
        : YouTubeMusicAuthState(
            phase: YouTubeMusicAuthPhase.authenticated,
            generation: generation,
            profile: credential.profile,
          );
  }

  Future<void> expireSession() async {
    final generation = ++_generation;
    final oldProfile = _credential?.profile;
    _credential = null;
    _clearPending();
    state = YouTubeMusicAuthState(
      phase: YouTubeMusicAuthPhase.expired,
      generation: generation,
      profile: oldProfile,
      message: 'La sesión de YouTube Music venció. Inicia sesión nuevamente.',
    );
    try {
      await ref.read(youtubeMusicAuthCoordinatorProvider).logout();
    } on Object {
      // The in-memory session is already disabled. A future logout/restore can
      // retry deletion without ever re-enabling authenticated requests.
    }
  }

  Future<void> logout({YouTubeMusicWebAuthPort? webAuthPort}) async {
    final generation = ++_generation;
    _credential = null;
    _clearPending();
    state = YouTubeMusicAuthState(
      phase: YouTubeMusicAuthPhase.anonymous,
      generation: generation,
    );

    var storageCleared = true;
    try {
      await ref.read(youtubeMusicAuthCoordinatorProvider).logout();
    } on Object {
      storageCleared = false;
    }
    if (webAuthPort != null) {
      try {
        await webAuthPort.cleanup();
      } on Object {
        // Network authentication stays disabled even if WebView cleanup needs
        // another attempt.
      }
    }
    if (_isCurrent(generation) && !storageCleared) {
      state = YouTubeMusicAuthState(
        phase: YouTubeMusicAuthPhase.anonymous,
        generation: generation,
        message:
            'La cuenta se desconectó, pero no se pudo eliminar la sesión '
            'cifrada. Reintenta cerrar sesión.',
      );
    }
  }

  void _publishAuthenticationError(Object error, int generation) {
    if (!_isCurrent(generation)) return;
    final message = switch (error) {
      YouTubeMusicAccountException(:final message) => message,
      FormatException() =>
        'YouTube Music devolvió datos de sesión inválidos o incompletos.',
      _ => 'No se pudo validar la cuenta de YouTube Music.',
    };
    _clearPending();
    state = YouTubeMusicAuthState(
      phase: YouTubeMusicAuthPhase.error,
      generation: generation,
      profile: _credential?.profile,
      message: message,
    );
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _clearPending() {
    _pendingAuthData = null;
    _expectedChannel = null;
  }
}
