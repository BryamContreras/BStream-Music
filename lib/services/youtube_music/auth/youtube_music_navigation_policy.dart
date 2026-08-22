enum YouTubeMusicNavigationDecision { allow, cancel }

/// Exact-host policy for the main document of the account WebView.
class YouTubeMusicNavigationPolicy {
  const YouTubeMusicNavigationPolicy({this.allowedHosts = defaultAllowedHosts});

  static const Set<String> defaultAllowedHosts = <String>{
    'accounts.google.com',
    'consent.google.com',
    'accounts.youtube.com',
    'consent.youtube.com',
    'music.youtube.com',
  };

  final Set<String> allowedHosts;

  YouTubeMusicNavigationDecision evaluate(
    Uri? uri, {
    required bool isMainFrame,
  }) {
    if (uri == null) return YouTubeMusicNavigationDecision.cancel;
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

    return allowedHosts.contains(uri.host.toLowerCase())
        ? YouTubeMusicNavigationDecision.allow
        : YouTubeMusicNavigationDecision.cancel;
  }

  bool isYouTubeMusicDocument(Uri? uri) =>
      uri != null &&
      uri.scheme.toLowerCase() == 'https' &&
      uri.host.toLowerCase() == 'music.youtube.com' &&
      uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443);
}
