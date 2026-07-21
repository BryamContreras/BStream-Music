part of 'music_providers.dart';

final searchControllerProvider =
    AsyncNotifierProvider<SearchController, List<TrackInfo>>(
      SearchController.new,
    );

class SearchController extends AsyncNotifier<List<TrackInfo>> {
  static const _prefetchLimit = 1;
  static const _androidPrefetchLimit = 3;
  int _searchGeneration = 0;

  @override
  Future<List<TrackInfo>> build() async {
    return const [];
  }

  Future<void> submit(String query) async {
    final generation = ++_searchGeneration;
    ref.read(remotePlaybackCacheProvider).cancelSearchWarmups();
    state = const AsyncLoading();
    final result = await AsyncValue.guard(() => _searchWithRetry(query));
    if (generation != _searchGeneration) {
      return;
    }
    state = result;

    final tracks = result.value;
    if (tracks != null && tracks.isNotEmpty) {
      unawaited(_prefetchPlayableTracks(tracks, generation));
    }
  }

  Future<List<TrackInfo>> _searchWithRetry(String query) async {
    try {
      return await ref.read(searchTracksProvider).call(query);
    } catch (error) {
      if (!_isTransientNetworkError(error)) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 800));
      return ref.read(searchTracksProvider).call(query);
    }
  }

  bool _isTransientNetworkError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('no address associated with hostname') ||
        text.contains('unknownhost') ||
        text.contains('unable to download api page');
  }

  Future<void> _prefetchPlayableTracks(
    List<TrackInfo> tracks,
    int generation,
  ) async {
    final resolver = ref.read(remoteTrackResolverProvider);
    final limit = AppPlatform.isAndroid
        ? _androidPrefetchLimit
        : _prefetchLimit;
    final pendingTracks = tracks
        .take(limit)
        .where((track) => track.streamUrl == null || track.streamUrl!.isEmpty)
        .toList(growable: false);
    if (pendingTracks.isEmpty) {
      return;
    }

    final firstResolved = await _resolvePlayableTrack(
      pendingTracks.first,
      resolver,
    );
    if (generation != _searchGeneration) {
      return;
    }
    if (firstResolved != null) {
      _replaceResolvedSearchTrack(pendingTracks.first, firstResolved);
    }

    final remainingTracks = pendingTracks.skip(1);
    await Future.wait([
      for (final track in remainingTracks)
        () async {
          if (generation != _searchGeneration) {
            return;
          }
          final resolved = await _resolvePlayableTrack(track, resolver);
          if (generation != _searchGeneration || resolved == null) {
            return;
          }
          _replaceResolvedSearchTrack(track, resolved);
        }(),
    ]);
  }

  Future<TrackInfo?> _resolvePlayableTrack(
    TrackInfo track, [
    RemoteTrackResolver? resolver,
  ]) async {
    try {
      final RemoteTrackResolver trackResolver;
      if (resolver == null) {
        trackResolver = ref.read(remoteTrackResolverProvider);
      } else {
        trackResolver = resolver;
      }
      return await trackResolver.resolve(track);
    } catch (_) {
      return null;
    }
  }

  void _replaceResolvedSearchTrack(TrackInfo original, TrackInfo resolved) {
    final current = state.value;
    if (current == null || current.isEmpty) {
      return;
    }

    final index = current.indexWhere((track) => track.url == original.url);
    if (index < 0) {
      return;
    }

    final next = List<TrackInfo>.of(current);
    next[index] = _mergeTrackInfo(next[index], resolved);
    state = AsyncData(List.unmodifiable(next));
  }
}

final settingsControllerProvider =
    AsyncNotifierProvider<SettingsController, SettingsState>(
      SettingsController.new,
    );
