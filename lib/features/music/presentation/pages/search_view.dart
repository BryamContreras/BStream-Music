import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../core/widgets/marquee_text.dart';
import '../../domain/entities/search_result.dart';
import '../providers/music_providers.dart';
import '../widgets/search_input.dart';
import '../widgets/scrolled_under_tab_frame.dart';
import '../widgets/now_playing_equalizer.dart';
import '../widgets/source_image.dart';
import '../widgets/track_result_tile.dart';
import 'artist_profile_page.dart';
import 'remote_collection_detail_page.dart';

class SearchView extends ConsumerStatefulWidget {
  const SearchView({
    required this.onOpenPlayer,
    this.onAddToPlaylist,
    this.onBrowseCategorySelected,
    this.active = true,
    this.bottomContentPadding = 0,
    super.key,
  });

  static const _headingTransitionDuration = Duration(milliseconds: 220);

  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  /// Overrides the default category-detail navigation when supplied.
  final ValueChanged<SearchBrowseCategory>? onBrowseCategorySelected;
  final bool active;
  final double bottomContentPadding;

  @override
  ConsumerState<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends ConsumerState<SearchView> {
  bool _focusInputAfterClear = false;

  void _clearSearch() {
    setState(() => _focusInputAfterClear = true);
    ref.read(searchControllerProvider.notifier).clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusInputAfterClear) {
        setState(() => _focusInputAfterClear = false);
      }
    });
  }

  void _selectBrowseCategory(
    SearchBrowseCategory category,
    AppStrings strings,
  ) {
    FocusManager.instance.primaryFocus?.unfocus();
    final callback = widget.onBrowseCategorySelected;
    if (callback != null) {
      callback(category);
      return;
    }

    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: category.title,
          subtitle: strings.youtubeMusic,
          artworkSource: null,
          queueSourceId: 'search-browse:${category.id}',
          tracksProvider: searchBrowseCategoryTracksProvider(category),
          emptyMessage: strings.searchBrowseEmpty,
          errorMessage: strings.searchBrowseError,
          fallbackIcon: _SearchBrowseVisual.forCategory(category).icon,
          onOpenPlayer: widget.onOpenPlayer,
          onAddToPlaylist: widget.onAddToPlaylist,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchControllerProvider);
    final searchState = results.value ?? SearchState();
    final strings = ref.watch(appStringsProvider);
    final fallbackBrowseCategories = fallbackSearchBrowseCategories(strings);
    // Persistent tab slots remain mounted after their first visit. Avoid
    // starting discovery merely because an offstage Search widget exists;
    // the local cards are already enough until the tab is actually visible.
    final browseCatalog = widget.active && !searchState.hasQuery
        ? ref.watch(searchBrowseCatalogProvider)
        : null;
    final browseCategories =
        browseCatalog?.when(
          data: (catalog) => catalog.categories,
          loading: () => fallbackBrowseCategories,
          error: (_, _) => fallbackBrowseCategories,
        ) ??
        fallbackBrowseCategories;
    final isMobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final showHeading = !isMobile || !searchState.hasQuery;
    final headingTransitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : SearchView._headingTransitionDuration;

    return ScrolledUnderTabFrame(
      surfaceKey: const ValueKey('search-tab-header-surface'),
      header: AnimatedSwitcher(
        key: const ValueKey('search-tab-heading-transition'),
        duration: headingTransitionDuration,
        reverseDuration: headingTransitionDuration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          alignment: Alignment.centerLeft,
          children: <Widget>[...previousChildren, ?currentChild],
        ),
        child: showHeading
            ? Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  key: const ValueKey('search-tab-title'),
                  strings.searchTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              )
            : SearchInput(
                key: const ValueKey('search-tab-search-input'),
                initialText: searchState.query,
                compact: true,
                requestFocusOnClear: false,
                autofocus: _focusInputAfterClear,
                hintText: strings.searchHint,
                tooltip: strings.search,
                clearTooltip: strings.clearSearch,
                onSubmitted: (query) =>
                    ref.read(searchControllerProvider.notifier).submit(query),
                onCleared: _clearSearch,
              ),
      ),
      scrollKey: const ValueKey('search-results-scroll'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      slivers: [
        SliverToBoxAdapter(
          child: AnimatedPadding(
            key: const ValueKey('search-input-section-padding'),
            duration: headingTransitionDuration,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.fromLTRB(
              0,
              showHeading ? appTabFirstSectionTopGap : 10,
              0,
              14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showHeading)
                  Padding(
                    key: const ValueKey('search-input-container'),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: SearchInput(
                      initialText: searchState.query,
                      autofocus: _focusInputAfterClear,
                      hintText: strings.searchHint,
                      tooltip: strings.search,
                      clearTooltip: strings.clearSearch,
                      onSubmitted: (query) => ref
                          .read(searchControllerProvider.notifier)
                          .submit(query),
                      onCleared: _clearSearch,
                    ),
                  ),
                if (searchState.hasQuery) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _SearchCategoryTabs(
                      categories: searchState.availableCategories,
                      selectedCategory: searchState.selectedCategory,
                      strings: strings,
                      onSelected: (category) => ref
                          .read(searchControllerProvider.notifier)
                          .selectCategory(category),
                    ),
                  ),
                ],
                if (searchState.fallbackOnly) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _FallbackNotice(
                      message: searchState.primaryError == null
                          ? strings.searchInnerTubeVideoOnly
                          : strings.searchInnerTubeVideoFallback,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (!searchState.hasQuery && !results.hasError)
          SliverToBoxAdapter(
            child: Padding(
              key: const ValueKey('search-browse-heading'),
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
              child: Text(
                strings.searchBrowseAll,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.contentTitleFor(context),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        _SearchResultsSliver(
          results: results,
          strings: strings,
          browseCategories: browseCategories,
          onBrowseCategorySelected: (category) =>
              _selectBrowseCategory(category, strings),
          onOpenPlayer: widget.onOpenPlayer,
          onAddToPlaylist: widget.onAddToPlaylist,
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            key: const ValueKey('search-scroll-bottom-reserve'),
            height: widget.bottomContentPadding + 16,
          ),
        ),
      ],
    );
  }
}

class _SearchResultsSliver extends StatelessWidget {
  const _SearchResultsSliver({
    required this.results,
    required this.strings,
    required this.browseCategories,
    required this.onBrowseCategorySelected,
    required this.onOpenPlayer,
    required this.onAddToPlaylist,
  });

  final AsyncValue<SearchState> results;
  final AppStrings strings;
  final List<SearchBrowseCategory> browseCategories;
  final ValueChanged<SearchBrowseCategory> onBrowseCategorySelected;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    return results.when(
      data: (state) {
        if (!state.hasQuery) {
          return _SearchBrowseCategoriesSliver(
            categories: browseCategories,
            onSelected: onBrowseCategorySelected,
          );
        }
        return _SearchCategoryResultsSliver(
          state: state,
          strings: strings,
          onOpenPlayer: onOpenPlayer,
          onAddToPlaylist: onAddToPlaylist,
        );
      },
      loading: () => _SearchBrowseCategoriesSliver(
        categories: browseCategories,
        onSelected: onBrowseCategorySelected,
      ),
      error: (error, _) => SliverFillRemaining(
        hasScrollBody: false,
        child: _SearchEmptyState(
          icon: Icons.error_outline_rounded,
          title: strings.searchErrorTitle,
          subtitle: error.toString(),
        ),
      ),
    );
  }

  static IconData _emptyIcon(SearchCategory category) => switch (category) {
    SearchCategory.songs => Icons.music_note_rounded,
    SearchCategory.videos => Icons.smart_display_rounded,
    SearchCategory.albums => Icons.album_rounded,
    SearchCategory.artists => Icons.person_rounded,
  };

  static String _emptyMessage(AppStrings strings, SearchCategory category) =>
      switch (category) {
        SearchCategory.songs => strings.searchSongsEmpty,
        SearchCategory.videos => strings.searchVideosEmpty,
        SearchCategory.albums => strings.searchAlbumsEmpty,
        SearchCategory.artists => strings.searchArtistsEmpty,
      };
}

