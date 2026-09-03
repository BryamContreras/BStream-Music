import 'po_token_binding.dart';

/// Describes whether a client needs the web player JavaScript to turn ciphered
/// stream metadata into usable URLs.
enum InnerTubePlayerJavaScriptRequirement { notRequired, required }

/// Describes how strongly a player or media request depends on a PO token.
enum InnerTubePoTokenRequirement {
  notRequired,
  optional,
  recommended,
  required,
}

/// The family of token a client accepts.
///
/// A platform token cannot be substituted with a token produced by WebPO.
enum InnerTubePoTokenProvider { none, web, platform }

/// Controls where a profile may participate without callers hard-coding keys.
///
/// [fallbackOnly] profiles have enough evidence to protect production when the
/// preferred identities fail, but are deliberately excluded from automatic
/// primary recommendations (for example, when content coverage is narrower).
enum InnerTubeClientAvailability {
  stable,
  fallbackOnly,
  experimental,
  disabled,
}

/// Runtime requirements that are intentionally kept separate from client
/// identity and request metadata.
final class InnerTubeClientCapabilities {
  const InnerTubeClientCapabilities({
    required this.playerJavaScript,
    required this.playerPoToken,
    required this.streamingDataPoToken,
    required this.poTokenProvider,
    this.playerPoTokenBinding = YoutubePoTokenBinding.videoId,
    this.streamingDataPoTokenBindings = const <YoutubePoTokenBinding>[
      YoutubePoTokenBinding.visitorData,
    ],
    this.supportsDash = true,
    this.supportsHls = true,
  });

  final InnerTubePlayerJavaScriptRequirement playerJavaScript;
  final InnerTubePoTokenRequirement playerPoToken;
  final InnerTubePoTokenRequirement streamingDataPoToken;
  final InnerTubePoTokenProvider poTokenProvider;
  final YoutubePoTokenBinding playerPoTokenBinding;
  final List<YoutubePoTokenBinding> streamingDataPoTokenBindings;
  final bool supportsDash;
  final bool supportsHls;

  bool get requiresPlayerJavaScript {
    return playerJavaScript == InnerTubePlayerJavaScriptRequirement.required;
  }

  bool get supportsWebPo {
    return poTokenProvider == InnerTubePoTokenProvider.web;
  }

  bool get unsupportedByWebPo {
    return poTokenProvider == InnerTubePoTokenProvider.platform;
  }

  bool get mayNeedPoToken {
    return playerPoToken != InnerTubePoTokenRequirement.notRequired ||
        streamingDataPoToken != InnerTubePoTokenRequirement.notRequired;
  }
}

/// Immutable identity and request context for one InnerTube player client.
///
/// Profile values are isolated here because YouTube changes them independently
/// from parsing and fallback logic.
final class InnerTubeClientProfile {
  const InnerTubeClientProfile({
    required this.key,
    required this.clientName,
    required this.clientVersion,
    required this.clientId,
    required this.host,
    required this.origin,
    required this.userAgent,
    required this.capabilities,
    required this.availability,
    this.isEmbedded = false,
    this.allowDynamicClientVersion = true,
    this.contextValues = const <String, Object?>{},
    this.requestContextValues = const <String, Object?>{},
  });

  final String key;
  final String clientName;
  final String clientVersion;
  final int clientId;
  final String host;
  final String origin;
  final String userAgent;
  final InnerTubeClientCapabilities capabilities;
  final InnerTubeClientAvailability availability;
  final bool isEmbedded;

  /// Whether a matching page bootstrap may replace [clientVersion] for one
  /// player request. Version-pinned escape hatches disable this so they remain
  /// behaviorally distinct from the current client advertised by YouTube.
  final bool allowDynamicClientVersion;
  final Map<String, Object?> contextValues;
  final Map<String, Object?> requestContextValues;

  bool get isEnabled {
    return availability != InnerTubeClientAvailability.disabled;
  }

  bool get isExperimental {
    return availability == InnerTubeClientAvailability.experimental;
  }

  bool get isFallbackOnly {
    return availability == InnerTubeClientAvailability.fallbackOnly;
  }

  Uri get playerEndpoint {
    return Uri.https(host, '/youtubei/v1/player', const <String, String>{
      'prettyPrint': 'false',
    });
  }

  Map<String, String> get requestHeaders {
    return Map<String, String>.unmodifiable(<String, String>{
      'Accept': '*/*',
      'Content-Type': 'application/json',
      'Origin': origin,
      'Referer': '$origin/',
      'User-Agent': userAgent,
      'X-Goog-Api-Format-Version': '1',
      'X-Origin': origin,
      'X-YouTube-Client-Name': clientId.toString(),
      'X-YouTube-Client-Version': clientVersion,
    });
  }

