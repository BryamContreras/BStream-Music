import 'package:shared_preferences/shared_preferences.dart';

import 'innertube_search_service.dart';

/// Persists YouTube Music's anonymous visitor identity between app launches.
///
/// This is not an authenticated account or playback telemetry. It only keeps
/// the bootstrap identifier YouTube assigns to anonymous catalog requests so
/// subsequent searches, home shelves and related requests share one anonymous
/// session instead of starting from a blank visitor on every launch.
final class SharedPreferencesInnerTubeVisitorDataStore
    implements InnerTubeVisitorDataStore {
  const SharedPreferencesInnerTubeVisitorDataStore({
    this.key = 'innertube.anonymousVisitorData',
  });

  final String key;

  @override
  Future<String?> read() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(key)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String visitorData) async {
    final normalized = visitorData.trim();
    if (normalized.isEmpty) {
      await clear();
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(key, normalized);
  }

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(key);
  }
}
