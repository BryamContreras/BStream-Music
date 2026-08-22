import 'recommendation_storage_models.dart';

/// Semantic groups produced by the local personalization engine.
enum PersonalizedSectionKind {
  continueListening,
  becauseYouListened,
  mixes,
  newForYou,
  discovery,
}

enum PersonalizedCollectionKind { mix, release }

sealed class PersonalizedRecommendationItem {
  const PersonalizedRecommendationItem();

  Map<String, Object?> toJson();

  static PersonalizedRecommendationItem? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final map = value.map<String, Object?>(
      (key, item) => MapEntry(key.toString(), item),
    );
    return switch (map['type']) {
      'track' => PersonalizedTrackItem.fromJson(map),
      'collection' => PersonalizedCollectionItem.fromJson(map),
      _ => null,
    };
  }
}

final class PersonalizedTrackItem extends PersonalizedRecommendationItem {
  PersonalizedTrackItem({
    required this.trackId,
    required this.title,
    required List<String> artists,
    this.videoId,
    List<String?> artistBrowseIds = const <String?>[],
    this.album,
    this.thumbnailUrl,
    this.durationMs,
    this.source = PlaybackEventSource.streaming,
  }) : artists = List<String>.unmodifiable(artists),
       artistBrowseIds = List<String?>.unmodifiable(artistBrowseIds);

  factory PersonalizedTrackItem.fromSeed(RecommendationSeed seed) {
    return PersonalizedTrackItem(
      trackId: seed.trackId,
      videoId: seed.videoId,
      title: seed.title,
      artists: seed.artists,
      artistBrowseIds: seed.artistBrowseIds,
      album: seed.album,
      thumbnailUrl: seed.thumbnailUrl,
      durationMs: seed.durationMs,
      source: seed.source,
    );
  }

  factory PersonalizedTrackItem.fromCandidate(RelatedTrackCandidate candidate) {
    return PersonalizedTrackItem(
      trackId: candidate.trackId,
      videoId: candidate.videoId,
      title: candidate.title,
      artists: candidate.artists,
      artistBrowseIds: candidate.artistBrowseIds,
      album: candidate.album,
      thumbnailUrl: candidate.thumbnailUrl,
      durationMs: candidate.durationMs,
    );
  }

  final String trackId;
  final String? videoId;
  final String title;
  final List<String> artists;
  final List<String?> artistBrowseIds;
  final String? album;
  final String? thumbnailUrl;
  final int? durationMs;
  final PlaybackEventSource source;

  String get trackKey =>
      recommendationTrackKey(videoId: videoId, trackId: trackId);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': 'track',
    'trackId': trackId,
    'videoId': videoId,
    'title': title,
    'artists': artists,
    'artistBrowseIds': artistBrowseIds,
    'album': album,
    'thumbnailUrl': thumbnailUrl,
    'durationMs': durationMs,
    'source': source.name,
  };

  static PersonalizedTrackItem? fromJson(Map<String, Object?> map) {
    final trackId = _nonEmptyString(map['trackId']);
    final title = _nonEmptyString(map['title']);
    if (trackId == null || title == null) {
      return null;
    }
    final artists = _stringList(map['artists']);
    final artistBrowseIds = _nullableStringList(map['artistBrowseIds']);
    final sourceName = _nonEmptyString(map['source']);
    final source = PlaybackEventSource.values.firstWhere(
      (candidate) => candidate.name == sourceName,
      orElse: () => PlaybackEventSource.unknown,
    );
    return PersonalizedTrackItem(
      trackId: trackId,
      videoId: _nonEmptyString(map['videoId']),
      title: title,
      artists: artists,
      artistBrowseIds: artistBrowseIds,
      album: _nonEmptyString(map['album']),
      thumbnailUrl: _nonEmptyString(map['thumbnailUrl']),
      durationMs: _nonNegativeInt(map['durationMs']),
      source: source,
    );
  }
}

final class PersonalizedCollectionItem extends PersonalizedRecommendationItem {
  PersonalizedCollectionItem({
    required this.id,
    required this.title,
    required this.browseId,
    required this.kind,
    List<String> artists = const <String>[],
    List<String?> artistBrowseIds = const <String?>[],
    this.subtitle,
    this.thumbnailUrl,
    this.playlistId,
    this.year,
  }) : artists = List<String>.unmodifiable(artists),
       artistBrowseIds = List<String?>.unmodifiable(artistBrowseIds);

