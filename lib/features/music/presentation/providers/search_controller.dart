part of 'music_providers.dart';

final searchControllerProvider =
    AsyncNotifierProvider<SearchController, SearchState>(SearchController.new);

class SearchState {
  SearchState({
    this.query = '',
    this.selectedCategory = SearchCategory.songs,
    Map<SearchCategory, SearchPage> pages = const {},
    this.fallbackOnly = false,
    this.loadingCategory,
  }) : assert(
         !fallbackOnly || selectedCategory == SearchCategory.videos,
         'A fallback-only search must select Videos.',
       ),
       assert(
         !fallbackOnly ||
             (pages.length <= 1 &&
                 (pages.isEmpty || pages.containsKey(SearchCategory.videos))),
         'A fallback-only search cannot expose InnerTube categories.',
       ),
       pages = Map.unmodifiable(pages);

  final String query;
  final SearchCategory selectedCategory;
  final Map<SearchCategory, SearchPage> pages;
  final bool fallbackOnly;
  final SearchCategory? loadingCategory;

  bool get hasQuery => query.isNotEmpty;
  bool get isLoading => loadingCategory != null;
  bool get isSelectedCategoryLoading => loadingCategory == selectedCategory;
  bool get hasSelectedPage => pages.containsKey(selectedCategory);
  SearchPage? get selectedPage => pages[selectedCategory];
  SearchBackend? get backend => selectedPage?.backend;
  Object? get primaryError => selectedPage?.primaryError;
  List<TrackInfo> get selectedTracks =>
      selectedPage?.tracks ?? const <TrackInfo>[];
  List<SearchAlbum> get selectedAlbums =>
      selectedPage?.albums ?? const <SearchAlbum>[];
  List<SearchArtist> get selectedArtists =>
      selectedPage?.artists ?? const <SearchArtist>[];
  List<SearchCategory> get availableCategories => fallbackOnly
      ? const <SearchCategory>[SearchCategory.videos]
      : SearchCategory.values;

  SearchPage? pageFor(SearchCategory category) => pages[category];

  SearchState copyWith({
    String? query,
    SearchCategory? selectedCategory,
    Map<SearchCategory, SearchPage>? pages,
    bool? fallbackOnly,
    Object? loadingCategory = _searchStateUnset,
  }) {
    return SearchState(
      query: query ?? this.query,
      selectedCategory: selectedCategory ?? this.selectedCategory,
      pages: pages ?? this.pages,
      fallbackOnly: fallbackOnly ?? this.fallbackOnly,
      loadingCategory: identical(loadingCategory, _searchStateUnset)
          ? this.loadingCategory
          : loadingCategory as SearchCategory?,
    );
  }
}

const _searchStateUnset = Object();

class SearchController extends AsyncNotifier<SearchState> {
  int _searchGeneration = 0;

  @override
  Future<SearchState> build() async => SearchState();

  Future<void> submit(String query) async {
    final normalizedQuery = query.trim();
    final generation = ++_searchGeneration;
    ref.read(remotePlaybackCacheProvider).cancelSearchWarmups();
    if (normalizedQuery.isEmpty) {
      state = AsyncData(SearchState());
      return;
    }

    final loadingState = SearchState(
      query: normalizedQuery,
      selectedCategory: SearchCategory.songs,
      loadingCategory: SearchCategory.songs,
    );
    state = AsyncData(loadingState);
    await _loadCategory(loadingState, SearchCategory.songs, generation);
  }

  Future<void> selectCategory(SearchCategory category) async {
    final current = state.value ?? SearchState();
    if (current.fallbackOnly) {
      return;
    }
    if (!current.hasQuery) {
      state = AsyncData(current.copyWith(selectedCategory: category));
      return;
    }
    if (current.loadingCategory == category) {
      return;
    }
    if (current.pages.containsKey(category)) {
      if (current.loadingCategory != null) {
        _searchGeneration++;
        ref.read(remotePlaybackCacheProvider).cancelSearchWarmups();
      }
      state = AsyncData(
        current.copyWith(selectedCategory: category, loadingCategory: null),
      );
      return;
    }

    final generation = ++_searchGeneration;
    ref.read(remotePlaybackCacheProvider).cancelSearchWarmups();
    final loadingState = current.copyWith(
      selectedCategory: category,
      loadingCategory: category,
    );
    state = AsyncData(loadingState);
    await _loadCategory(loadingState, category, generation);
  }

  void clear() {
    _searchGeneration++;
    ref.read(remotePlaybackCacheProvider).cancelSearchWarmups();
    state = AsyncData(SearchState());
  }

  Future<void> _loadCategory(
    SearchState loadingState,
    SearchCategory category,
    int generation,
  ) async {
    try {
      final page = await ref
          .read(remoteMusicDataSourceProvider)
          .searchCategory(loadingState.query, category);
      if (generation != _searchGeneration) {
        return;
      }
      if (page.isFallback) {
        state = AsyncData(
          SearchState(
            query: loadingState.query,
            selectedCategory: SearchCategory.videos,
            pages: <SearchCategory, SearchPage>{SearchCategory.videos: page},
            fallbackOnly: true,
          ),
        );
        return;
      }
      state = AsyncData(
        loadingState.copyWith(
          pages: <SearchCategory, SearchPage>{
            ...loadingState.pages,
            category: page,
          },
          loadingCategory: null,
        ),
      );
    } catch (error, stackTrace) {
      if (generation != _searchGeneration) {
        return;
      }
      final fallbackState = SearchState(
        query: loadingState.query,
        selectedCategory: SearchCategory.videos,
        fallbackOnly: true,
      );
      final errorState = AsyncError<SearchState>(error, stackTrace);
      // Riverpod has no public error-with-value constructor. Keeping this
      // previous value makes the fallback restriction observable to the UI
      // even when yt-dlp also fails.
      // ignore: invalid_use_of_internal_member
      state = errorState.copyWithPrevious(AsyncData(fallbackState));
    }
  }
}