enum _SearchBrowsePattern { confetti, orbit, waves, equalizer, rays, mosaic }

enum _SearchBrowsePalette {
  pop(
    Color(0xFFD81B60),
    Color(0xFF6A1B9A),
    Color(0xFFFF80AB),
    _SearchBrowsePattern.confetti,
  ),
  party(
    Color(0xFFFF7A18),
    Color(0xFFB3264A),
    Color(0xFFFFD166),
    _SearchBrowsePattern.rays,
  ),
  tropical(
    Color(0xFF168B69),
    Color(0xFF07565F),
    Color(0xFFF7C948),
    _SearchBrowsePattern.waves,
  ),
  chill(
    Color(0xFF287BAE),
    Color(0xFF3949AB),
    Color(0xFF80DEEA),
    _SearchBrowsePattern.waves,
  ),
  romance(
    Color(0xFFEC407A),
    Color(0xFF7B1E48),
    Color(0xFFFFCDD2),
    _SearchBrowsePattern.orbit,
  ),
  electronic(
    Color(0xFF00ACC1),
    Color(0xFF512DA8),
    Color(0xFF84FFFF),
    _SearchBrowsePattern.equalizer,
  ),
  classical(
    Color(0xFFA86832),
    Color(0xFF51302A),
    Color(0xFFFFCC80),
    _SearchBrowsePattern.orbit,
  ),
  jazz(
    Color(0xFF536DFE),
    Color(0xFF1A237E),
    Color(0xFFFFD54F),
    _SearchBrowsePattern.confetti,
  ),
  rock(
    Color(0xFFD33F49),
    Color(0xFF3E1725),
    Color(0xFFFF8A80),
    _SearchBrowsePattern.rays,
  ),
  latin(
    Color(0xFFF4511E),
    Color(0xFFAD1457),
    Color(0xFFFFCC80),
    _SearchBrowsePattern.mosaic,
  ),
  street(
    Color(0xFF6750A4),
    Color(0xFF25233F),
    Color(0xFFB39DDB),
    _SearchBrowsePattern.equalizer,
  ),
  workout(
    Color(0xFF43A047),
    Color(0xFF00695C),
    Color(0xFFB2FF59),
    _SearchBrowsePattern.rays,
  ),
  focus(
    Color(0xFF546E7A),
    Color(0xFF263238),
    Color(0xFFB0BEC5),
    _SearchBrowsePattern.orbit,
  ),
  sleep(
    Color(0xFF5C6BC0),
    Color(0xFF20204A),
    Color(0xFF9FA8DA),
    _SearchBrowsePattern.orbit,
  ),
  travel(
    Color(0xFF00838F),
    Color(0xFF37474F),
    Color(0xFF80CBC4),
    _SearchBrowsePattern.waves,
  ),
  games(
    Color(0xFF7E57C2),
    Color(0xFF283593),
    Color(0xFF69F0AE),
    _SearchBrowsePattern.mosaic,
  ),
  family(
    Color(0xFFEC6F66),
    Color(0xFFF3A183),
    Color(0xFFFFF59D),
    _SearchBrowsePattern.confetti,
  ),
  rainy(
    Color(0xFF607D8B),
    Color(0xFF303F5B),
    Color(0xFF90CAF9),
    _SearchBrowsePattern.waves,
  ),
  happy(
    Color(0xFFF9A825),
    Color(0xFFEF6C00),
    Color(0xFFFFFF8D),
    _SearchBrowsePattern.confetti,
  ),
  nostalgia(
    Color(0xFF8D6E63),
    Color(0xFF4E342E),
    Color(0xFFFFAB91),
    _SearchBrowsePattern.orbit,
  ),
  nature(
    Color(0xFF43A047),
    Color(0xFF1B5E20),
    Color(0xFFA5D6A7),
    _SearchBrowsePattern.rays,
  ),
  world(
    Color(0xFF00897B),
    Color(0xFF01579B),
    Color(0xFF4DD0E1),
    _SearchBrowsePattern.orbit,
  ),
  neon(
    Color(0xFF8E24AA),
    Color(0xFF4527A0),
    Color(0xFFEA80FC),
    _SearchBrowsePattern.equalizer,
  ),
  ocean(
    Color(0xFF039BE5),
    Color(0xFF006064),
    Color(0xFF40C4FF),
    _SearchBrowsePattern.waves,
  );

