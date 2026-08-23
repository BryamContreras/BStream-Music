import 'dart:ui' show PlatformDispatcher;

import '../auth/youtube_music_auth_header_factory.dart';
import '../auth/youtube_music_auth_models.dart' as auth;
import 'youtube_music_account_transport.dart';

typedef YouTubeMusicSessionCredentialSnapshot =
    Future<auth.YouTubeMusicSessionCredential?> Function();

/// Adapts the secure auth credential snapshot to the account gateway's
/// storage-agnostic header port.
class CredentialYouTubeMusicSessionHeadersProvider
    implements YouTubeMusicSessionHeadersProvider {
  CredentialYouTubeMusicSessionHeadersProvider({
    required this.readCredential,
    YouTubeMusicAuthHeaderFactory? headerFactory,
    Map<String, String> additionalHeaders = const <String, String>{},
  }) : _headerFactory = headerFactory ?? YouTubeMusicAuthHeaderFactory(),
       _additionalHeaders = Map<String, String>.unmodifiable(additionalHeaders);

  final YouTubeMusicSessionCredentialSnapshot readCredential;
  final YouTubeMusicAuthHeaderFactory _headerFactory;
  final Map<String, String> _additionalHeaders;

  @override
  Future<YouTubeMusicSessionHeaders> headersFor(
    YouTubeMusicSessionHeaderRequest request,
  ) async {
    final credential = await readCredential();
    if (credential == null) {
      throw const YouTubeMusicAccountException(
        'No authenticated YouTube Music session is available.',
        statusCode: 401,
      );
    }
    return _headersForCredential(
      endpoint: request.endpoint,
      credential: credential,
      headerFactory: _headerFactory,
      additionalHeaders: _additionalHeaders,
    );
  }
}

/// Header provider used while validating a freshly captured WebView session,
/// before a [auth.YouTubeMusicSessionCredential] is persisted.
class WebAuthDataYouTubeMusicSessionHeadersProvider
    implements YouTubeMusicSessionHeadersProvider {
  WebAuthDataYouTubeMusicSessionHeadersProvider({
    required auth.YouTubeMusicWebAuthData authData,
    YouTubeMusicAuthHeaderFactory? headerFactory,
    Map<String, String> additionalHeaders = const <String, String>{},
  }) : _credential = _ephemeralCredential(authData),
       _headerFactory = headerFactory ?? YouTubeMusicAuthHeaderFactory(),
       _additionalHeaders = Map<String, String>.unmodifiable(additionalHeaders);

  final auth.YouTubeMusicSessionCredential _credential;
  final YouTubeMusicAuthHeaderFactory _headerFactory;
  final Map<String, String> _additionalHeaders;

  @override
  Future<YouTubeMusicSessionHeaders> headersFor(
    YouTubeMusicSessionHeaderRequest request,
  ) async {
    return _headersForCredential(
      endpoint: request.endpoint,
      credential: _credential,
      headerFactory: _headerFactory,
      additionalHeaders: _additionalHeaders,
    );
  }
}

/// Builds the authenticated WEB_REMIX context consumed by the gateway.
///
/// [clientVersion] should come from the current YouTube Music bootstrap page;
/// no stale version is hard-coded in this account module.
Map<String, Object?> buildYouTubeMusicAccountClientContext({
  required String clientVersion,
  required String clientName,
  required auth.YouTubeMusicAuthIdentity identity,
  String language = 'es-419',
  String? region,
  String? userAgent,
}) {
  final normalizedVersion = _requiredContextValue(
    clientVersion,
    'clientVersion',
  );
  final normalizedLanguage = _requiredContextValue(language, 'language');
  // Prefer the country from the authenticated page. Older credentials do
  // not contain it, so use the device locale rather than a Nicaragua-only
  // default; YouTube will still apply its own account-side region rules.
  final normalizedRegion =
      _normalizeRegion(region) ??
      _normalizeRegion(PlatformDispatcher.instance.locale.countryCode);
  final normalizedClientName = _requiredContextValue(clientName, 'clientName');
  final dataSyncId = identity.dataSyncId?.trim();
  final normalizedUserAgent = userAgent?.trim();
  return <String, Object?>{
    'client': <String, Object?>{
      'clientName': normalizedClientName,
      'clientVersion': normalizedVersion,
      'hl': normalizedLanguage,
      ...?normalizedRegion == null
          ? null
          : <String, Object?>{'gl': normalizedRegion},
      'visitorData': identity.visitorData,
      if (normalizedUserAgent != null && normalizedUserAgent.isNotEmpty)
        'userAgent': normalizedUserAgent,
    },
    'request': const <String, Object?>{
      'internalExperimentFlags': <Object?>[],
      'useSsl': true,
    },
    'user': <String, Object?>{
      'lockedSafetyMode': false,
      if (dataSyncId != null && dataSyncId.isNotEmpty)
        'onBehalfOfUser': dataSyncId,
    },
  };
}