  Map<String, Object?> buildClientContext({
    String language = 'en',
    String region = 'US',
    String? visitorData,
  }) {
    final client = <String, Object?>{
      ...contextValues,
      'clientName': clientName,
      'clientVersion': clientVersion,
      'userAgent': userAgent,
      'hl': language,
      'gl': region,
    };
    if (visitorData != null && visitorData.trim().isNotEmpty) {
      client['visitorData'] = visitorData.trim();
    }
    return Map<String, Object?>.unmodifiable(client);
  }

  Map<String, Object?> buildContext({
    String language = 'en',
    String region = 'US',
    String? visitorData,
  }) {
    return Map<String, Object?>.unmodifiable(<String, Object?>{
      ...requestContextValues,
      'client': buildClientContext(
        language: language,
        region: region,
        visitorData: visitorData,
      ),
    });
  }

  @override
  String toString() => '$key ($clientName $clientVersion)';
}

/// Curated player profiles and their fallback/benchmark ordering.
///
/// These values are request metadata, not an assertion that a given client
/// will remain accepted indefinitely. The runtime should record failures and
/// benchmark enabled candidates.
abstract final class InnerTubeClientRegistry {
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/140.0.0.0 Safari/537.36';

  static const InnerTubeClientProfile androidSdkless = InnerTubeClientProfile(
    key: 'androidSdkless',
    clientName: 'ANDROID',
    clientVersion: '21.26.364',
    clientId: 3,
    host: 'www.youtube.com',
    origin: 'https://www.youtube.com',
    userAgent:
        'com.google.android.youtube/21.26.364 '
        '(Linux; U; Android 11) gzip',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.notRequired,
      playerPoToken: InnerTubePoTokenRequirement.notRequired,
      streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
      poTokenProvider: InnerTubePoTokenProvider.none,
    ),
    // Kept behind a deep GVS byte-range probe on every resolution. If
    // selective POT enforcement reaches this SDK-less variant, the router
    // immediately continues with VisionOS.
    availability: InnerTubeClientAvailability.stable,
    contextValues: <String, Object?>{'osName': 'Android', 'osVersion': '11'},
  );

  static const InnerTubeClientProfile visionOS = InnerTubeClientProfile(
    key: 'visionOS',
    clientName: 'VISIONOS',
    clientVersion: '1.02',
    clientId: 101,
    host: 'music.youtube.com',
    origin: 'https://music.youtube.com',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/26.0 Safari/605.1.15',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.notRequired,
      playerPoToken: InnerTubePoTokenRequirement.notRequired,
      streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
      poTokenProvider: InnerTubePoTokenProvider.none,
    ),
    availability: InnerTubeClientAvailability.stable,
    contextValues: <String, Object?>{
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice17,1',
      'osName': 'visionOS',
      'osVersion': '26.5.23O471',
    },
  );

  /// Older VisionOS identity kept separate from the unreleased 1.02 profile.
  /// It passed BStream's full raw deep-range corpus, but remains fallback-only
  /// because its known content coverage is narrower than the primary profile.
  static const InnerTubeClientProfile visionOS01 = InnerTubeClientProfile(
    key: 'visionOS01',
    clientName: 'VISIONOS',
    clientVersion: '0.1',
    clientId: 101,
    host: 'music.youtube.com',
    origin: 'https://music.youtube.com',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) '
        'Version/17.5 Safari/605.1.15',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.notRequired,
      playerPoToken: InnerTubePoTokenRequirement.notRequired,
      streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
      poTokenProvider: InnerTubePoTokenProvider.none,
    ),
    availability: InnerTubeClientAvailability.fallbackOnly,
    contextValues: <String, Object?>{
      'deviceMake': 'Apple',
      'deviceModel': 'RealityDevice14,1',
      'osName': 'VISION_OS',
      'osVersion': '1.3',
      'platform': 'MOBILE',
    },
  );

  static const InnerTubeClientProfile webMusic = InnerTubeClientProfile(
    key: 'webMusic',
    clientName: 'WEB_REMIX',
    clientVersion: '1.20260707.12.00',
    clientId: 67,
    host: 'music.youtube.com',
    origin: 'https://music.youtube.com',
    userAgent: _desktopUserAgent,
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.required,
      playerPoToken: InnerTubePoTokenRequirement.optional,
      streamingDataPoToken: InnerTubePoTokenRequirement.required,
      poTokenProvider: InnerTubePoTokenProvider.web,
      playerPoTokenBinding: YoutubePoTokenBinding.visitorData,
      streamingDataPoTokenBindings: <YoutubePoTokenBinding>[
        YoutubePoTokenBinding.videoId,
        YoutubePoTokenBinding.visitorData,
      ],
    ),
    availability: InnerTubeClientAvailability.stable,
    contextValues: <String, Object?>{'osName': 'Windows', 'osVersion': '10.0'},
  );

  /// Tokenless TV identity retained for live probes. Current signed-out
  /// sessions return `UNPLAYABLE` before EJS, so it must not add cold-start
  /// latency to the production ladder until the resolved matrix recovers.
  static const InnerTubeClientProfile tv = InnerTubeClientProfile(
    key: 'tv',
    clientName: 'TVHTML5',
    clientVersion: '7.20260707.07.00',
    clientId: 7,
    host: 'www.youtube.com',
    origin: 'https://www.youtube.com',
    userAgent:
        'Mozilla/5.0 (ChromiumStylePlatform) '
        'Cobalt/25.lts.30.1034943-gold (unlike Gecko), '
        'Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.required,
      playerPoToken: InnerTubePoTokenRequirement.notRequired,
      streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
      poTokenProvider: InnerTubePoTokenProvider.none,
    ),
    availability: InnerTubeClientAvailability.experimental,
  );

  /// Lower-version TV identity retained as an independent probe when current
  /// Cobalt behavior rotates.
  static const InnerTubeClientProfile tvDowngraded = InnerTubeClientProfile(
    key: 'tvDowngraded',
    clientName: 'TVHTML5',
    clientVersion: '5.20260707',
    clientId: 7,
    host: 'www.youtube.com',
    origin: 'https://www.youtube.com',
    userAgent: 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.required,
      playerPoToken: InnerTubePoTokenRequirement.notRequired,
      streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
      poTokenProvider: InnerTubePoTokenProvider.none,
    ),
    availability: InnerTubeClientAvailability.experimental,
    allowDynamicClientVersion: false,
    contextValues: <String, Object?>{
      'userAgent': 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
    },
  );

  /// Embedded Web profile. It is restricted to embeddable videos but remains
  /// a useful tokenless fallback before WebPO-backed profiles.
  static const InnerTubeClientProfile webEmbedded = InnerTubeClientProfile(
    key: 'webEmbedded',
    clientName: 'WEB_EMBEDDED_PLAYER',
    clientVersion: '2.20260708.00.00',
    clientId: 56,
    host: 'www.youtube.com',
    origin: 'https://www.youtube.com',
    userAgent: _desktopUserAgent,
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.required,
      playerPoToken: InnerTubePoTokenRequirement.notRequired,
      streamingDataPoToken: InnerTubePoTokenRequirement.notRequired,
      poTokenProvider: InnerTubePoTokenProvider.none,
    ),
    availability: InnerTubeClientAvailability.stable,
    isEmbedded: true,
  );

  /// Web-cipher TV client with visitor-bound player attestation and a
  /// video-bound GVS token. It stays experimental until the resolved matrix
  /// proves sustained media access across the supported WebView platforms.
  static const InnerTubeClientProfile tvSimply = InnerTubeClientProfile(
    key: 'tvSimply',
    clientName: 'TVHTML5_SIMPLY',
    clientVersion: '1.0',
    clientId: 75,
    host: 'music.youtube.com',
    origin: 'https://music.youtube.com',
    userAgent:
        'Mozilla/5.0 (ChromiumStylePlatform) '
        'Cobalt/25.lts.30.1034943-gold (unlike Gecko), '
        'Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.required,
      playerPoToken: InnerTubePoTokenRequirement.required,
      streamingDataPoToken: InnerTubePoTokenRequirement.required,
      poTokenProvider: InnerTubePoTokenProvider.web,
      playerPoTokenBinding: YoutubePoTokenBinding.visitorData,
      streamingDataPoTokenBindings: <YoutubePoTokenBinding>[
        YoutubePoTokenBinding.videoId,
      ],
    ),
    availability: InnerTubeClientAvailability.experimental,
  );

  /// Ordinary WEB currently exposes SABR-only media in signed-out sessions.
  /// Keep it measurable but out of the direct-HTTPS ladder until SABR exists.
  static const InnerTubeClientProfile web = InnerTubeClientProfile(
    key: 'web',
    clientName: 'WEB',
    clientVersion: '2.20260708.00.00',
    clientId: 1,
    host: 'www.youtube.com',
    origin: 'https://www.youtube.com',
    userAgent: _desktopUserAgent,
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.required,
      playerPoToken: InnerTubePoTokenRequirement.optional,
      streamingDataPoToken: InnerTubePoTokenRequirement.required,
      poTokenProvider: InnerTubePoTokenProvider.web,
      playerPoTokenBinding: YoutubePoTokenBinding.videoId,
      streamingDataPoTokenBindings: <YoutubePoTokenBinding>[
        YoutubePoTokenBinding.videoId,
        YoutubePoTokenBinding.visitorData,
      ],
    ),
    availability: InnerTubeClientAvailability.experimental,
    contextValues: <String, Object?>{'osName': 'Windows', 'osVersion': '10.0'},
  );

  /// Mobile Web is the preferred WebPO fallback because ordinary WEB often
  /// exposes only SABR formats. Values track the maintained MWEB client.
  static const InnerTubeClientProfile mweb = InnerTubeClientProfile(
    key: 'mweb',
    clientName: 'MWEB',
    clientVersion: '2.20260708.05.00',
    clientId: 2,
    host: 'm.youtube.com',
    origin: 'https://m.youtube.com',
    userAgent:
        'Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 '
        'Mobile/15E148 Safari/604.1,gzip(gfe)',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.required,
      playerPoToken: InnerTubePoTokenRequirement.optional,
      streamingDataPoToken: InnerTubePoTokenRequirement.required,
      poTokenProvider: InnerTubePoTokenProvider.web,
      playerPoTokenBinding: YoutubePoTokenBinding.videoId,
      streamingDataPoTokenBindings: <YoutubePoTokenBinding>[
        YoutubePoTokenBinding.videoId,
        YoutubePoTokenBinding.visitorData,
      ],
    ),
    availability: InnerTubeClientAvailability.stable,
  );

  static const InnerTubeClientProfile ios = InnerTubeClientProfile(
    key: 'ios',
    clientName: 'IOS',
    clientVersion: '21.26.4',
    clientId: 5,
    host: 'www.youtube.com',
    origin: 'https://www.youtube.com',
    userAgent:
        'com.google.ios.youtube/21.26.4 '
        '(iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.notRequired,
      playerPoToken: InnerTubePoTokenRequirement.optional,
      streamingDataPoToken: InnerTubePoTokenRequirement.required,
      poTokenProvider: InnerTubePoTokenProvider.platform,
    ),
    availability: InnerTubeClientAvailability.stable,
    contextValues: <String, Object?>{
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osName': 'iPhone',
      'osVersion': '18.3.2.22D82',
    },
  );

  static const InnerTubeClientProfile androidVr = InnerTubeClientProfile(
    key: 'androidVr',
    clientName: 'ANDROID_VR',
    clientVersion: '1.65.10',
    clientId: 28,
    host: 'www.youtube.com',
    origin: 'https://www.youtube.com',
    userAgent:
        'com.google.android.apps.youtube.vr.oculus/1.65.10 '
        '(Linux; U; Android 12L; '
        'eureka-user Build/SQ3A.220605.009.A1) gzip',
    capabilities: InnerTubeClientCapabilities(
      playerJavaScript: InnerTubePlayerJavaScriptRequirement.notRequired,
      playerPoToken: InnerTubePoTokenRequirement.optional,
      streamingDataPoToken: InnerTubePoTokenRequirement.required,
      poTokenProvider: InnerTubePoTokenProvider.platform,
    ),
    availability: InnerTubeClientAvailability.disabled,
    contextValues: <String, Object?>{
      'androidSdkVersion': 32,
      'deviceMake': 'Oculus',
      'deviceModel': 'Quest 3',
      'osName': 'Android',
      'osVersion': '12L',
    },
  );

  /// Fastest unrestricted profile in the repository's repeated deep-range
  /// benchmark. The slightly faster VisionOS 0.1 identity is fallback-only
  /// because its known content coverage is narrower.
  static const InnerTubeClientProfile primary = visionOS;

  /// Enabled production fallback order.
  ///
  /// Experimental and platform-token-only clients are excluded. They remain
  /// available through [benchmarkCandidates] and [all].
  static const List<InnerTubeClientProfile> defaults = <InnerTubeClientProfile>[
    visionOS,
    androidSdkless,
    visionOS01,
    webEmbedded,
    mweb,
    webMusic,
  ];

  /// Enabled clients that can be measured before runtime capability filtering.
  static const List<InnerTubeClientProfile> benchmarkCandidates =
      <InnerTubeClientProfile>[
        androidSdkless,
        visionOS01,
        visionOS,
        tv,
        tvDowngraded,
        webEmbedded,
        tvSimply,
        mweb,
        webMusic,
        web,
        ios,
      ];

  /// Every known profile. Disabled profiles are always last.
  static const List<InnerTubeClientProfile> all = <InnerTubeClientProfile>[
    androidSdkless,
    visionOS01,
    visionOS,
    tv,
    tvDowngraded,
    webEmbedded,
    tvSimply,
    mweb,
    webMusic,
    web,
    ios,
    androidVr,
  ];

  static InnerTubeClientProfile? byKey(String key) {
    for (final profile in all) {
      if (profile.key == key) {
        return profile;
      }
    }
    return null;
  }
}