  final String id;
  final String title;
  final String browseId;
  final String? playlistId;
  final PersonalizedCollectionKind kind;
  final List<String> artists;
  final List<String?> artistBrowseIds;
  final String? subtitle;
  final String? thumbnailUrl;
  final String? year;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': 'collection',
    'id': id,
    'title': title,
    'browseId': browseId,
    'playlistId': playlistId,
    'kind': kind.name,
    'artists': artists,
    'artistBrowseIds': artistBrowseIds,
    'subtitle': subtitle,
    'thumbnailUrl': thumbnailUrl,
    'year': year,
  };

  static PersonalizedCollectionItem? fromJson(Map<String, Object?> map) {
    final id = _nonEmptyString(map['id']);
    final title = _nonEmptyString(map['title']);
    final browseId = _nonEmptyString(map['browseId']);
    final kindName = _nonEmptyString(map['kind']);
    if (id == null || title == null || browseId == null || kindName == null) {
      return null;
    }
    PersonalizedCollectionKind? kind;
    for (final candidate in PersonalizedCollectionKind.values) {
      if (candidate.name == kindName) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) {
      return null;
    }
    return PersonalizedCollectionItem(
      id: id,
      title: title,
      browseId: browseId,
      playlistId: _nonEmptyString(map['playlistId']),
      kind: kind,
      artists: _stringList(map['artists']),
      artistBrowseIds: _nullableStringList(map['artistBrowseIds']),
      subtitle: _nonEmptyString(map['subtitle']),
      thumbnailUrl: _nonEmptyString(map['thumbnailUrl']),
      year: _nonEmptyString(map['year']),
    );
  }
}

class PersonalizedRecommendationSection {
  PersonalizedRecommendationSection({
    required this.kind,
    required this.title,
    required List<PersonalizedRecommendationItem> items,
    this.seedTrackKey,
    this.seedTitle,
  }) : items = List<PersonalizedRecommendationItem>.unmodifiable(items);

  final PersonalizedSectionKind kind;
  final String title;
  final String? seedTrackKey;
  final String? seedTitle;
  final List<PersonalizedRecommendationItem> items;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'title': title,
    'seedTrackKey': seedTrackKey,
    'seedTitle': seedTitle,
    'items': items.map((item) => item.toJson()).toList(growable: false),
  };

  static PersonalizedRecommendationSection? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final map = value.map<String, Object?>(
      (key, item) => MapEntry(key.toString(), item),
    );
    final kindName = _nonEmptyString(map['kind']);
    final title = _nonEmptyString(map['title']);
    if (kindName == null || title == null || map['items'] is! List) {
      return null;
    }
    PersonalizedSectionKind? kind;
    for (final candidate in PersonalizedSectionKind.values) {
      if (candidate.name == kindName) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) {
      return null;
    }
    final items = (map['items']! as List)
        .map(PersonalizedRecommendationItem.fromJson)
        .whereType<PersonalizedRecommendationItem>()
        .toList(growable: false);
    if (items.isEmpty) {
      return null;
    }
    return PersonalizedRecommendationSection(
      kind: kind,
      title: title,
      seedTrackKey: _nonEmptyString(map['seedTrackKey']),
      seedTitle: _nonEmptyString(map['seedTitle']),
      items: items,
    );
  }
}

class PersonalizedRecommendationFeed {
  PersonalizedRecommendationFeed({
    required this.generatedAt,
    required List<PersonalizedRecommendationSection> sections,
  }) : sections = List<PersonalizedRecommendationSection>.unmodifiable(
         sections,
       );

  static const int schemaVersion = 1;

  final DateTime generatedAt;
  final List<PersonalizedRecommendationSection> sections;

  bool get isEmpty => sections.isEmpty;
  bool get isNotEmpty => sections.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'sections': sections
        .map((section) => section.toJson())
        .toList(growable: false),
  };

  static PersonalizedRecommendationFeed? fromJson(
    Map<String, Object?> payload,
  ) {
    if (payload['schemaVersion'] != schemaVersion ||
        payload['sections'] is! List) {
      return null;
    }
    final generatedAtValue = _nonEmptyString(payload['generatedAt']);
    final generatedAt = generatedAtValue == null
        ? null
        : DateTime.tryParse(generatedAtValue);
    if (generatedAt == null) {
      return null;
    }
    final sections = (payload['sections']! as List)
        .map(PersonalizedRecommendationSection.fromJson)
        .whereType<PersonalizedRecommendationSection>()
        .toList(growable: false);
    return PersonalizedRecommendationFeed(
      generatedAt: generatedAt,
      sections: sections,
    );
  }
}

String? _nonEmptyString(Object? value) {
  if (value is! String) {
    return null;
  }
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

int? _nonNegativeInt(Object? value) {
  if (value is! num) {
    return null;
  }
  final result = value.toInt();
  return result < 0 ? null : result;
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return const <String>[];
  }
  return List<String>.unmodifiable(
    value.map(_nonEmptyString).whereType<String>(),
  );
}

List<String?> _nullableStringList(Object? value) {
  if (value is! List) {
    return const <String?>[];
  }
  return List<String?>.unmodifiable(value.map(_nonEmptyString));
}
