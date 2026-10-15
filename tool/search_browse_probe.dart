import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';

/// Read-only smoke check against YouTube Music's current regional catalog.
Future<void> main() async {
  final service = InnerTubeSearchService();
  try {
    final catalog = await service.getMoodsAndGenres();
    final categories = catalog.expand((section) => section.categories).toList();
    final selected = categories
        .where(
          (category) =>
              category.title.toLowerCase().contains('concentra') ||
              category.title.toLowerCase().contains('fiesta'),
        )
        .take(2)
        .toList();
    final results = <Object>[];
    for (final category in selected.isEmpty ? categories.take(2) : selected) {
      final page = await service.getMoodOrGenre(
        category.target,
        maxSections: InnerTubeSearchService.maxMoodGenrePageSections,
      );
      results.add({
        'category': category.title,
        'sections': [
          for (final section in page.sections)
            {
              'title': section.title,
              'items': section.items.length,
              'playlists': section.collections
                  .take(3)
                  .map(
                    (item) => {
                      'title': item.title,
                      'artwork': item.thumbnailUrl != null,
                    },
                  )
                  .toList(),
            },
        ],
        'hasContinuation': page.continuation != null,
      });
    }
    stdout.writeln(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'categories': categories.length, 'results': results}),
    );
  } finally {
    service.dispose();
  }
}