  const _SearchBrowsePalette(
    this.startColor,
    this.endColor,
    this.highlightColor,
    this.pattern,
  );

  final Color startColor;
  final Color endColor;
  final Color highlightColor;
  final _SearchBrowsePattern pattern;
}

final class _SearchBrowseVisual {
  const _SearchBrowseVisual({required this.icon, required this.palette});

  final IconData icon;
  final _SearchBrowsePalette palette;

  Color get startColor => palette.startColor;
  Color get endColor => palette.endColor;
  Color get highlightColor => palette.highlightColor;
  _SearchBrowsePattern get pattern => palette.pattern;

  static const _iconPool = <IconData>[
    Icons.music_note_rounded,
    Icons.celebration_rounded,
    Icons.wb_sunny_rounded,
    Icons.air_rounded,
    Icons.favorite_rounded,
    Icons.memory_rounded,
    Icons.piano_rounded,
    Icons.nightlife_rounded,
    Icons.electric_bolt_rounded,
    Icons.local_fire_department_rounded,
    Icons.mic_rounded,
    Icons.fitness_center_rounded,
    Icons.center_focus_strong_rounded,
    Icons.bedtime_rounded,
    Icons.directions_car_rounded,
    Icons.sports_esports_rounded,
    Icons.child_care_rounded,
    Icons.cloud_rounded,
    Icons.sentiment_very_satisfied_rounded,
    Icons.auto_awesome_rounded,
    Icons.history_rounded,
    Icons.landscape_rounded,
    Icons.restaurant_rounded,
    Icons.public_rounded,
    Icons.trending_up_rounded,
    Icons.headphones_rounded,
    Icons.album_rounded,
    Icons.queue_music_rounded,
    Icons.radio_rounded,
    Icons.library_music_rounded,
    Icons.music_video_rounded,
    Icons.audiotrack_rounded,
    Icons.graphic_eq_rounded,
    Icons.equalizer_rounded,
    Icons.speaker_rounded,
    Icons.explore_rounded,
    Icons.card_giftcard_rounded,
    Icons.directions_run_rounded,
  ];

  static List<_SearchBrowseVisual> forCategories(
    List<SearchBrowseCategory> categories,
  ) {
    final usedIconCodePoints = <int>{};
    return List<_SearchBrowseVisual>.generate(
      categories.length,
      (index) => forCategory(
        categories[index],
        position: index,
        usedIconCodePoints: usedIconCodePoints,
      ),
      growable: false,
    );
  }

  static _SearchBrowseVisual forCategory(
    SearchBrowseCategory category, {
    int position = 0,
    Set<int>? usedIconCodePoints,
  }) {
    final identity = _foldIdentity(
      '${category.id} ${category.title}'.toLowerCase(),
    );
    final palette = _paletteFor(identity);
    var icon = _iconFor(identity);
    if (usedIconCodePoints?.contains(icon.codePoint) ?? false) {
      final start = (_stableHash(identity) + position) % _iconPool.length;
      for (var offset = 0; offset < _iconPool.length; offset++) {
        final candidate = _iconPool[(start + offset) % _iconPool.length];
        if (!usedIconCodePoints!.contains(candidate.codePoint)) {
          icon = candidate;
          break;
        }
      }
    }
    usedIconCodePoints?.add(icon.codePoint);
    return _SearchBrowseVisual(icon: icon, palette: palette);
  }

