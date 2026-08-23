import 'dart:convert';

/// Non-secret account information safe for presentation state.
class YouTubeMusicAccountProfile {
  const YouTubeMusicAccountProfile({
    required this.channelId,
    required this.displayName,
    this.handle,
    this.email,
    this.avatarUrl,
  });

  final String channelId;
  final String displayName;
  final String? handle;
  final String? email;
  final Uri? avatarUrl;

  String get accountKey => channelId;

  Map<String, Object?> toJson() => <String, Object?>{
    'channelId': channelId,
    'displayName': displayName,
    'handle': handle,
    'email': email,
    'avatarUrl': avatarUrl?.toString(),
  };

  factory YouTubeMusicAccountProfile.fromJson(Map<String, Object?> json) {
    final channelId = _requiredString(json, 'channelId', maximumLength: 256);
    final displayName = _requiredString(
      json,
      'displayName',
      maximumLength: 512,
    );
    final avatarValue = _optionalString(json, 'avatarUrl', maximumLength: 2048);
    final avatarUrl = avatarValue == null ? null : Uri.tryParse(avatarValue);
    if (avatarValue != null &&
        (avatarUrl == null ||
            avatarUrl.scheme != 'https' ||
            avatarUrl.host.isEmpty ||
            avatarUrl.userInfo.isNotEmpty)) {
      throw const FormatException('Invalid account avatar URL.');
    }
    return YouTubeMusicAccountProfile(
      channelId: channelId,
      displayName: displayName,
      handle: _optionalString(json, 'handle', maximumLength: 256),
      email: _optionalString(json, 'email', maximumLength: 512),
      avatarUrl: avatarUrl,
    );
  }

  @override
  String toString() =>
      'YouTubeMusicAccountProfile(channelId: $channelId, '
      'displayName: $displayName)';
}

/// Account/channel identity fields required by authenticated InnerTube calls.
///
/// These values are treated as credential material and are deliberately never
/// included in [toString].
class YouTubeMusicAuthIdentity {
  const YouTubeMusicAuthIdentity({
    required this.visitorData,
    required this.authUser,
    this.dataSyncId,
    this.delegatedPageId,
  });

  final String visitorData;
  final String authUser;
  final String? dataSyncId;
  final String? delegatedPageId;

  Map<String, Object?> toJson() => <String, Object?>{
    'visitorData': visitorData,
    'authUser': authUser,
    'dataSyncId': dataSyncId,
    'delegatedPageId': delegatedPageId,
  };

  factory YouTubeMusicAuthIdentity.fromJson(Map<String, Object?> json) {
    final authUser = _requiredString(json, 'authUser', maximumLength: 16);
    if (!RegExp(r'^\d{1,16}$').hasMatch(authUser)) {
      throw const FormatException('Invalid account session index.');
    }
    return YouTubeMusicAuthIdentity(
      visitorData: _requiredString(json, 'visitorData', maximumLength: 4096),
      authUser: authUser,
      dataSyncId: _optionalString(json, 'dataSyncId', maximumLength: 4096),
      delegatedPageId: _optionalString(
        json,
        'delegatedPageId',
        maximumLength: 1024,
      ),
    );
  }

  @override
  String toString() => 'YouTubeMusicAuthIdentity([REDACTED])';
}

/// Candidate extracted from the isolated login WebView.
class YouTubeMusicWebAuthData {
  factory YouTubeMusicWebAuthData({
    required String cookieHeader,
    required YouTubeMusicAuthIdentity identity,
    required String apiKey,
    required String clientVersion,
    required String clientName,
    String? region,
  }) => YouTubeMusicWebAuthData._(
    cookieHeader: cookieHeader,
    identity: identity,
    apiKey: _requiredProtocolValue(apiKey, 'apiKey', maximumLength: 512),
    clientVersion: _requiredProtocolValue(
      clientVersion,
      'clientVersion',
      maximumLength: 128,
    ),
    clientName: _requiredProtocolValue(
      clientName,
      'clientName',
      maximumLength: 64,
    ),
    region: _optionalRegion(region),
  );

  const YouTubeMusicWebAuthData._({
    required this.cookieHeader,
    required this.identity,
    required this.apiKey,
    required this.clientVersion,
    required this.clientName,
    this.region,
  });

  final String cookieHeader;
  final YouTubeMusicAuthIdentity identity;
  final String apiKey;
  final String clientVersion;
  final String clientName;

  /// YouTube's country context (`gl`) captured from the authenticated page.
  /// It is optional for credentials created by older app versions.
  final String? region;

  @override
  String toString() => 'YouTubeMusicWebAuthData([REDACTED])';
}

/// A selectable Google/YouTube channel returned during account discovery.
///
/// [signInUrl] is intentionally ephemeral and must never be persisted.
class YouTubeMusicAccountChannel {
  const YouTubeMusicAccountChannel({
    required this.profile,
    required this.isSelected,
    this.pageId,
    this.dataSyncId,
    this.signInUrl,
  });

  final YouTubeMusicAccountProfile profile;
  final bool isSelected;
  final String? pageId;
  final String? dataSyncId;
  final Uri? signInUrl;

  @override
  String toString() =>
      'YouTubeMusicAccountChannel(profile: $profile, '
      'isSelected: $isSelected)';
}