YouTubeMusicSessionHeaders _headersForCredential({
  required String endpoint,
  required auth.YouTubeMusicSessionCredential credential,
  required YouTubeMusicAuthHeaderFactory headerFactory,
  required Map<String, String> additionalHeaders,
}) {
  if (!RegExp(r'^[a-z0-9_]+(?:/[a-z0-9_]+)*$').hasMatch(endpoint)) {
    throw const YouTubeMusicAccountException(
      'Invalid authenticated YouTube Music endpoint.',
    );
  }
  final uri = Uri.https('music.youtube.com', '/youtubei/v1/$endpoint');
  final authenticatedHeaders = headerFactory.create(uri, credential);
  if (authenticatedHeaders.isEmpty) {
    throw const YouTubeMusicAccountException(
      'Authentication headers were rejected for this origin.',
      statusCode: 401,
    );
  }
  return YouTubeMusicSessionHeaders(<String, String>{
    'Accept': 'application/json',
    'Content-Type': 'application/json',
    // Match the headers emitted by YouTube Music's WEB_REMIX client.  These
    // are public request metadata, not account secrets, and are required by
    // some account endpoints after the Google hand-off.
    'X-Goog-Api-Format-Version': '1',
    'Referer': 'https://music.youtube.com/',
    'Accept-Language': _webRemixAcceptLanguage(credential.region),
    'User-Agent': _webRemixUserAgent,
    ...additionalHeaders,
    'X-YouTube-Client-Name': credential.clientName,
    'X-YouTube-Client-Version': credential.clientVersion,
    // Auth-owned values always win over caller-supplied additions.
    ...authenticatedHeaders,
  }, apiKey: credential.apiKey);
}

const String _webRemixUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/140.0.0.0 Safari/537.36';

String _webRemixAcceptLanguage(String? region) {
  // Keep the UI language independent from the account's country.  The page
  // region is sent in the InnerTube context (`gl`), while this header remains
  // a normal browser language preference usable worldwide.
  final language = PlatformDispatcher.instance.locale.languageCode
      .trim()
      .toLowerCase();
  final normalizedLanguage = RegExp(r'^[a-z]{2,3}$').hasMatch(language)
      ? language
      : 'en';
  final normalizedRegion = _normalizeRegion(region);
  final primary = normalizedRegion == null
      ? normalizedLanguage
      : '$normalizedLanguage-${normalizedRegion.toLowerCase()}';
  return '$primary,$normalizedLanguage;q=0.9';
}

Map<String, Object?> buildYouTubeMusicAccountClientContextFromWebAuthData(
  auth.YouTubeMusicWebAuthData authData, {
  String language = 'es-419',
  String? region,
  String? userAgent,
}) {
  return buildYouTubeMusicAccountClientContext(
    clientVersion: authData.clientVersion,
    clientName: authData.clientName,
    identity: authData.identity,
    language: language,
    region: region ?? authData.region,
    userAgent: userAgent,
  );
}

Map<String, Object?> buildYouTubeMusicAccountClientContextFromCredential(
  auth.YouTubeMusicSessionCredential credential, {
  String language = 'es-419',
  String? region,
  String? userAgent,
}) {
  return buildYouTubeMusicAccountClientContext(
    clientVersion: credential.clientVersion,
    clientName: credential.clientName,
    identity: credential.identity,
    language: language,
    region: region ?? credential.region,
    userAgent: userAgent,
  );
}

auth.YouTubeMusicSessionCredential _ephemeralCredential(
  auth.YouTubeMusicWebAuthData authData,
) {
  final provisionalChannelId = _firstNonEmpty(<String?>[
    authData.identity.delegatedPageId,
    _channelIdFromDataSync(authData.identity.dataSyncId),
    'pending-account-validation',
  ])!;
  return auth.YouTubeMusicSessionCredential(
    cookieHeader: authData.cookieHeader,
    identity: authData.identity,
    profile: auth.YouTubeMusicAccountProfile(
      channelId: provisionalChannelId,
      displayName: 'Pending YouTube Music validation',
    ),
    validatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    apiKey: authData.apiKey,
    clientVersion: authData.clientVersion,
    clientName: authData.clientName,
    region: authData.region,
  );
}

String? _channelIdFromDataSync(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  for (final part in normalized.split(RegExp(r'[|,;:]'))) {
    final candidate = part.trim();
    if (candidate.startsWith('UC')) {
      return candidate;
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

String _requiredContextValue(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 4096) {
    throw ArgumentError.value(
      value,
      name,
      'Must be a bounded non-empty value.',
    );
  }
  return normalized;
}

String? _normalizeRegion(String? value) {
  final normalized = value?.trim().toUpperCase();
  if (normalized == null || normalized.isEmpty) return null;
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(normalized)) {
    throw ArgumentError.value(
      value,
      'region',
      'Must be an ISO-3166 alpha-2 code.',
    );
  }
  return normalized;
}
