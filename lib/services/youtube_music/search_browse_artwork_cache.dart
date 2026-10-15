import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small persistent index for the category-cover URLs shown in Search.
///
/// The image bytes themselves live in the shared artwork disk cache. Keeping
/// this URL index lets the UI render that disk-cached image before it refreshes
/// YouTube Music's category metadata after the next launch.
abstract interface class SearchBrowseCategoryArtworkCache {
  Future<String?> read(String categoryId);

  Future<void> write(String categoryId, String? artworkUrl);
}

final class SharedPreferencesSearchBrowseCategoryArtworkCache
    implements SearchBrowseCategoryArtworkCache {
  const SharedPreferencesSearchBrowseCategoryArtworkCache();

  static const _keyPrefix = 'search.browse.categoryArtwork.v1.';

  String _keyFor(String categoryId) =>
      '$_keyPrefix${base64Url.encode(utf8.encode(categoryId))}';

  @override
  Future<String?> read(String categoryId) async {
    try {
      final value = (await SharedPreferences.getInstance())
          .getString(_keyFor(categoryId))
          ?.trim();
      if (value == null || value.isEmpty) return null;
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !uri.hasAuthority ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        return null;
      }
      return value;
    } catch (_) {
      // A cache miss must never prevent browsing or network fallback.
      return null;
    }
  }

  @override
  Future<void> write(String categoryId, String? artworkUrl) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final key = _keyFor(categoryId);
      final normalized = artworkUrl?.trim();
      if (normalized == null || normalized.isEmpty) {
        await preferences.remove(key);
        return;
      }
      final uri = Uri.tryParse(normalized);
      if (uri == null ||
          !uri.hasAuthority ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        return;
      }
      if (preferences.getString(key) == normalized) return;
      await preferences.setString(key, normalized);
    } catch (_) {
      // Search remains usable when persistent storage is temporarily absent.
    }
  }
}
