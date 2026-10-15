import 'package:bstream_music/services/youtube_music/search_browse_artwork_cache.dart';
import 'package:bstream_music/services/youtube_music/search_browse_catalog_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'persists valid artwork URLs by category across cache instances',
    () async {
      SharedPreferences.setMockInitialValues({});
      const categoryId = 'yt:focus-target';
      const artwork = 'https://img.test/cover.jpg';

      await const SharedPreferencesSearchBrowseCategoryArtworkCache().write(
        categoryId,
        artwork,
      );

      expect(
        await const SharedPreferencesSearchBrowseCategoryArtworkCache().read(
          categoryId,
        ),
        artwork,
      );
    },
  );

  test('ignores invalid URLs and can remove a cached URL', () async {
    SharedPreferences.setMockInitialValues({});
    const cache = SharedPreferencesSearchBrowseCategoryArtworkCache();

    await cache.write('broken', 'file:///private/cover.jpg');
    expect(await cache.read('broken'), isNull);

    await cache.write('focus', 'https://img.test/cover.jpg');
    await cache.write('focus', null);
    expect(await cache.read('focus'), isNull);
  });

  test(
    'persists the live category catalog separately by app language',
    () async {
      SharedPreferences.setMockInitialValues({});
      const cache = SharedPreferencesSearchBrowseCatalogCache();
      final snapshot = SearchBrowseCatalogSnapshot(
        usesLiveYouTubeMusicCategories: true,
        categories: const [
          SearchBrowseCategorySnapshot(
            id: 'yt:focus',
            title: 'ConcentraciÃ³n',
            searchQuery: 'ConcentraciÃ³n',
            browseId: 'FEmusic_moods_and_genres_category',
            params: 'opaque-focus',
          ),
        ],
      );

      await cache.write('es', snapshot);

      final restored = await cache.read('es');
      expect(restored?.usesLiveYouTubeMusicCategories, isTrue);
      expect(restored?.categories.single.title, 'ConcentraciÃ³n');
      expect(restored?.categories.single.params, 'opaque-focus');
      expect(await cache.read('en'), isNull);
    },
  );
}
