import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's opt-in for automatic playlist synchronization.
///
/// This store must never receive or persist authentication material. The
/// account key is hashed before it becomes a preference key so the preference
/// file contains only an opaque policy identifier and a boolean decision.
abstract interface class PlaylistSyncConsentStore {
  Future<bool> hasConsent(String accountKey);

  Future<void> grantConsent(String accountKey);
}

final class SharedPreferencesPlaylistSyncConsentStore
    implements PlaylistSyncConsentStore {
  const SharedPreferencesPlaylistSyncConsentStore();

  static const _preferencePrefix = 'ytm_playlist_sync_consent_v1_';

  @override
  Future<bool> hasConsent(String accountKey) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_preferenceKey(accountKey)) == true;
  }

  @override
  Future<void> grantConsent(String accountKey) async {
    final preferences = await SharedPreferences.getInstance();
    final written = await preferences.setBool(_preferenceKey(accountKey), true);
    if (!written) {
      throw StateError('Playlist synchronization consent was not persisted.');
    }
  }
}

String _preferenceKey(String accountKey) {
  final normalized = accountKey.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(accountKey, 'accountKey', 'Must not be empty.');
  }
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return '${SharedPreferencesPlaylistSyncConsentStore._preferencePrefix}$digest';
}
