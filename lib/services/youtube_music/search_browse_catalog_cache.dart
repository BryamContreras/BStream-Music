import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A serializable copy of a YouTube Music browse category. Keeping the opaque
/// target allows the app to show the last catalog immediately, then refresh it.
final class SearchBrowseCategorySnapshot {
  const SearchBrowseCategorySnapshot({
    required this.id,
    required this.title,
    required this.searchQuery,
    this.browseId,
    this.params,
  });

  final String id;
  final String title;
  final String searchQuery;
  final String? browseId;
  final String? params;
}

final class SearchBrowseCatalogSnapshot {
  SearchBrowseCatalogSnapshot({
    required List<SearchBrowseCategorySnapshot> categories,
    required this.usesLiveYouTubeMusicCategories,
  }) : categories = List.unmodifiable(categories);

  final List<SearchBrowseCategorySnapshot> categories;
  final bool usesLiveYouTubeMusicCategories;
}

abstract interface class SearchBrowseCatalogCache {
  Future<SearchBrowseCatalogSnapshot?> read(String languageCode);

  Future<void> write(String languageCode, SearchBrowseCatalogSnapshot catalog);
}

final class SharedPreferencesSearchBrowseCatalogCache
    implements SearchBrowseCatalogCache {
  const SharedPreferencesSearchBrowseCatalogCache();

  static const _keyPrefix = 'search.browse.catalog.v1.';

  String _keyFor(String languageCode) => '$_keyPrefix$languageCode';

  @override
  Future<SearchBrowseCatalogSnapshot?> read(String languageCode) async {
    try {
      final encoded = (await SharedPreferences.getInstance()).getString(
        _keyFor(languageCode),
      );
      if (encoded == null || encoded.isEmpty) return null;
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != 1 ||
          decoded['live'] != true ||
          decoded['categories'] is! List) {
        return null;
      }
      final categories = <SearchBrowseCategorySnapshot>[];
      for (final value in decoded['categories'] as List) {
        if (value is! Map<String, dynamic>) continue;
        final id = value['id'];
        final title = value['title'];
        final searchQuery = value['searchQuery'];
        if (id is! String ||
            id.isEmpty ||
            title is! String ||
            title.isEmpty ||
            searchQuery is! String) {
          continue;
        }
        final browseId = value['browseId'];
        final params = value['params'];
        categories.add(
          SearchBrowseCategorySnapshot(
            id: id,
            title: title,
            searchQuery: searchQuery,
            browseId: browseId is String ? browseId : null,
            params: params is String ? params : null,
          ),
        );
      }
      if (categories.isEmpty) return null;
      return SearchBrowseCatalogSnapshot(
        categories: categories,
        usesLiveYouTubeMusicCategories: true,
      );
    } catch (_) {
      // The browse page falls back to live discovery when this cache is absent.
      return null;
    }
  }

  @override
  Future<void> write(
    String languageCode,
    SearchBrowseCatalogSnapshot catalog,
  ) async {
    if (!catalog.usesLiveYouTubeMusicCategories || catalog.categories.isEmpty) {
      return;
    }
    try {
      final encoded = jsonEncode(<String, Object?>{
        'version': 1,
        'live': true,
        'categories': [
          for (final category in catalog.categories)
            <String, Object?>{
              'id': category.id,
              'title': category.title,
              'searchQuery': category.searchQuery,
              if (category.browseId != null) 'browseId': category.browseId,
              if (category.params != null) 'params': category.params,
            },
        ],
      });
      final preferences = await SharedPreferences.getInstance();
      final key = _keyFor(languageCode);
      if (preferences.getString(key) == encoded) return;
      await preferences.setString(key, encoded);
    } catch (_) {
      // Persistent catalog data is an optimization, never a requirement.
    }
  }
}
