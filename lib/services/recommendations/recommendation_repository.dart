import '../storage/library_operation_coordinator.dart';
import '../storage/local_database_service.dart';
import 'recommendation_storage_models.dart';

/// Persistence boundary used by [PersonalizedRecommendationEngine].
///
/// Keeping this contract separate from SQLite makes ranking and cache behavior
/// deterministic in unit tests and lets another storage backend be introduced
/// without changing the recommendation policy.
abstract interface class RecommendationRepository {
  /// Synchronously changes whenever recommendation data is cleared.
  int get generation;

  Future<List<RecommendationSeed>> getTopSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  });

  Future<List<RecommendationSeed>> getRecentSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  });

  /// Stable local and YouTube identities already present in the library.
  Future<Set<String>> getLibraryTrackKeys();

  Future<List<RelatedTrackCandidate>> getRelatedCandidates(
    String seedKey, {
    required Duration ttl,
    required DateTime now,
  });

  Future<bool> replaceRelatedCandidates({
    required String seedKey,
    required List<RelatedTrackCandidate> candidates,
    required DateTime fetchedAt,
    required int expectedGeneration,
  });

  Future<RecommendationFeedCache?> loadFeed(String feedKey);

  Future<bool> deleteFeed(String feedKey, {required int expectedGeneration});

  Future<bool> saveFeed(
    RecommendationFeedCache feed, {
    required int expectedGeneration,
  });
}

/// Production adapter over BStream's local database.
class LocalDatabaseRecommendationRepository
    implements RecommendationRepository {
  const LocalDatabaseRecommendationRepository({
    required this.database,
    required this.coordinator,
  });

  final LocalDatabaseService database;
  final LibraryOperationCoordinator coordinator;

  @override
  int get generation => database.recommendationGeneration;

  @override
  Future<List<RecommendationSeed>> getTopSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  }) {
    return coordinator.runWithGate(
      () => database.getTopRecommendationSeeds(
        limit: limit,
        since: since,
        minListenedMs: minListenedMs,
      ),
    );
  }

  @override
  Future<List<RecommendationSeed>> getRecentSeeds({
    required int limit,
    DateTime? since,
    int minListenedMs = 30000,
  }) {
    return coordinator.runWithGate(
      () => database.getRecentRecommendationSeeds(
        limit: limit,
        since: since,
        minListenedMs: minListenedMs,
      ),
    );
  }

  @override
  Future<Set<String>> getLibraryTrackKeys() {
    return coordinator.runWithGate(database.getLocalTrackIdentityKeys);
  }

  @override
  Future<List<RelatedTrackCandidate>> getRelatedCandidates(
    String seedKey, {
    required Duration ttl,
    required DateTime now,
  }) {
    return coordinator.runWithGate(
      () => database.getRelatedCandidates(seedKey, ttl: ttl, now: now),
    );
  }

  @override
  Future<bool> replaceRelatedCandidates({
    required String seedKey,
    required List<RelatedTrackCandidate> candidates,
    required DateTime fetchedAt,
    required int expectedGeneration,
  }) {
    return coordinator.runWithGate(
      () => database.upsertRelatedCandidates(
        seedKey: seedKey,
        candidates: candidates,
        fetchedAt: fetchedAt,
        expectedGeneration: expectedGeneration,
      ),
    );
  }

  @override
  Future<RecommendationFeedCache?> loadFeed(String feedKey) {
    return coordinator.runWithGate(
      () => database.loadRecommendationFeed(feedKey),
    );
  }

  @override
  Future<bool> deleteFeed(String feedKey, {required int expectedGeneration}) {
    return coordinator.runWithGate(
      () => database.deleteRecommendationFeed(
        feedKey,
        expectedGeneration: expectedGeneration,
      ),
    );
  }

  @override
  Future<bool> saveFeed(
    RecommendationFeedCache feed, {
    required int expectedGeneration,
  }) {
    return coordinator.runWithGate(
      () => database.saveRecommendationFeed(
        feed,
        expectedGeneration: expectedGeneration,
      ),
    );
  }
}
