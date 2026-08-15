import '../auth/ttwid.dart' as auth;
import '../errors.dart';
import '../http/sigi.dart';

const _defaultTtlMs = 300000; // 5 minutes
const _ttwidTimeout = Duration(seconds: 10);
const _scrapeTimeout = Duration(seconds: 15);

class _CacheEntry {
  final SigiProfile? profile;
  final PirateTokError? error;
  final int insertedAtMs;

  _CacheEntry.ok(this.profile)
    : error = null,
      insertedAtMs = DateTime.now().millisecondsSinceEpoch;

  _CacheEntry.err(this.error)
    : profile = null,
      insertedAtMs = DateTime.now().millisecondsSinceEpoch;
}

/// Cached profile fetcher — wraps sigi scraping with TTL cache + ttwid management.
class ProfileCache {
  final Map<String, _CacheEntry> _entries = {};
  String? _ttwid;
  final int _ttlMs;
  final String? _userAgent;
  final String _cookies;
  final String _proxy;
  final String? _language;
  final String? _region;

  ProfileCache({
    int ttlMs = _defaultTtlMs,
    String? userAgent,
    String cookies = '',
    String proxy = '',
    String? language,
    String? region,
  }) : _ttlMs = ttlMs,
       _userAgent = userAgent,
       _cookies = cookies,
       _proxy = proxy,
       _language = language,
       _region = region;

  /// Fetch a profile, returning cached data if available and not expired.
  Future<SigiProfile> fetch(String username) async {
    final key = _normalizeKey(username);
    final now = DateTime.now().millisecondsSinceEpoch;

    final entry = _entries[key];
    if (entry != null && (now - entry.insertedAtMs) < _ttlMs) {
      if (entry.error != null) throw entry.error!;
      return entry.profile!;
    }

    final ttwid = await _ensureTtwid();

    try {
      final profile = await scrapeProfile(
        key,
        ttwid,
        timeout: _scrapeTimeout,
        userAgent: _userAgent,
        cookies: _cookies,
        proxy: _proxy,
        language: _language,
        region: _region,
      );
      _entries[key] = _CacheEntry.ok(profile);
      return profile;
    } on PirateTokError catch (e) {
      if (e is ProfilePrivateError ||
          e is ProfileNotFoundError ||
          e is ProfileError) {
        _entries[key] = _CacheEntry.err(e);
      }
      rethrow;
    }
  }

  /// Return cached profile without fetching. Returns null on miss or expiry.
  SigiProfile? cached(String username) {
    final key = _normalizeKey(username);
    final entry = _entries[key];
    if (entry == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now - entry.insertedAtMs) >= _ttlMs) return null;
    return entry.profile;
  }

  /// Remove one entry from the cache.
  void invalidate(String username) {
    _entries.remove(_normalizeKey(username));
  }

  /// Clear the entire cache.
  void invalidateAll() {
    _entries.clear();
  }

  Future<String> _ensureTtwid() async {
    if (_ttwid != null) return _ttwid!;
    _ttwid = await auth.fetchTtwid(
      timeout: _ttwidTimeout,
      proxy: _proxy,
      userAgent: _userAgent,
    );
    return _ttwid!;
  }

  static String _normalizeKey(String username) {
    return username.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
  }
}

// ignore_for_file: prefer_initializing_formals
