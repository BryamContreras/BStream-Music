import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'youtube_music_auth_models.dart';

abstract interface class YouTubeMusicSessionStore {
  Future<YouTubeMusicSessionCredential?> read();

  Future<void> write(YouTubeMusicSessionCredential credential);

  Future<void> delete();
}

/// Minimal injectable adapter used to keep platform-channel code out of tests.
abstract interface class YouTubeMusicSecureKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// Persists only a non-secret revocation bit outside the credential store.
///
/// Keeping this marker independent from the encrypted credential is
/// intentional: if the platform refuses to delete the encrypted value during
/// logout, the next process still knows that the value must never be restored.
/// Cookies, visitor data and account identifiers must never be written here.
abstract interface class YouTubeMusicSessionRevocationStore {
  Future<bool> isRevoked();

  Future<void> markRevoked();

  Future<void> clearRevoked();
}

class SharedPreferencesYouTubeMusicSessionRevocationStore
    implements YouTubeMusicSessionRevocationStore {
  const SharedPreferencesYouTubeMusicSessionRevocationStore({
    this.storageKey = 'bstream.youtube_music.session.revoked.v1',
  });

  final String storageKey;

  @override
  Future<bool> isRevoked() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(storageKey) ?? false;
  }

  @override
  Future<void> markRevoked() async {
    final preferences = await SharedPreferences.getInstance();
    final persisted = await preferences.setBool(storageKey, true);
    if (!persisted) {
      throw StateError('Could not persist the session revocation marker.');
    }
  }

  @override
  Future<void> clearRevoked() async {
    final preferences = await SharedPreferences.getInstance();
    final removed = await preferences.remove(storageKey);
    if (!removed && preferences.containsKey(storageKey)) {
      throw StateError('Could not clear the session revocation marker.');
    }
  }
}

class FlutterYouTubeMusicSecureKeyValueStore
    implements YouTubeMusicSecureKeyValueStore {
  const FlutterYouTubeMusicSecureKeyValueStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(
        resetOnError: true,
        migrateOnAlgorithmChange: true,
      ),
      wOptions: WindowsOptions(useBackwardCompatibility: false),
    ),
  }) : this._(storage);

  const FlutterYouTubeMusicSecureKeyValueStore._(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Stores one versioned JSON value so a session is never partially committed.
class SecureYouTubeMusicSessionStore implements YouTubeMusicSessionStore {
  SecureYouTubeMusicSessionStore({
    YouTubeMusicSecureKeyValueStore secureStore =
        const FlutterYouTubeMusicSecureKeyValueStore(),
    YouTubeMusicSessionRevocationStore revocationStore =
        const SharedPreferencesYouTubeMusicSessionRevocationStore(),
    String storageKey = 'bstream.youtube_music.session.v1',
  }) : this._(secureStore, revocationStore, storageKey);

  SecureYouTubeMusicSessionStore._(
    this._secureStore,
    this._revocationStore,
    this.storageKey,
  );

  final YouTubeMusicSecureKeyValueStore _secureStore;
  final YouTubeMusicSessionRevocationStore _revocationStore;
  final String storageKey;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<YouTubeMusicSessionCredential?> read() => _serialized(() async {
    // Marker reads are deliberately fail-closed. If the auxiliary store is
    // unavailable, callers receive an error state instead of an old session.
    if (await _revocationStore.isRevoked()) {
      await _retryRevokedCredentialCleanup();
      return null;
    }
    final encoded = await _secureStore.read(storageKey);
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return YouTubeMusicSessionCredential.decode(encoded);
    } on FormatException {
      // Corrupt or future-version credentials are safer to forget than to use.
      await _secureStore.delete(storageKey);
      return null;
    }
  });

  @override
  Future<void> write(YouTubeMusicSessionCredential credential) =>
      _serialized(() async {
        final replacesRevokedCredential = await _revocationStore.isRevoked();
        await _secureStore.write(storageKey, credential.encode());
        if (!replacesRevokedCredential) return;

        try {
          // A newly validated login may replace a quarantined credential. The
          // marker is cleared only after the encrypted replacement is durable.
          await _revocationStore.clearRevoked();
        } on Object catch (error, stackTrace) {
          // The marker still blocks restoration. Best-effort deletion avoids
          // retaining a credential whose login could not be committed.
          try {
            await _secureStore.delete(storageKey);
          } on Object {
            // The persisted revocation marker remains the source of truth.
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
      });

  @override
  Future<void> delete() => _serialized(() async {
    try {
      // Persist intent first: a failed secure deletion must remain revoked
      // across an app/process restart.
      await _revocationStore.markRevoked();
    } on Object {
      // Still attempt the authoritative encrypted deletion. If that succeeds,
      // no credential remains that could be restored.
    }

    try {
      await _secureStore.delete(storageKey);
    } on Object catch (error, stackTrace) {
      // When the marker succeeded this is a safe, quarantined cleanup failure.
      // When it did not, propagating still keeps the current process signed
      // out and lets the caller surface a retry requirement.
      Error.throwWithStackTrace(error, stackTrace);
    }

    // The secret is gone, so failure to remove a conservative marker cannot
    // resurrect it. A later restore will retry marker cleanup.
    try {
      await _revocationStore.clearRevoked();
    } on Object {
      return;
    }
  });

  Future<void> _retryRevokedCredentialCleanup() async {
    try {
      await _secureStore.delete(storageKey);
    } on Object {
      // Never return the quarantined credential. The marker is intentionally
      // retained so a later restore/logout can retry cleanup.
      return;
    }
    try {
      await _revocationStore.clearRevoked();
    } on Object {
      // A stale true marker is conservative and remains fail-closed.
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
