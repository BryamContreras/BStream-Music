enum YouTubeMusicNavigationDecision { allow, cancel }

/// Exact-host policy for the main document of the account WebView.
class YouTubeMusicNavigationPolicy {
  const YouTubeMusicNavigationPolicy({this.allowedHosts = defaultAllowedHosts});

  static const Set<String> defaultAllowedHosts = <String>{
    'accounts.google.com',
    'consent.google.com',
    'accounts.youtube.com',
    'consent.youtube.com',
    // Google may move the sign-in continuation through these exact hosts.
    // Keep this an exact-host list; never accept arbitrary *.google.com or
    // *.youtube.com descendants in the main frame.
    'www.google.com',
    'ogs.google.com',
    'gds.google.com',
    'myaccount.google.com',
    'music.youtube.com',
    'www.youtube.com',
    'youtube.com',
    'm.youtube.com',
    // Exact hosts used by Google's account hand-off on some devices.
    'play.google.com',
    'accounts.googleusercontent.com',
    'oauthaccountmanager.googleapis.com',
    // The Android password-manager hand-off can briefly use this exact host
    // before returning to the YouTube Music origin.
    'passwords.google.com',
  };

  static const Set<String> safeAuthContinuationHosts = <String>{
    'play.google.com',
    'accounts.googleusercontent.com',
    'oauthaccountmanager.googleapis.com',
    'passwords.google.com',
  };

  final Set<String> allowedHosts;

  static String _hostOf(Uri uri) =>
      uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  // Google occasionally serves the account hand-off from its country-code
  // domain (for example accounts.google.com.ni). Restrict this exception to
  // Google's known account/consent labels and a two-letter country code; do
  // not turn it into a general suffix allow-list.
  static bool _isRegionalAccountHost(String host) => RegExp(
    r'^(accounts|consent)\.(google|youtube)\.com\.[a-z]{2}$',
  ).hasMatch(host);

  /// Parses only the narrowly scoped Google intent hand-off. Arbitrary
  /// intents are never launched from the login WebView.
  Uri? safeIntentDestination(String? rawUrl) {
    final raw = rawUrl?.trim();
    if (raw == null || !raw.toLowerCase().startsWith('intent://')) {
      return null;
    }
    final marker = raw.toLowerCase().indexOf('#intent;');
    final authorityAndPath = raw.substring(
      'intent://'.length,
      marker < 0 ? raw.length : marker,
    );
    final destination = Uri.tryParse('https://$authorityAndPath');
    final destinationHost = destination == null ? '' : _hostOf(destination);
    if (destination == null ||
        destination.userInfo.isNotEmpty ||
        (destination.hasPort && destination.port != 443) ||
        !allowedHosts.contains(destinationHost) &&
            !safeAuthContinuationHosts.contains(destinationHost) &&
            !_isRegionalAccountHost(destinationHost)) {
      return null;
    }
    return destination;
  }

  bool isSafeAuthContinuation(Uri? uri) =>
      uri != null && safeAuthContinuationHosts.contains(_hostOf(uri));

  YouTubeMusicNavigationDecision evaluate(
    Uri? uri, {
    required bool isMainFrame,
  }) {
    if (uri == null) return YouTubeMusicNavigationDecision.cancel;
    // Google occasionally sends the sign-in surface through an intermediate
    // about:blank document. It contains no network content and is safe to
    // keep inside the private WebView while the next HTTPS navigation starts.
    if (uri.scheme.toLowerCase() == 'about' &&
        uri.path.toLowerCase() == 'blank' &&
        uri.host.isEmpty) {
      return YouTubeMusicNavigationDecision.allow;
    }
    if (uri.scheme.toLowerCase() != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return YouTubeMusicNavigationDecision.cancel;
    }

    // Google authentication uses HTTPS subframes and resources from several
    // rotating CDNs. They cannot expose native functionality because this
    // WebView deliberately installs no JavaScript bridge.
    if (!isMainFrame) return YouTubeMusicNavigationDecision.allow;

    final host = _hostOf(uri);
    if (allowedHosts.contains(host)) {
      return YouTubeMusicNavigationDecision.allow;
    }

    // Keep the main-frame policy bounded to Google/YouTube-owned origins.
    // Their sign-in flow has used rotating subdomains and intermediate
    // account surfaces; rejecting those after the password is entered leaves
    // the WebView in the exact blocked state users reported. No credentials
    // are injected into these pages and cookie extraction still accepts only
    // youtube.com domains after the flow returns to Music.
    if (host == 'google.com' ||
        host.endsWith('.google.com') ||
        host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        _isRegionalAccountHost(host)) {
      return YouTubeMusicNavigationDecision.allow;
    }
    return YouTubeMusicNavigationDecision.cancel;
  }

  bool isYouTubeMusicDocument(Uri? uri) =>
      uri != null &&
      uri.scheme.toLowerCase() == 'https' &&
      _hostOf(uri) == 'music.youtube.com' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);

  /// Google sometimes completes the account hand-off on the regular YouTube
  /// origin before redirecting back to Music. Keep this exact-host list
  /// bounded; it must not become a wildcard for arbitrary Google pages.
  bool isYouTubeAuthDocument(Uri? uri) {
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443)) {
      return false;
    }
    const hosts = <String>{
      'music.youtube.com',
      'www.youtube.com',
      'youtube.com',
      'm.youtube.com',
    };
    return hosts.contains(_hostOf(uri));
  }
}
