import 'dart:io';
import 'dart:math';

const _userAgents = [
  'Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:138.0) Gecko/20100101 Firefox/138.0',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 14.7; rv:139.0) Gecko/20100101 Firefox/139.0',
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
];

final _rng = Random();

String randomUa() => _userAgents[_rng.nextInt(_userAgents.length)];

String systemTimezone() {
  // Try TZ env var first
  final tz = Platform.environment['TZ'];
  if (tz != null && tz.contains('/') && tz.trim().isNotEmpty) {
    return tz.trim();
  }

  // Try /etc/timezone (Debian/Ubuntu)
  try {
    final contents = File('/etc/timezone').readAsStringSync().trim();
    if (contents.contains('/') && contents.isNotEmpty) return contents;
  } on FileSystemException {
    // not available
  }

  // Try /etc/localtime symlink
  try {
    final target = Link('/etc/localtime').resolveSymbolicLinksSync();
    final parts = target.split('/zoneinfo/');
    if (parts.length >= 2 && parts[1].isNotEmpty) return parts[1];
  } on FileSystemException {
    // not available
  }

  return 'UTC';
}

/// Returns `(language, region)` from system locale.
/// Uses `Platform.localeName`, falls back to `('en', 'US')`.
(String, String) systemLocale() {
  try {
    final raw = Platform.localeName; // e.g. "en_US", "ro_RO.UTF-8"
    if (raw.isEmpty || raw == 'C' || raw == 'POSIX') return ('en', 'US');
    return _parsePosixLocale(raw);
  } on UnsupportedError {
    return ('en', 'US');
  }
}

String systemLanguage() => systemLocale().$1;
String systemRegion() => systemLocale().$2;

(String, String) _parsePosixLocale(String s) {
  // strip encoding: "en_US.UTF-8" -> "en_US"
  final base = s.split('.').first;
  // split on _ or -
  final match = RegExp(r'^([a-zA-Z]{2,})[_-]([a-zA-Z]+)').firstMatch(base);
  if (match != null) {
    return (match.group(1)!.toLowerCase(), match.group(2)!.toUpperCase());
  }
  if (base.length >= 2) return (base.toLowerCase(), 'US');
  return ('en', 'US');
}
