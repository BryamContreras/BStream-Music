import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../js_challenge.dart';
import 'ejs.dart';

/// Base class for EJS solvers that handles common caching and parsing logic.
/// Subclasses must implement [executeJavaScript] to provide the JS engine-specific execution.
abstract class BaseEJSSolver extends BaseJSChallengeSolver {
  BaseEJSSolver({
    http.Client? httpClient,
    this.playerRequestTimeout = const Duration(seconds: 15),
    this.cacheTtl = const Duration(hours: 6),
    this.maxCacheEntries = 32,
  })  : _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null {
    if (playerRequestTimeout <= Duration.zero) {
      throw ArgumentError.value(
        playerRequestTimeout,
        'playerRequestTimeout',
        'Must be positive.',
      );
    }
    if (cacheTtl <= Duration.zero) {
      throw ArgumentError.value(cacheTtl, 'cacheTtl', 'Must be positive.');
    }
    if (maxCacheEntries <= 0) {
      throw ArgumentError.value(
        maxCacheEntries,
        'maxCacheEntries',
        'Must be positive.',
      );
    }
  }

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration playerRequestTimeout;
  final Duration cacheTtl;
  final int maxCacheEntries;

  final _playerCache = <String, _CacheEntry<String>>{};
  final _sigCache = <(String, String, JSChallengeType), _CacheEntry<String>>{};
  final _preprocPlayer = <String, _CacheEntry<String>>{};
  Future<void> _queueTail = Future<void>.value();
  bool _disposed = false;

  /// Executes JavaScript code and returns the JSON string result.
  Future<String> executeJavaScript(String jsCode);

  @override
  Future<Map<String, String?>> solveBulk(
      String playerUrl, Map<JSChallengeType, List<String>> requests) async {
    return _enqueue(() => _solveBulk(playerUrl, requests));
  }

  Future<Map<String, String?>> _solveBulk(
      String playerUrl, Map<JSChallengeType, List<String>> requests) async {
    // Filter out already cached challenges
    final uncachedRequests = <JSChallengeType, List<String>>{};
    final cachedResults = <String, String?>{};

    for (final entry in requests.entries) {
      final type = entry.key;
      final challenges = entry.value;
      final uncached = <String>[];

      for (final challenge in challenges) {
        final key = (playerUrl, challenge, type);
        final cached = _readCache(_sigCache, key);
        if (cached != null) {
          cachedResults[challenge] = cached;
        } else {
          uncached.add(challenge);
        }
      }

      if (uncached.isNotEmpty) {
        uncachedRequests[type] = uncached;
      }
    }

    // If all challenges are cached, return early
    if (uncachedRequests.isEmpty) {
      return cachedResults;
    }

    // Get player script (from cache or fetch)
    late String playerScript;
    var isPreprocessed = false;
    final preprocessed = _readCache(_preprocPlayer, playerUrl);
    if (preprocessed != null) {
      playerScript = preprocessed;
      isPreprocessed = true;
    } else {
      final cachedPlayer = _readCache(_playerCache, playerUrl);
      if (cachedPlayer != null) {
        playerScript = cachedPlayer;
      } else {
        final response = await _httpClient
            .get(Uri.parse(playerUrl))
            .timeout(playerRequestTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw http.ClientException(
            'Player script returned HTTP ${response.statusCode}.',
            Uri.parse(playerUrl),
          );
        }
        playerScript = response.body;
        _writeCache(_playerCache, playerUrl, playerScript);
      }
    }

    final jsCall = EJSBuilder.buildJSCall(playerScript, uncachedRequests,
        isPreprocessed: isPreprocessed);

    final resultJson = await executeJavaScript(jsCall);

    final data = json.decode(resultJson) as Map<String, dynamic>;

    if (data['type'] != 'result') {
      throw Exception('Unexpected response type: ${data['type']}');
    }

    // Store preprocessed player if available
    if (data['preprocessed_player'] != null) {
      _writeCache(
        _preprocPlayer,
        playerUrl,
        data['preprocessed_player'] as String,
      );
    }

    // Process all responses
    final responses = data['responses'] as List;
    for (final response in responses) {
      if (response['type'] != 'result') {
        throw Exception('Unexpected item response type: ${response['type']}');
      }

      final responseData = response['data'] as Map<String, dynamic>;
      for (final entry in responseData.entries) {
        final challenge = entry.key;
        final decoded = entry.value as String?;

        // Find the type for this challenge
        JSChallengeType? challengeType;
        for (final typeEntry in uncachedRequests.entries) {
          if (typeEntry.value.contains(challenge)) {
            challengeType = typeEntry.key;
            break;
          }
        }

        if (challengeType != null) {
          final key = (playerUrl, challenge, challengeType);
          if (decoded != null) {
            _writeCache(_sigCache, key, decoded);
            cachedResults[challenge] = decoded;
          } else {
            cachedResults[challenge] = null;
          }
        }
      }
    }

    return cachedResults;
  }

  @override
  Future<String> solve(
      String playerUrl, JSChallengeType type, String challenge) async {
    final key = (playerUrl, challenge, type);
    final cached = _readCache(_sigCache, key);
    if (cached != null) {
      return cached;
    }

    final results = await solveBulk(playerUrl, {
      type: [challenge]
    });
    final decoded = results[challenge];
    if (decoded == null) {
      throw Exception('No data for challenge: $challenge');
    }
    return decoded;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _queueTail;
    _queueTail = () async {
      // One failed solve must not permanently poison the shared queue.
      try {
        await previous;
      } catch (_) {}

      if (_disposed) {
        completer.completeError(StateError('The JS solver was disposed.'));
        return;
      }

      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }

  T? _readCache<K, T>(Map<K, _CacheEntry<T>> cache, K key) {
    final entry = cache[key];
    if (entry == null) {
      return null;
    }
    if (entry.expiresAt.isBefore(DateTime.now())) {
      cache.remove(key);
      return null;
    }

    // Refresh insertion order so active entries survive bounded eviction.
    cache.remove(key);
    cache[key] = entry;
    return entry.value;
  }

  void _writeCache<K, T>(
    Map<K, _CacheEntry<T>> cache,
    K key,
    T value,
  ) {
    cache.remove(key);
    cache[key] = _CacheEntry(value, DateTime.now().add(cacheTtl));
    while (cache.length > maxCacheEntries) {
      cache.remove(cache.keys.first);
    }
  }
}

class _CacheEntry<T> {
  const _CacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;
}
