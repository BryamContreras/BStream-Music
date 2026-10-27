/// Providers are tried in declaration order, regardless of selection order.
enum LyricsProvider {
  betterLyrics,
  youLyPlus,
  lrclib;

  String get code => name;

  String get label => switch (this) {
    LyricsProvider.lrclib => 'LRCLIB',
    // Keep the persisted code for compatibility; the queried backend is
    // LyricsPlus, while YouLy+ is the browser extension that uses it.
    LyricsProvider.youLyPlus => 'LyricsPlus',
    LyricsProvider.betterLyrics => 'Better Lyrics',
  };

  static Set<LyricsProvider> fromCodes(Iterable<String>? codes) {
    if (codes == null) {
      return defaultLyricsProviders;
    }
    final storedCodes = codes.toSet();
    // An explicit empty choice means no network lyrics providers. Unknown
    // codes from another app version must not silently enable other services.
    return Set<LyricsProvider>.unmodifiable(
      values.where((provider) => storedCodes.contains(provider.code)),
    );
  }
}

const defaultLyricsProviders = <LyricsProvider>{
  LyricsProvider.betterLyrics,
  LyricsProvider.youLyPlus,
  LyricsProvider.lrclib,
};
