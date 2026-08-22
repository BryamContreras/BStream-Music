import 'package:bstream_music/services/recommendations/recommendations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('personalized feed JSON round-trips every item kind', () {
    final feed = PersonalizedRecommendationFeed(
      generatedAt: DateTime.utc(2026, 8, 21),
      sections: <PersonalizedRecommendationSection>[
        PersonalizedRecommendationSection(
          kind: PersonalizedSectionKind.discovery,
          title: 'Descubrimiento para ti',
          seedTrackKey: 'seed',
          seedTitle: 'Seed title',
          items: <PersonalizedRecommendationItem>[
            PersonalizedTrackItem(
              trackId: 'track',
              videoId: 'video000001',
              title: 'Song',
              artists: const <String>['Artist'],
              artistBrowseIds: const <String?>['UCartist'],
              album: 'Album',
              thumbnailUrl: 'https://example.com/art.jpg',
              durationMs: 123000,
            ),
            PersonalizedCollectionItem(
              id: 'release:MPREb_1',
              title: 'Release',
              browseId: 'MPREb_1',
              kind: PersonalizedCollectionKind.release,
              artists: const <String>['Artist'],
              artistBrowseIds: const <String?>['UCartist'],
              year: '2026',
            ),
          ],
        ),
      ],
    );

    final decoded = PersonalizedRecommendationFeed.fromJson(feed.toJson());

    expect(decoded, isNotNull);
    expect(decoded!.toJson(), feed.toJson());
  });

  test('malformed sections and items are discarded defensively', () {
    final decoded = PersonalizedRecommendationFeed.fromJson(<String, Object?>{
      'schemaVersion': PersonalizedRecommendationFeed.schemaVersion,
      'generatedAt': '2026-08-21T00:00:00.000Z',
      'sections': <Object?>[
        <String, Object?>{
          'kind': 'unknown',
          'title': 'Bad',
          'items': <Object?>[],
        },
        <String, Object?>{
          'kind': 'discovery',
          'title': 'Valid section',
          'items': <Object?>[
            <String, Object?>{'type': 'track', 'trackId': '', 'title': 'Bad'},
            <String, Object?>{
              'type': 'track',
              'trackId': 'good',
              'title': 'Good',
              'artists': <Object?>['Artist'],
            },
          ],
        },
      ],
    });

    expect(decoded, isNotNull);
    expect(decoded!.sections, hasLength(1));
    expect(decoded.sections.single.items, hasLength(1));
  });
}
