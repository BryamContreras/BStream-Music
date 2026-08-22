import 'dart:convert';

/// Strict parser/canonicalizer for cookies applicable to YouTube Music.
class YouTubeMusicCookieCodec {
  const YouTubeMusicCookieCodec({
    this.maximumBytes = 64 * 1024,
    this.maximumCookies = 128,
  });

  static final RegExp _cookieName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

  final int maximumBytes;
  final int maximumCookies;

  Map<String, String> decode(String rawHeader) {
    if (rawHeader.isEmpty || utf8.encode(rawHeader).length > maximumBytes) {
      throw const FormatException('Invalid YouTube Music cookie header size.');
    }
    if (_controlCharacters.hasMatch(rawHeader)) {
      throw const FormatException('Invalid YouTube Music cookie header.');
    }

    final result = <String, String>{};
    final parts = rawHeader.split(';');
    if (parts.length > maximumCookies) {
      throw const FormatException('Too many YouTube Music cookies.');
    }
    for (final rawPart in parts) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;
      final separator = part.indexOf('=');
      if (separator <= 0) {
        throw const FormatException('Invalid YouTube Music cookie.');
      }
      final name = part.substring(0, separator).trim();
      final value = part.substring(separator + 1).trim();
      if (!_cookieName.hasMatch(name) ||
          value.isEmpty ||
          value.contains(';') ||
          _controlCharacters.hasMatch(value)) {
        throw const FormatException('Invalid YouTube Music cookie.');
      }
      if (result.containsKey(name)) {
        throw const FormatException('Duplicate YouTube Music cookie.');
      }
      result[name] = value;
    }
    if (result.isEmpty || !hasSigningCookie(result)) {
      throw const FormatException('Missing YouTube Music session cookie.');
    }
    return Map<String, String>.unmodifiable(result);
  }

  String encode(Map<String, String> cookies) {
    if (cookies.isEmpty || cookies.length > maximumCookies) {
      throw const FormatException('Invalid YouTube Music cookies.');
    }
    final entries = cookies.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in entries) {
      if (!_cookieName.hasMatch(entry.key) ||
          entry.value.isEmpty ||
          entry.value.contains(';') ||
          _controlCharacters.hasMatch(entry.value)) {
        throw const FormatException('Invalid YouTube Music cookie.');
      }
    }
    if (!hasSigningCookie(cookies)) {
      throw const FormatException('Missing YouTube Music session cookie.');
    }
    final encoded = entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
    if (utf8.encode(encoded).length > maximumBytes) {
      throw const FormatException('Invalid YouTube Music cookie header size.');
    }
    return encoded;
  }

  String canonicalize(String rawHeader) => encode(decode(rawHeader));

  bool hasSigningCookie(Map<String, String> cookies) =>
      _nonEmpty(cookies['SAPISID']) ||
      _nonEmpty(cookies['__Secure-1PAPISID']) ||
      _nonEmpty(cookies['__Secure-3PAPISID']);

  bool _nonEmpty(String? value) => value != null && value.trim().isNotEmpty;
}
