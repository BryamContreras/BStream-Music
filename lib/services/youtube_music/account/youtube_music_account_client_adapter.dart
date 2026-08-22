import '../auth/youtube_music_account_client.dart' as auth_client;
import '../auth/youtube_music_auth_models.dart' as auth;
import 'youtube_music_account_gateway.dart';
import 'youtube_music_account_models.dart';
import 'youtube_music_account_transport.dart';

typedef YouTubeMusicAuthenticatedGatewayFactory =
    YouTubeMusicAccountGateway Function(auth.YouTubeMusicWebAuthData authData);

/// Bridges the clean account gateway to the login coordinator without Riverpod
/// or storage dependencies.
///
/// The factory is responsible for binding the candidate WebView session to a
/// [YouTubeMusicSessionHeadersProvider]. This keeps credential handling in the
/// auth composition root and out of playlist/domain code.
class GatewayYouTubeMusicAccountClient
    implements auth_client.YouTubeMusicAccountClient {
  const GatewayYouTubeMusicAccountClient({required this.createGateway});

  final YouTubeMusicAuthenticatedGatewayFactory createGateway;

  @override
  Future<auth.YouTubeMusicAccountProfile> validateAccount(
    auth.YouTubeMusicWebAuthData authData,
  ) async {
    try {
      final gateway = createGateway(authData);
      final remoteProfile = await gateway.getProfile();
      if (remoteProfile == null) {
        throw const auth_client.YouTubeMusicAccountException(
          auth_client.YouTubeMusicAccountFailureKind.invalidResponse,
          'YouTube Music no devolvió un perfil de cuenta válido.',
        );
      }

      RemoteAccountChannel? selectedChannel;
      if (remoteProfile.channelId == null) {
        final directory = await gateway.getAccounts();
        selectedChannel = _matchingChannel(directory.channels, authData);
      }
      final channelId = _firstNonEmpty(<String?>[
        remoteProfile.channelId,
        selectedChannel?.channelId,
        selectedChannel?.pageId,
        authData.identity.delegatedPageId,
        _channelIdFromDataSync(selectedChannel?.dataSyncId),
        _channelIdFromDataSync(authData.identity.dataSyncId),
      ]);
      if (channelId == null) {
        throw const auth_client.YouTubeMusicAccountException(
          auth_client.YouTubeMusicAccountFailureKind.invalidResponse,
          'YouTube Music no devolvió una identidad de canal estable.',
        );
      }
      return auth.YouTubeMusicAccountProfile(
        channelId: channelId,
        displayName: remoteProfile.displayName,
        handle: remoteProfile.handle ?? selectedChannel?.handle,
        email: remoteProfile.email,
        avatarUrl: _safeAvatarUri(
          remoteProfile.avatarUrl ?? selectedChannel?.avatarUrl,
        ),
      );
    } on auth_client.YouTubeMusicAccountException {
      rethrow;
    } on YouTubeMusicAccountException catch (error) {
      throw _mapGatewayFailure(error);
    } on Object {
      throw const auth_client.YouTubeMusicAccountException(
        auth_client.YouTubeMusicAccountFailureKind.unavailable,
        'No se pudo validar la cuenta de YouTube Music.',
      );
    }
  }

  @override
  Future<List<auth.YouTubeMusicAccountChannel>> listChannels(
    auth.YouTubeMusicWebAuthData authData,
  ) async {
    try {
      final directory = await createGateway(authData).getAccounts();
      final email = directory.accounts.isEmpty
          ? null
          : directory.accounts.first.email;
      final channels = <auth.YouTubeMusicAccountChannel>[];
      for (final channel in directory.channels) {
        final channelId = _firstNonEmpty(<String?>[
          channel.channelId,
          channel.pageId,
          _channelIdFromDataSync(channel.dataSyncId),
        ]);
        if (channelId == null) {
          continue;
        }
        channels.add(
          auth.YouTubeMusicAccountChannel(
            profile: auth.YouTubeMusicAccountProfile(
              channelId: channelId,
              displayName: channel.displayName,
              handle: channel.handle,
              email: email,
              avatarUrl: _safeAvatarUri(channel.avatarUrl),
            ),
            isSelected: channel.isSelected,
            pageId: channel.pageId,
            dataSyncId: channel.dataSyncId,
            signInUrl: _safeSignInUri(channel.signInUrl),
          ),
        );
      }
      if (directory.channels.isNotEmpty && channels.isEmpty) {
        throw const auth_client.YouTubeMusicAccountException(
          auth_client.YouTubeMusicAccountFailureKind.invalidResponse,
          'YouTube Music devolvió canales sin una identidad estable.',
        );
      }
      return List<auth.YouTubeMusicAccountChannel>.unmodifiable(channels);
    } on auth_client.YouTubeMusicAccountException {
      rethrow;
    } on YouTubeMusicAccountException catch (error) {
      throw _mapGatewayFailure(error);
    } on Object {
      throw const auth_client.YouTubeMusicAccountException(
        auth_client.YouTubeMusicAccountFailureKind.unavailable,
        'No se pudieron consultar los canales de YouTube Music.',
      );
    }
  }
}

RemoteAccountChannel? _matchingChannel(
  List<RemoteAccountChannel> channels,
  auth.YouTubeMusicWebAuthData authData,
) {
  final delegatedPageId = authData.identity.delegatedPageId?.trim();
  if (delegatedPageId != null && delegatedPageId.isNotEmpty) {
    for (final channel in channels) {
      if (channel.pageId == delegatedPageId ||
          channel.channelId == delegatedPageId) {
        return channel;
      }
    }
  }
  for (final channel in channels) {
    if (channel.isSelected) {
      return channel;
    }
  }
  return channels.length == 1 ? channels.single : null;
}

String? _channelIdFromDataSync(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  for (final component in normalized.split(RegExp(r'[|,;:]'))) {
    if (component.trim().startsWith('UC')) {
      return component.trim();
    }
  }
  return null;
}

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    final normalized = value?.trim();
    if (normalized != null && normalized.isNotEmpty) {
      return normalized;
    }
  }
  return null;
}

Uri? _safeAvatarUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

Uri? _safeSignInUri(String? value) {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.toLowerCase() != 'music.youtube.com' ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

auth_client.YouTubeMusicAccountException _mapGatewayFailure(
  YouTubeMusicAccountException error,
) {
  final statusCode = error.statusCode;
  if (statusCode == 401 || statusCode == 403) {
    return const auth_client.YouTubeMusicAccountException(
      auth_client.YouTubeMusicAccountFailureKind.unauthenticated,
      'La sesión de YouTube Music ya no es válida.',
    );
  }
  if (statusCode == 408 ||
      statusCode == 425 ||
      statusCode == 429 ||
      (statusCode != null && statusCode >= 500)) {
    return const auth_client.YouTubeMusicAccountException(
      auth_client.YouTubeMusicAccountFailureKind.transient,
      'YouTube Music no está disponible temporalmente.',
    );
  }
  return const auth_client.YouTubeMusicAccountException(
    auth_client.YouTubeMusicAccountFailureKind.invalidResponse,
    'YouTube Music devolvió una respuesta de cuenta no válida.',
  );
}