  static IconData _iconFor(String identity) {
    if (_containsAny(identity, const [
      'navidad',
      'naviden',
      'christmas',
      'holiday',
    ])) {
      return Icons.card_giftcard_rounded;
    }
    if (_containsAny(identity, const ['party', 'fiesta', 'celebr'])) {
      return Icons.celebration_rounded;
    }
    if (_containsAny(identity, const ['reggae', 'island', 'caribbean'])) {
      return Icons.wb_sunny_rounded;
    }
    if (_containsAny(identity, const [
      'chill',
      'relax',
      'relaj',
      'ambient',
      'spa',
    ])) {
      return Icons.air_rounded;
    }
    if (_containsAny(identity, const ['love', 'amor', 'romance', 'romant'])) {
      return Icons.favorite_rounded;
    }
    if (_containsAny(identity, const ['electr', 'edm', 'techno', 'house'])) {
      return Icons.memory_rounded;
    }
    if (_containsAny(identity, const [
      'classic',
      'clasica',
      'piano',
      'orquest',
    ])) {
      return Icons.piano_rounded;
    }
    if (_containsAny(identity, const ['jazz', 'blues', 'soul'])) {
      return Icons.nightlife_rounded;
    }
    if (_containsAny(identity, const ['rock', 'metal', 'punk'])) {
      return Icons.electric_bolt_rounded;
    }
    if (_containsAny(identity, const ['latin', 'salsa', 'cumbia', 'bachata'])) {
      return Icons.local_fire_department_rounded;
    }
    if (_containsAny(identity, const ['hip', 'rap', 'r&b', 'urbano'])) {
      return Icons.mic_rounded;
    }
    if (_containsAny(identity, const [
      'workout',
      'fitness',
      'entrena',
      'gym',
      'exercise',
      'ejercicio',
      'deporte',
      'estado f',
      'running',
      'correr',
    ])) {
      return Icons.fitness_center_rounded;
    }
    if (_containsAny(identity, const ['energy', 'energia', 'energ', 'power'])) {
      return Icons.electric_bolt_rounded;
    }
    if (_containsAny(identity, const [
      'focus',
      'concentra',
      'study',
      'estudi',
    ])) {
      return Icons.center_focus_strong_rounded;
    }
    if (_containsAny(identity, const ['sleep', 'dormir', 'noche'])) {
      return Icons.bedtime_rounded;
    }
    if (_containsAny(identity, const [
      'commute',
      'driv',
      'viaje',
      'carretera',
      'road trip',
      'camino',
    ])) {
      return Icons.directions_car_rounded;
    }
    if (_containsAny(identity, const ['gaming', 'game', 'juego'])) {
      return Icons.sports_esports_rounded;
    }
    if (_containsAny(identity, const ['kid', 'family', 'nin', 'famil'])) {
      return Icons.child_care_rounded;
    }
    if (_containsAny(identity, const ['sad', 'triste', 'melancol', 'rain'])) {
      return Icons.cloud_rounded;
    }
    if (_containsAny(identity, const [
      'happy',
      'feel good',
      'feliz',
      'alegre',
      'sentirse bien',
      'buen an',
    ])) {
      return Icons.sentiment_very_satisfied_rounded;
    }
    if (_containsAny(identity, const [
      'decade',
      'retro',
      'oldies',
      'recuerdo',
    ])) {
      return Icons.history_rounded;
    }
    if (_containsAny(identity, const ['country', 'folk', 'campirano'])) {
      return Icons.landscape_rounded;
    }
    if (_containsAny(identity, const ['cook', 'comida', 'cocina'])) {
      return Icons.restaurant_rounded;
    }
    if (_containsAny(identity, const ['world', 'mundo', 'global'])) {
      return Icons.public_rounded;
    }
    if (_containsAny(identity, const ['pop', 'chart', 'hit', 'xito', 'top'])) {
      return Icons.music_note_rounded;
    }
    return _iconPool[_stableHash(identity) % _iconPool.length];
  }

  static _SearchBrowsePalette _paletteFor(String identity) {
    if (_containsAny(identity, const [
      'navidad',
      'naviden',
      'christmas',
      'holiday',
    ])) {
      return _SearchBrowsePalette.happy;
    }
    if (_containsAny(identity, const ['party', 'fiesta', 'celebr'])) {
      return _SearchBrowsePalette.party;
    }
    if (_containsAny(identity, const ['reggae', 'island', 'caribbean'])) {
      return _SearchBrowsePalette.tropical;
    }
    if (_containsAny(identity, const [
      'chill',
      'relax',
      'relaj',
      'ambient',
      'spa',
    ])) {
      return _SearchBrowsePalette.chill;
    }
    if (_containsAny(identity, const ['love', 'amor', 'romance', 'romant'])) {
      return _SearchBrowsePalette.romance;
    }
    if (_containsAny(identity, const ['electr', 'edm', 'techno', 'house'])) {
      return _SearchBrowsePalette.electronic;
    }
    if (_containsAny(identity, const [
      'classic',
      'clasica',
      'piano',
      'orquest',
    ])) {
      return _SearchBrowsePalette.classical;
    }
    if (_containsAny(identity, const ['jazz', 'blues', 'soul'])) {
      return _SearchBrowsePalette.jazz;
    }
    if (_containsAny(identity, const ['rock', 'metal', 'punk'])) {
      return _SearchBrowsePalette.rock;
    }
    if (_containsAny(identity, const ['latin', 'salsa', 'cumbia', 'bachata'])) {
      return _SearchBrowsePalette.latin;
    }
    if (_containsAny(identity, const ['hip', 'rap', 'r&b', 'urbano'])) {
      return _SearchBrowsePalette.street;
    }
    if (_containsAny(identity, const [
      'workout',
      'fitness',
      'entrena',
      'gym',
      'exercise',
      'ejercicio',
      'deporte',
      'estado f',
      'running',
      'correr',
    ])) {
      return _SearchBrowsePalette.workout;
    }
    if (_containsAny(identity, const ['energy', 'energia', 'energ', 'power'])) {
      return _SearchBrowsePalette.neon;
    }
    if (_containsAny(identity, const [
      'focus',
      'concentra',
      'study',
      'estudi',
    ])) {
      return _SearchBrowsePalette.focus;
    }
    if (_containsAny(identity, const ['sleep', 'dormir', 'noche'])) {
      return _SearchBrowsePalette.sleep;
    }
    if (_containsAny(identity, const [
      'commute',
      'driv',
      'viaje',
      'carretera',
      'road trip',
      'camino',
    ])) {
      return _SearchBrowsePalette.travel;
    }
    if (_containsAny(identity, const ['gaming', 'game', 'juego'])) {
      return _SearchBrowsePalette.games;
    }
    if (_containsAny(identity, const ['kid', 'family', 'nin', 'famil'])) {
      return _SearchBrowsePalette.family;
    }
    if (_containsAny(identity, const ['sad', 'triste', 'melancol', 'rain'])) {
      return _SearchBrowsePalette.rainy;
    }
    if (_containsAny(identity, const [
      'happy',
      'feel good',
      'feliz',
      'alegre',
      'sentirse bien',
      'buen an',
    ])) {
      return _SearchBrowsePalette.happy;
    }
    if (_containsAny(identity, const [
      'decade',
      'retro',
      'oldies',
      'recuerdo',
    ])) {
      return _SearchBrowsePalette.nostalgia;
    }
    if (_containsAny(identity, const ['country', 'folk', 'campirano'])) {
      return _SearchBrowsePalette.nature;
    }
    if (_containsAny(identity, const ['world', 'mundo', 'global'])) {
      return _SearchBrowsePalette.world;
    }
    if (_containsAny(identity, const ['pop', 'chart', 'hit', 'xito', 'top'])) {
      return _SearchBrowsePalette.pop;
    }
    return _SearchBrowsePalette.values[_stableHash(identity) %
        _SearchBrowsePalette.values.length];
  }