/// Versioned credential persisted exclusively in secure platform storage.
class YouTubeMusicSessionCredential {
  factory YouTubeMusicSessionCredential({
    required String cookieHeader,
    required YouTubeMusicAuthIdentity identity,
    required YouTubeMusicAccountProfile profile,
    required DateTime validatedAt,
    required String apiKey,
    required String clientVersion,
    required String clientName,
    String? region,
  }) => YouTubeMusicSessionCredential._(
    cookieHeader: cookieHeader,
    identity: identity,
    profile: profile,
    validatedAt: validatedAt,
    apiKey: _requiredProtocolValue(apiKey, 'apiKey', maximumLength: 512),
    clientVersion: _requiredProtocolValue(
      clientVersion,
      'clientVersion',
      maximumLength: 128,
    ),
    clientName: _requiredProtocolValue(
      clientName,
      'clientName',
      maximumLength: 64,
    ),
    region: _optionalRegion(region),
  );

  const YouTubeMusicSessionCredential._({
    required this.cookieHeader,
    required this.identity,
    required this.profile,
    required this.validatedAt,
    required this.apiKey,
    required this.clientVersion,
    required this.clientName,
    this.region,
  });

  static const schemaVersion = 1;
  static const maximumEncodedBytes = 96 * 1024;

  final String cookieHeader;
  final YouTubeMusicAuthIdentity identity;
  final YouTubeMusicAccountProfile profile;
  final DateTime validatedAt;
  final String apiKey;
  final String clientVersion;
  final String clientName;
  final String? region;

  String encode() {
    final encoded = jsonEncode(<String, Object?>{
      'version': schemaVersion,
      'cookieHeader': cookieHeader,
      'client': <String, Object?>{
        'apiKey': apiKey,
        'clientVersion': clientVersion,
        'clientName': clientName,
        if (region != null) 'region': region,
      },
      'identity': identity.toJson(),
      'profile': profile.toJson(),
      'validatedAt': validatedAt.toUtc().toIso8601String(),
    });
    if (utf8.encode(encoded).length > maximumEncodedBytes) {
      throw const FormatException('The account session is too large.');
    }
    return encoded;
  }

  factory YouTubeMusicSessionCredential.decode(String encoded) {
    if (encoded.isEmpty || utf8.encode(encoded).length > maximumEncodedBytes) {
      throw const FormatException('Invalid account session size.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on Object {
      throw const FormatException('Invalid account session document.');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['version'] != schemaVersion) {
      throw const FormatException('Unsupported account session version.');
    }
    final identityJson = decoded['identity'];
    final profileJson = decoded['profile'];
    final clientJson = decoded['client'];
    if (identityJson is! Map<String, Object?> ||
        profileJson is! Map<String, Object?> ||
        clientJson is! Map<String, Object?>) {
      throw const FormatException('Invalid account session document.');
    }
    final validatedAtValue = _requiredString(
      decoded,
      'validatedAt',
      maximumLength: 64,
    );
    final validatedAt = DateTime.tryParse(validatedAtValue);
    if (validatedAt == null) {
      throw const FormatException('Invalid account validation date.');
    }
    return YouTubeMusicSessionCredential(
      cookieHeader: _requiredString(
        decoded,
        'cookieHeader',
        maximumLength: 64 * 1024,
        trim: false,
      ),
      identity: YouTubeMusicAuthIdentity.fromJson(identityJson),
      profile: YouTubeMusicAccountProfile.fromJson(profileJson),
      validatedAt: validatedAt.toUtc(),
      apiKey: _requiredString(clientJson, 'apiKey', maximumLength: 512),
      clientVersion: _requiredString(
        clientJson,
        'clientVersion',
        maximumLength: 128,
      ),
      clientName: _requiredString(clientJson, 'clientName', maximumLength: 64),
      region: _optionalRegion(
        _optionalString(clientJson, 'region', maximumLength: 8),
      ),
    );
  }

  @override
  String toString() =>
      'YouTubeMusicSessionCredential(profile: $profile, '
      'validatedAt: ${validatedAt.toUtc().toIso8601String()}, '
      'secrets: [REDACTED])';
}

String _requiredString(
  Map<String, Object?> json,
  String key, {
  required int maximumLength,
  bool trim = true,
}) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Missing or invalid $key.');
  }
  final normalized = trim ? value.trim() : value;
  if (normalized.isEmpty || normalized.length > maximumLength) {
    throw FormatException('Missing or invalid $key.');
  }
  return normalized;
}

String? _optionalString(
  Map<String, Object?> json,
  String key, {
  required int maximumLength,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('Invalid $key.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty) return null;
  if (normalized.length > maximumLength) {
    throw FormatException('Invalid $key.');
  }
  return normalized;
}

String _requiredProtocolValue(
  String value,
  String name, {
  required int maximumLength,
}) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > maximumLength ||
      !RegExp(r'^[0-9A-Za-z._-]+$').hasMatch(normalized)) {
    throw FormatException('Invalid YouTube Music $name.');
  }
  return normalized;
}

String? _optionalRegion(String? value) {
  final normalized = value?.trim().toUpperCase();
  if (normalized == null || normalized.isEmpty) return null;
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(normalized)) {
    throw FormatException('Invalid YouTube Music region.');
  }
  return normalized;
}
