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
  GatewayYouTubeMusicAccountClient({required this.createGateway});

  final YouTubeMusicAuthenticatedGatewayFactory createGateway;

  // Login first validates `account_menu`, just like the reference Android
  // clients.  Keep that result for the immediately-following optional
  // channel enumeration so a normal single-channel login does not hit the
  // same endpoint twice.
  String? _cachedProfileKey;
  auth.YouTubeMusicAccountProfile? _cachedProfile;

  @override
  Future<auth.YouTubeMusicAccountProfile> validateAccount(
    auth.YouTubeMusicWebAuthData authData,
  ) async {
    try {
      final cacheKey = _profileKey(authData);
      final cached = _cachedProfile;
      if (cached != null && _cachedProfileKey == cacheKey) {
        _cachedProfile = null;
        _cachedProfileKey = null;
        return cached;
      }
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
        try {
          final directory = await gateway.getAccounts();
          selectedChannel = _matchingChannel(directory.channels, authData);
        } on YouTubeMusicAccountException catch (error) {
          // account_menu is authoritative for authentication.  Channel
          // enumeration is optional and may be rate-limited independently;
          // retain the session and use DATASYNC/page identity below.
          if (!_isTransientAccountFailure(error)) rethrow;
        }
      }
      final channelId = _stableAccountId(
        remoteProfile: remoteProfile,
        selectedChannel: selectedChannel,
        authData: authData,
      );
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
      final gateway = createGateway(authData);
      // Validate the session before asking for the optional channel
      // directory.  This is the order used by Metrolist/OpenTune and avoids
      // treating a successful Google hand-off as an unauthenticated channel
      // lookup.
      final remoteProfile = await gateway.getProfile();
      if (remoteProfile == null) {
        throw const auth_client.YouTubeMusicAccountException(
          auth_client.YouTubeMusicAccountFailureKind.invalidResponse,
          'YouTube Music no devolvi\u00f3 un perfil de cuenta v\u00e1lido.',
        );
      }
      if (remoteProfile.channelId != null) {
        _cachedProfileKey = _profileKey(authData);
        _cachedProfile = auth.YouTubeMusicAccountProfile(
          channelId: remoteProfile.channelId!,
          displayName: remoteProfile.displayName,
          handle: remoteProfile.handle,
          email: remoteProfile.email,
          avatarUrl: _safeAvatarUri(remoteProfile.avatarUrl),
        );
      }
      final directory = await gateway.getAccounts();
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
      if (channels.length == 1) {
        final channel = channels.single;
        final profile = auth.YouTubeMusicAccountProfile(
          channelId: channel.profile.channelId,
          displayName: remoteProfile.displayName,
          handle: remoteProfile.handle ?? channel.profile.handle,
          email: remoteProfile.email ?? channel.profile.email,
          avatarUrl: _safeAvatarUri(
            remoteProfile.avatarUrl ?? channel.profile.avatarUrl?.toString(),
          ),
        );
        _cachedProfileKey = _profileKey(authData);
        _cachedProfile = profile;
      } else if (channels.length > 1) {
        // The user still has to choose a channel.  Do not leave a profile
        // cache that could be reused if the picker is cancelled and a later
        // login happens with the same identity fields.
        _cachedProfileKey = null;
        _cachedProfile = null;
      } else if (remoteProfile.channelId != null) {
        _cachedProfileKey = _profileKey(authData);
        _cachedProfile = auth.YouTubeMusicAccountProfile(
          channelId: remoteProfile.channelId!,
          displayName: remoteProfile.displayName,
          handle: remoteProfile.handle,
          email: remoteProfile.email,
          avatarUrl: _safeAvatarUri(remoteProfile.avatarUrl),
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

String _profileKey(auth.YouTubeMusicWebAuthData authData) {
  final identity = authData.identity;
  return <String?>[
    identity.visitorData,
    identity.authUser,
    identity.dataSyncId,
    identity.delegatedPageId,
    authData.apiKey,
    authData.clientVersion,
    authData.clientName,
  ].map((value) => value?.trim() ?? '').join('|');
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

String? _stableAccountId({
  required RemoteAccountProfile remoteProfile,
  required RemoteAccountChannel? selectedChannel,
  required auth.YouTubeMusicWebAuthData authData,
}) {
  final channelId = _firstNonEmpty(<String?>[
    remoteProfile.channelId,
    selectedChannel?.channelId,
    selectedChannel?.pageId,
    authData.identity.delegatedPageId,
    _channelIdFromDataSync(selectedChannel?.dataSyncId),
  ]);
  if (channelId != null) return channelId;

  // Metrolist treats DATASYNC_ID as the authenticated account identity even
  // when YouTube does not expose a UC channel id in account_menu.  Preserve
  // that behavior instead of rejecting a valid session.
  final dataSync = _firstNonEmpty(<String?>[
    selectedChannel?.dataSyncId,
    authData.identity.dataSyncId,
  ]);
  if (dataSync != null) {
    final normalized = dataSync.split('||').first.trim();
    if (normalized.isNotEmpty) return 'datasync:$normalized';
  }
  final email = remoteProfile.email?.trim();
  if (email != null && email.isNotEmpty) return 'email:${email.toLowerCase()}';
  return null;
}

bool _isTransientAccountFailure(YouTubeMusicAccountException error) {
  final status = error.statusCode;
  return status == 408 ||
      status == 425 ||
      status == 429 ||
      (status != null && status >= 500);
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