  static int _stableHash(String value) {
    var hash = 0;
    for (final rune in value.runes) {
      hash = 0x1fffffff & (hash * 31 + rune);
    }
    return hash;
  }

  static String _foldIdentity(String value) => value
      .replaceAll('\u00e1', 'a')
      .replaceAll('\u00e0', 'a')
      .replaceAll('\u00e4', 'a')
      .replaceAll('\u00e9', 'e')
      .replaceAll('\u00e8', 'e')
      .replaceAll('\u00eb', 'e')
      .replaceAll('\u00ed', 'i')
      .replaceAll('\u00ec', 'i')
      .replaceAll('\u00ef', 'i')
      .replaceAll('\u00f3', 'o')
      .replaceAll('\u00f2', 'o')
      .replaceAll('\u00f6', 'o')
      .replaceAll('\u00fa', 'u')
      .replaceAll('\u00f9', 'u')
      .replaceAll('\u00fc', 'u')
      .replaceAll('\u00f1', 'n');

  static bool _containsAny(String value, List<String> candidates) =>
      candidates.any(value.contains);
}

class _SearchBrowseCategoriesSliver extends StatelessWidget {
  const _SearchBrowseCategoriesSliver({
    required this.categories,
    required this.onSelected,
  });

  final List<SearchBrowseCategory> categories;
  final ValueChanged<SearchBrowseCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    final cardExtent = (textScaler.scale(20) * 2 + 28)
        .clamp(96.0, 220.0)
        .toDouble();
    final visuals = _SearchBrowseVisual.forCategories(categories);

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 18),
      sliver: SliverGrid(
        key: const ValueKey('search-browse-grid'),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisExtent: cardExtent,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final category = categories[index];
          return _SearchBrowseCategoryCard(
            key: ValueKey('search-browse-card-${category.id}'),
            category: category,
            visual: visuals[index],
            onTap: () => onSelected(category),
          );
        }, childCount: categories.length),
      ),
    );
  }
}

class _SearchBrowseCategoryCard extends StatelessWidget {
  const _SearchBrowseCategoryCard({
    required this.category,
    required this.visual,
    required this.onTap,
    super.key,
  });

  final SearchBrowseCategory category;
  final _SearchBrowseVisual visual;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.all(Radius.circular(12));
    return Semantics(
      button: true,
      label: category.title,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: Ink(
          key: ValueKey('search-browse-surface-${category.id}'),
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: AlignmentDirectional.topStart,
              end: AlignmentDirectional.bottomEnd,
              colors: [visual.startColor, visual.endColor],
            ),
          ),
          child: InkWell(
            key: ValueKey('search-browse-action-${category.id}'),
            borderRadius: radius,
            onTap: onTap,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: ValueKey('search-browse-pattern-${category.id}'),
                        painter: _SearchBrowsePatternPainter(
                          pattern: visual.pattern,
                          color: visual.highlightColor,
                        ),
                      ),
                    ),
                  ),
                ),
                PositionedDirectional(
                  end: -7,
                  bottom: -9,
                  child: Transform.rotate(
                    angle: -0.13,
                    child: Container(
                      key: ValueKey('search-browse-art-${category.id}'),
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.24),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withValues(alpha: 0.28),
                            visual.highlightColor.withValues(alpha: 0.20),
                            Colors.black.withValues(alpha: 0.08),
                          ],
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x32000000),
                            blurRadius: 12,
                            offset: Offset(-2, 4),
                          ),
                        ],
                      ),
                      child: Icon(
                        visual.icon,
                        key: ValueKey('search-browse-icon-${category.id}'),
                        size: 34,
                        color: Colors.white.withValues(alpha: 0.94),
                        shadows: const [
                          Shadow(color: Color(0x3D000000), blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      14,
                      13,
                      64,
                      13,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.topStart,
                      child: Text(
                        category.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              height: 1.08,
                              shadows: const [
                                Shadow(color: Color(0x52000000), blurRadius: 3),
                              ],
                            ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _SearchBrowsePatternPainter extends CustomPainter {
  const _SearchBrowsePatternPainter({
    required this.pattern,
    required this.color,
  });

  final _SearchBrowsePattern pattern;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final fill = Paint()
      ..color = color.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;

    switch (pattern) {
      case _SearchBrowsePattern.confetti:
        final marks = <Offset>[
          Offset(size.width * 0.55, size.height * 0.19),
          Offset(size.width * 0.72, size.height * 0.30),
          Offset(size.width * 0.88, size.height * 0.15),
          Offset(size.width * 0.63, size.height * 0.53),
          Offset(size.width * 0.83, size.height * 0.63),
        ];
        for (var index = 0; index < marks.length; index++) {
          final mark = marks[index];
          if (index.isEven) {
            canvas.drawCircle(mark, index == 0 ? 4.2 : 2.8, fill);
          } else {
            canvas.drawLine(
              mark - const Offset(3, 5),
              mark + const Offset(3, 5),
              stroke,
            );
          }
        }
        break;
      case _SearchBrowsePattern.orbit:
        final center = Offset(size.width * 0.88, size.height * 0.76);
        canvas.drawCircle(center, size.shortestSide * 0.33, stroke);
        canvas.drawCircle(center, size.shortestSide * 0.48, stroke);
        canvas.drawCircle(
          center.translate(-size.shortestSide * 0.29, -4),
          3.6,
          fill,
        );
        break;
      case _SearchBrowsePattern.waves:
        for (var row = 0; row < 3; row++) {
          final y = size.height * (0.40 + row * 0.14);
          final path = Path()
            ..moveTo(size.width * 0.42, y)
            ..cubicTo(
              size.width * 0.57,
              y - 10,
              size.width * 0.67,
              y + 10,
              size.width * 0.82,
              y,
            )
            ..cubicTo(
              size.width * 0.90,
              y - 5,
              size.width * 0.96,
              y - 4,
              size.width,
              y,
            );
          canvas.drawPath(path, stroke);
        }
        break;
      case _SearchBrowsePattern.equalizer:
        const heights = <double>[0.18, 0.38, 0.25, 0.52, 0.31, 0.44];
        final barWidth = (size.width * 0.38 / heights.length)
            .clamp(3.0, 8.0)
            .toDouble();
        for (var index = 0; index < heights.length; index++) {
          final left = size.width * 0.58 + index * (barWidth + 4);
          final barHeight = size.height * heights[index];
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(left, size.height - barHeight, barWidth, barHeight),
              const Radius.circular(3),
            ),
            fill,
          );
        }
        break;
      case _SearchBrowsePattern.rays:
        final origin = Offset(size.width * 0.88, size.height * 0.82);
        final destinations = <Offset>[
          Offset(size.width * 0.45, 0),
          Offset(size.width * 0.64, 0),
          Offset(size.width * 0.83, 0),
          Offset(size.width, size.height * 0.08),
          Offset(size.width, size.height * 0.38),
        ];
        for (final destination in destinations) {
          canvas.drawLine(origin, destination, stroke);
        }
        canvas.drawCircle(origin, size.shortestSide * 0.23, fill);
        break;
      case _SearchBrowsePattern.mosaic:
        final tilePaint = Paint()
          ..color = color.withValues(alpha: 0.12)
          ..style = PaintingStyle.fill;
        canvas.save();
        canvas.translate(size.width * 0.67, size.height * 0.10);
        canvas.rotate(-0.22);
        for (var row = 0; row < 3; row++) {
          for (var column = 0; column < 3; column++) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(column * 22, row * 22, 16, 16),
                const Radius.circular(4),
              ),
              tilePaint,
            );
          }
        }
        canvas.restore();
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _SearchBrowsePatternPainter oldDelegate) =>
      pattern != oldDelegate.pattern || color != oldDelegate.color;
}

class _SearchCategoryResultsSliver extends StatefulWidget {
  const _SearchCategoryResultsSliver({
    required this.state,
    required this.strings,
    required this.onOpenPlayer,
    required this.onAddToPlaylist,
  });

  static const _transitionDuration = Duration(milliseconds: 240);

  final SearchState state;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  State<_SearchCategoryResultsSliver> createState() =>
      _SearchCategoryResultsSliverState();
}

class _SearchCategoryResultsSliverState
    extends State<_SearchCategoryResultsSliver> {
  int _direction = 1;

  @override
  void didUpdateWidget(covariant _SearchCategoryResultsSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.state.selectedCategory.index;
    final next = widget.state.selectedCategory.index;
    if (previous != next) {
      _direction = next > previous ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final selectedCategory = widget.state.selectedCategory;
    final selectedKey = ValueKey(
      'search-category-results-${selectedCategory.name}',
    );

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 18),
      sliver: SliverToBoxAdapter(
        child: AnimatedSwitcher(
          key: const ValueKey('search-results-switcher'),
          duration: disableAnimations
              ? Duration.zero
              : _SearchCategoryResultsSliver._transitionDuration,
          reverseDuration: disableAnimations
              ? Duration.zero
              : _SearchCategoryResultsSliver._transitionDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: <Widget>[...previousChildren, ?currentChild],
          ),
          transitionBuilder: (child, animation) {
            final incoming = child.key == selectedKey;
            final horizontalOffset = incoming
                ? 0.045 * _direction
                : -0.03 * _direction;
            return ClipRect(
              child: FadeTransition(
                opacity: Tween<double>(begin: 0.35, end: 1).animate(animation),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(horizontalOffset, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
            );
          },
          // The key changes only with the selected category. Loading a page,
          // refreshing it, or updating its bounded results therefore does not
          // replay the tab transition or disturb the outer scroll position.
          child: KeyedSubtree(
            key: selectedKey,
            child: _SearchCategoryResultsBody(
              state: widget.state,
              strings: widget.strings,
              onOpenPlayer: widget.onOpenPlayer,
              onAddToPlaylist: widget.onAddToPlaylist,
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchCategoryResultsBody extends StatelessWidget {
  const _SearchCategoryResultsBody({
    required this.state,
    required this.strings,
    required this.onOpenPlayer,
    required this.onAddToPlaylist,
  });

  final SearchState state;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    if (state.isSelectedCategoryLoading || !state.hasSelectedPage) {
      return SizedBox(
        height: _minimumBodyHeight(context),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final page = state.selectedPage!;
    if (page.isEmpty) {
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: _minimumBodyHeight(context)),
        child: _SearchEmptyState(
          icon: _SearchResultsSliver._emptyIcon(state.selectedCategory),
          title: _categoryLabel(strings, state.selectedCategory),
          subtitle: _SearchResultsSliver._emptyMessage(
            strings,
            state.selectedCategory,
          ),
        ),
      );
    }

    if (state.selectedCategory == SearchCategory.albums) {
      return Column(
        children: [
          for (var index = 0; index < page.albums.length; index++) ...[
            _AlbumResultTile(
              key: ValueKey('search-album-${page.albums[index].browseId}'),
              album: page.albums[index],
              strings: strings,
              onOpenPlayer: onOpenPlayer,
              onAddToPlaylist: onAddToPlaylist,
            ),
            if (index < page.albums.length - 1) const SizedBox(height: 6),
          ],
        ],
      );
    }

    if (state.selectedCategory == SearchCategory.artists) {
      return _ArtistResultsGrid(
        artists: page.artists,
        strings: strings,
        onOpenPlayer: onOpenPlayer,
      );
    }

    final tracks = page.tracks;
    // Search pages are deliberately bounded, so keeping their rows mounted
    // makes the cross-fade stable and avoids decoding thumbnails repeatedly.
    return Column(
      children: [
        for (var index = 0; index < tracks.length; index++) ...[
          TrackResultTile(
            key: ValueKey(
              'search-result-${tracks[index].id.isNotEmpty ? tracks[index].id : tracks[index].url}',
            ),
            track: tracks[index],
            queue: tracks,
            preferCatalogArtwork:
                state.selectedCategory != SearchCategory.videos,
            onOpenPlayer: onOpenPlayer,
          ),
          if (index < tracks.length - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }

  double _minimumBodyHeight(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.48).clamp(220.0, 480.0);
}

class _SearchCategoryTabs extends StatelessWidget {
  const _SearchCategoryTabs({
    required this.categories,
    required this.selectedCategory,
    required this.strings,
    required this.onSelected,
  });

  final List<SearchCategory> categories;
  final SearchCategory selectedCategory;
  final AppStrings strings;
  final ValueChanged<SearchCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final labelStyle =
        (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w800,
        );
    final tabWidths = <double>[
      for (final category in categories)
        _naturalTabWidth(
          label: _categoryLabel(strings, category),
          style: labelStyle,
          textScaler: textScaler,
          textDirection: textDirection,
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 6.0;
        final spacingWidth = categories.length > 1
            ? spacing * (categories.length - 1)
            : 0.0;
        final naturalWidth = tabWidths.fold<double>(
          spacingWidth,
          (total, width) => total + width,
        );
        final extraWidthPerTab =
            categories.isNotEmpty && constraints.maxWidth > naturalWidth
            ? (constraints.maxWidth - naturalWidth) / categories.length
            : 0.0;

        return SingleChildScrollView(
          key: const ValueKey('search-category-horizontal-scroll'),
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < categories.length; index++) ...[
                if (index > 0) const SizedBox(width: spacing),
                SizedBox(
                  width: tabWidths[index] + extraWidthPerTab,
                  child: _SearchCategoryTab(
                    category: categories[index],
                    icon: _categoryIcon(categories[index]),
                    label: _categoryLabel(strings, categories[index]),
                    selected: categories[index] == selectedCategory,
                    selectedColor: colors.primaryContainer,
                    onSelected: onSelected,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  double _naturalTabWidth({
    required String label,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      maxLines: 1,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();

    // Icon (18), separation (4) and the horizontal breathing room (24).
    final width = painter.width + 46;
    return width < 92 ? 92 : width;
  }
}

class _SearchCategoryTab extends StatelessWidget {
  const _SearchCategoryTab({
    required this.category,
    required this.icon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.onSelected,
  });

  final SearchCategory category;
  final IconData icon;
  final String label;
  final bool selected;
  final Color selectedColor;
  final ValueChanged<SearchCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(appNavItemRadius);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final motionDuration = disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final scaledLabelHeight = MediaQuery.textScalerOf(context).scale(14);
    final tapTargetHeight = (scaledLabelHeight + 20)
        .clamp(48.0, 80.0)
        .toDouble();
    final surfaceHeight = (scaledLabelHeight + 14).clamp(44.0, 74.0).toDouble();
    final contentColor = selected
        ? colors.onPrimaryContainer
        : AppColors.contentTitleFor(context);

    return Semantics(
      selected: selected,
      button: true,
      child: SizedBox(
        height: tapTargetHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AnimatedContainer(
                key: ValueKey('search-category-surface-${category.name}'),
                width: double.infinity,
                height: surfaceHeight,
                duration: motionDuration,
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: selected
                      ? selectedColor
                      : AppColors.cardSurfaceFor(context),
                  borderRadius: radius,
                  border: Border.all(
                    color: selected
                        ? colors.primary
                        : AppColors.cardBorderFor(context),
                  ),
                ),
              ),
            ),
            Material(
              color: Colors.transparent,
              child: InkWell(
                key: ValueKey('search-category-${category.name}'),
                borderRadius: radius,
                onTap: selected ? null : () => onSelected(category),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TweenAnimationBuilder<Color?>(
                          duration: motionDuration,
                          curve: Curves.easeOutCubic,
                          tween: ColorTween(end: contentColor),
                          builder: (context, color, _) => Icon(
                            icon,
                            key: ValueKey(
                              'search-category-icon-${category.name}',
                            ),
                            size: 18,
                            color: color ?? contentColor,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: AnimatedDefaultTextStyle(
                            duration: motionDuration,
                            curve: Curves.easeOutCubic,
                            style:
                                (Theme.of(context).textTheme.labelLarge ??
                                        const TextStyle())
                                    .copyWith(
                                      color: contentColor,
                                      fontWeight: selected
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                    ),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArtistResultsGrid extends StatelessWidget {
  const _ArtistResultsGrid({
    required this.artists,
    required this.strings,
    required this.onOpenPlayer,
  });

  final List<SearchArtist> artists;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        const targetCardWidth = 126.0;
        final availableWidth = constraints.maxWidth;
        final columnCount =
            ((availableWidth + spacing) / (targetCardWidth + spacing))
                .floor()
                .clamp(2, 8);
        final cardWidth =
            (availableWidth - spacing * (columnCount - 1)) / columnCount;

        return Wrap(
          key: const ValueKey('search-artist-results'),
          spacing: spacing,
          runSpacing: 12,
          children: [
            for (final artist in artists)
              _ArtistResultCard(
                key: ValueKey('search-artist-${artist.browseId}'),
                artist: artist,
                strings: strings,
                width: cardWidth,
                onOpenPlayer: onOpenPlayer,
              ),
          ],
        );
      },
    );
  }
}

class _ArtistResultCard extends ConsumerWidget {
  const _ArtistResultCard({
    required this.artist,
    required this.strings,
    required this.width,
    required this.onOpenPlayer,
    super.key,
  });

  final SearchArtist artist;
  final AppStrings strings;
  final double width;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final artworkExtent = (width - 16).clamp(76.0, 124.0);
    final radius = BorderRadius.circular(appCardRadius);

    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: '${strings.goToArtist}: ${artist.name}',
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            key: ValueKey('search-artist-open-${artist.browseId}'),
            borderRadius: radius,
            onTap: () => _openArtist(context, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppColors.cardBorderFor(context),
                      ),
                    ),
                    padding: const EdgeInsets.all(1),
                    child: ClipOval(
                      key: ValueKey('search-artist-artwork-${artist.browseId}'),
                      child: SizedBox.square(
                        dimension: artworkExtent,
                        child: SourceImage(
                          source: artist.thumbnailUrl,
                          cacheWidth: 384,
                          fallback: ColoredBox(
                            color: colors.surfaceContainerHighest,
                            child: Icon(
                              Icons.person_rounded,
                              size: artworkExtent * 0.42,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    artist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.contentTitleFor(context),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openArtist(BuildContext context, WidgetRef ref) {
    final request = (
      artistBrowseId: artist.browseId,
      artistName: artist.name,
      artistThumbnailUrl: artist.thumbnailUrl,
    );
    unawaited(
      ref
          .read(artistProfileProvider(request).future)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ArtistProfilePage(
          artistBrowseId: artist.browseId,
          artistName: artist.name,
          artistThumbnailUrl: artist.thumbnailUrl,
          onOpenPlayer: onOpenPlayer,
        ),
      ),
    );
  }
}

class _FallbackNotice extends StatelessWidget {
  const _FallbackNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('search-fallback-notice'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colors.onSecondaryContainer.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 20,
            color: colors.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumResultTile extends StatefulWidget {
  const _AlbumResultTile({
    required this.album,
    required this.strings,
    required this.onOpenPlayer,
    this.onAddToPlaylist,
    super.key,
  });

  final SearchAlbum album;
  final AppStrings strings;
  final VoidCallback onOpenPlayer;
  final AddRemoteTracksToPlaylist? onAddToPlaylist;

  @override
  State<_AlbumResultTile> createState() => _AlbumResultTileState();
}

class _AlbumResultTileState extends State<_AlbumResultTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(appCardRadius);
    final surface = _hovered
        ? Color.alphaBlend(
            colors.onSurface.withValues(alpha: 0.09),
            AppColors.cardSurfaceFor(context),
          )
        : AppColors.cardSurfaceFor(context);
    final details = [
      album.type?.trim(),
      album.year?.trim(),
    ].whereType<String>().where((value) => value.isNotEmpty).join(' • ');
    final artist = album.artist.trim().isEmpty
        ? widget.strings.unknownArtist
        : album.artist.trim();

    return Semantics(
      button: true,
      label: widget.strings.openAlbum(album.title),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: surface,
            borderRadius: radius,
            border: Border.all(
              color: _hovered
                  ? colors.primary
                  : AppColors.cardBorderFor(context),
              width: _hovered ? 1.4 : 1,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('search-album-open-${album.browseId}'),
              borderRadius: radius,
              onTap: _openAlbum,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    HoverEqualizerArtwork(
                      width: 52,
                      height: 18,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(appArtworkRadius),
                        child: SizedBox.square(
                          dimension: 62,
                          child: ProportionalArtwork(
                            source: album.thumbnailUrl,
                            cacheWidth: 256,
                            fallback: const ColoredBox(
                              color: Color(0xFF202520),
                              child: Icon(Icons.album_rounded),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MarqueeText(
                            album.title,
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(
                                  color: AppColors.contentTitleFor(context),
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            artist,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: AppColors.contentSubtitleFor(context),
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (details.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              details,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: AppColors.contentSubtitleFor(
                                      context,
                                    ),
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.primary,
                      size: 30,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openAlbum() {
    final album = widget.album;
    final artist = album.artist.trim().isEmpty
        ? widget.strings.unknownArtist
        : album.artist.trim();
    final metadata = [album.type?.trim() ?? '', album.year?.trim() ?? ''];
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: album.title,
          subtitle: artist,
          artworkSource: album.thumbnailUrl,
          metadata: metadata,
          fallbackIcon: Icons.album_rounded,
          useCollectionArtworkForTrackFallback: true,
          queueSourceId: 'album:${album.browseId}',
          tracksProvider: searchAlbumTracksProvider(album.browseId),
          emptyMessage: widget.strings.albumWithoutSongs,
          errorMessage: widget.strings.albumLoadError,
          onOpenPlayer: widget.onOpenPlayer,
          onAddToPlaylist: widget.onAddToPlaylist,
        ),
      ),
    );
  }
}

String _categoryLabel(AppStrings strings, SearchCategory category) =>
    switch (category) {
      SearchCategory.songs => strings.searchSongs,
      SearchCategory.videos => strings.searchVideos,
      SearchCategory.albums => strings.searchAlbums,
      SearchCategory.artists => strings.searchArtists,
    };

IconData _categoryIcon(SearchCategory category) => switch (category) {
  SearchCategory.songs => Icons.music_note_rounded,
  SearchCategory.videos => Icons.smart_display_rounded,
  SearchCategory.albums => Icons.album_rounded,
  SearchCategory.artists => Icons.person_rounded,
};

class _SearchEmptyState extends StatelessWidget {
  const _SearchEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 46,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.contentTitleFor(context),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.contentSubtitleFor(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
