import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/errors/app_exception.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/platform/app_platform.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/bounded_byte_stream.dart';
import '../../../../core/utils/image_source.dart';
import '../../../../core/utils/safe_file_name.dart';
import '../../../../services/downloader/audio_stream_resolver.dart';
import '../../../../services/downloader/downloader_service.dart';
import '../../../../services/downloader/innertube_audio_resolver.dart';
import '../../../../services/downloader/innertube_download_service.dart';
import '../../../../services/live/tiktok_live_command_service.dart';
import '../../../../services/lyrics/lyrics_service.dart';
import '../../../../services/lyrics/lyrics_romanization_service.dart';
import '../../../../services/media_session/desktop_media_session.dart';
import '../../../../services/media_session/desktop_media_session_binding.dart';
import '../../../../services/media_session/desktop_media_session_factory.dart';
import '../../../../services/player/just_audio_player_service.dart';
import '../../../../services/player/media_kit_player_service.dart';
import '../../../../services/player/player_service.dart';
import '../../../../services/recommendations/recommendations.dart';
import '../../../../services/sharing/bstream_track_link.dart';
import '../../../../services/sharing/incoming_track_link_service.dart';
import '../../../../services/sharing/track_share_service.dart';
import '../../../../services/sharing/youtube_music_playlist_share_service.dart';
import '../../../../services/sharing/youtube_music_link.dart';
import '../../../../services/storage/backup_service.dart';
import '../../../../services/storage/library_csv_import_service.dart';
import '../../../../services/storage/library_csv_service.dart';
import '../../../../services/storage/library_operation_coordinator.dart';
import '../../../../services/storage/local_database_service.dart';
import '../../../../services/storage/local_database_shutdown_coordinator.dart';
import '../../../../services/storage/local_library_reconciler.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../../../services/youtube_music/shared_preferences_visitor_data_store.dart';
import '../../../../services/youtube_music/playback/playback.dart';
import '../../../../services/youtube_music/account/youtube_music_account.dart'
    as ytm_account;
import '../../../../services/youtube_music/playlist_sync/playlist_account_sync_coordinator.dart';
import '../../../../services/youtube_music/playlist_sync/playlist_sync_engine.dart';
import '../../../../services/youtube_music/playlist_sync/playlist_sync_consent_store.dart';
import '../../../../services/youtube_music/playlist_sync/playlist_sync_models.dart';
import '../../../../services/youtube_music/playlist_sync/playlist_sync_store.dart';
import '../../../../services/youtube_music/playlist_sync/playlist_three_way_merger.dart';
import '../../../../services/youtube_music/playlist_sync/sqlite_playlist_sync_store.dart';
import '../../../../services/youtube_music/playlist_sync/youtube_music_account_playlist_gateway.dart';
import '../../data/datasources/local_music_datasource.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../data/models/track_info_model.dart';
import '../../data/repositories/catalog_playlist_repository_impl.dart';
import '../../data/repositories/library_repository_impl.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/entities/download_options.dart';
import '../../domain/entities/download_result.dart';
import '../../domain/entities/catalog_playlist.dart';
import '../../domain/entities/catalog_track.dart';
import '../../domain/entities/playlist_entry.dart';
import '../../domain/entities/local_track.dart';
import '../../domain/entities/lyrics.dart';
import '../../domain/entities/playlist.dart';
import '../../domain/entities/track_info.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories/library_repository.dart';
import '../../domain/repositories/music_repository.dart';
import '../../domain/usecases/download_audio.dart';
import '../../domain/usecases/get_playback_info.dart';
import '../../domain/usecases/get_history.dart';
import '../../domain/usecases/get_library_tracks.dart';
import '../../domain/usecases/get_playlists.dart';
import '../../domain/usecases/get_track_info.dart';
import '../../domain/usecases/search_tracks.dart';
import 'app_strings.dart';
import 'lyrics_animation_style.dart';
import 'mini_player_background_mode.dart';
import 'mini_player_mode.dart';
import 'player_style.dart';
import 'youtube_music_auth_controller.dart';
import 'player/catalog_playback_item.dart';
import 'player/catalog_playlist_playback.dart';
import 'player/playback_identity.dart';
import 'player/recommendation_playback_item.dart';
import 'player/recommendation_queue_extension_coordinator.dart';
import 'player/remote_playback_source_factory.dart';
import 'player/remote_prefetch_coordinator.dart';
import 'player/remote_playback_retry_coordinator.dart';

export 'app_strings.dart';
export 'lyrics_animation_style.dart';
export 'mini_player_background_mode.dart';
export 'mini_player_mode.dart';
export 'player_style.dart';
export 'player/catalog_playback_item.dart';
export 'player/catalog_playlist_playback.dart';
export 'player/playback_identity.dart';
export 'player/recommendation_playback_item.dart';
export 'player/recommendation_queue_extension_coordinator.dart';
export 'player/remote_playback_source_factory.dart';
export 'player/remote_prefetch_coordinator.dart';
export 'player/remote_playback_retry_coordinator.dart';
export '../../domain/entities/lyrics_romanization_language.dart';

part 'app_strings_provider.dart';
part 'download_controller.dart';
part 'download_directory_migrator.dart';
part 'local_track_download_helper.dart';
part 'library_csv_transfer_controller.dart';
part 'lyrics_offset_controller.dart';
part 'playback_history_tracker.dart';
part 'player/player_queue_components.dart';
part 'player/player_playback_coordinators.dart';
part 'player/playback_history_track_factory.dart';
part 'player_controller.dart';
part 'playlists_controller.dart';
part 'remote_playback_cache.dart';
part 'remote_track_resolver.dart';
part 'search_controller.dart';
part 'settings_controller.dart';
part 'sleep_timer_controller.dart';
part 'tiktok_live_controller.dart';
part 'youtube_music_playlist_sync_controller.dart';

String _innerTubeDeviceRegion() {
  final country = PlatformDispatcher.instance.locale.countryCode
      ?.trim()
      .toUpperCase();
  return country != null && RegExp(r'^[A-Z]{2}$').hasMatch(country)
      ? country
      : 'US';
}

final innerTubePlaybackServiceProvider = Provider<InnerTubePlaybackService>((
  ref,
) {
  final platform = AppPlatform.current;
  final supportsChallenges =
      HeadlessInAppWebViewJavaScriptRuntime.supportsPlatform(platform);
  final service = InnerTubePlaybackService(
    visitorDataStore: const SharedPreferencesInnerTubeVisitorDataStore(),
    ejsSolver: supportsChallenges
        ? EjsSolver(runtime: HeadlessInAppWebViewJavaScriptRuntime())
        : null,
    poTokenProvider: supportsChallenges ? BotGuardPoTokenProvider() : null,
    audioFormatPredicate: platform == AppPlatformType.ios
        ? isAvFoundationCompatibleInnerTubeAudio
        : null,
    language: PlatformDispatcher.instance.locale.languageCode,
    region: _innerTubeDeviceRegion(),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final downloaderServiceProvider = Provider<DownloaderService>((ref) {
  final service = InnerTubeDownloadService(
    playback: ref.watch(innerTubePlaybackServiceProvider),
    catalog: ref.watch(youtubeMusicSearchProvider),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

final downloaderWarmupProvider = FutureProvider<void>((ref) async {
  await ref.watch(downloaderServiceProvider).initialize();
});

final playerServiceProvider = Provider<PlayerService>((ref) {
  final PlayerService service = AppPlatform.isDesktop
      ? MediaKitPlayerService()
      : JustAudioPlayerService();
  ref.onDispose(service.dispose);
  return service;
});

final trackShareServiceProvider = Provider<TrackShareService>((ref) {
  return const SharePlusTrackShareService();
});

final youtubeMusicPlaylistShareServiceProvider =
    Provider<YouTubeMusicPlaylistShareService>((ref) {
      return const SharePlusYouTubeMusicPlaylistShareService();
    });

final incomingTrackLinkServiceProvider = Provider<IncomingTrackLinkService>((
  ref,
) {
  return AppLinksIncomingTrackLinkService();
});

final bstreamTrackLinkCodecProvider = Provider<BStreamTrackLinkCodec>((ref) {
  return const BStreamTrackLinkCodec();
});

/// Valid BStream activations, with the occasional cold/warm duplicate removed.
final incomingTrackLinkProvider = StreamProvider<BStreamTrackLink>((
  ref,
) async* {
  final source = ref.watch(incomingTrackLinkServiceProvider);
  final codec = ref.watch(bstreamTrackLinkCodecProvider);
  String? previousIdentity;
  DateTime? previousAt;

  await for (final uri in source.links) {
    final link = codec.tryDecode(uri);
    if (link == null) {
      continue;
    }
    final now = DateTime.now();
    final identity = link.videoId;
    if (identity == previousIdentity &&
        previousAt != null &&
        now.difference(previousAt) <= const Duration(seconds: 2)) {
      continue;
    }
    previousIdentity = identity;
    previousAt = now;
    yield link;
  }
});

/// Public YouTube/YouTube Music links received from Android intents.
///
/// This is deliberately separate from [incomingTrackLinkProvider] so older
/// `bstreammusic://` links keep their exact compatibility contract while
/// regular YouTube links can also be offered to BStream by the operating
/// system.
final incomingYouTubeMusicLinkProvider = StreamProvider<YouTubeMusicLink>((
  ref,
) async* {
  final source = ref.watch(incomingTrackLinkServiceProvider);
  const codec = YouTubeMusicLinkCodec();
  String? previousIdentity;
  DateTime? previousAt;

  await for (final uri in source.links) {
    final link = codec.tryDecode(uri);
    if (link == null) continue;
    final identity = [
      link.kind.name,
      link.videoId ?? '',
      link.collectionId ?? '',
    ].join(':');
    final now = DateTime.now();
    if (identity == previousIdentity &&
        previousAt != null &&
        now.difference(previousAt) <= const Duration(seconds: 2)) {
      continue;
    }
    previousIdentity = identity;
    previousAt = now;
    yield link;
  }
});

final lyricsServiceProvider = Provider<LyricsService>((ref) {
  final service = LrclibLyricsService(
    userAgent:
        '${AppConstants.appName}/${AppConstants.appVersion} '
        '(https://github.com/BryamContreras/BStream-Music)',
    // This short cache exists only in RAM. It avoids querying LRCLIB again when
    // returning to the lyrics screen, keeps only a small recent working set,
    // and is discarded when the app closes.
    cacheTtl: const Duration(minutes: 15),
    maxCacheEntries: 24,
  );
  ref.onDispose(service.dispose);
  return service;
});

final lyricsRomanizationServiceProvider = Provider<LyricsRomanizationService>((
  ref,
) {
  final service = LyricsRomanizationService();
  ref.onDispose(service.dispose);
  return service;
});

final currentLyricsLookupProvider = playerControllerProvider.select((player) {
  final snapshot = player.value;
  final metadata = (
    title: snapshot?.title,
    artist: snapshot?.artist,
    album: snapshot?.album,
    duration: snapshot?.duration,
    // A track id is stable when a remote stream URL is refreshed.
    sourceId: snapshot?.trackId ?? snapshot?.sourceUrl,
  );
  final title = metadata.title?.trim();
  if (title == null || title.isEmpty) {
    return null;
  }
  return LyricsLookup(
    title: title,
    artist: metadata.artist?.trim() ?? '',
    album: metadata.album?.trim(),
    duration: metadata.duration,
    sourceId: metadata.sourceId,
  );
});

final currentPlaybackPositionProvider = playerControllerProvider.select(
  (player) => player.value?.position ?? Duration.zero,
);

final lyricsProvider = FutureProvider.autoDispose
    .family<LyricsDocument?, LyricsLookup>((ref, lookup) {
      return ref.watch(lyricsServiceProvider).findLyrics(lookup);
    });

final similarLyricsProvider = FutureProvider.autoDispose
    .family<List<LyricsCandidate>, LyricsLookup>((ref, lookup) {
      return ref.watch(lyricsServiceProvider).findSimilarLyrics(lookup);
    });

typedef ManualLyricsSearch = ({String title, LyricsLookup context});

final manualLyricsSearchProvider = FutureProvider.autoDispose
    .family<List<LyricsCandidate>, ManualLyricsSearch>((ref, request) {
      return ref
          .watch(lyricsServiceProvider)
          .searchLyricsByTitle(request.title, context: request.context);
    });

final _currentLyricsSelectionIdentityProvider = playerControllerProvider.select(
  (player) {
    final snapshot = player.value;
    final title = snapshot?.title?.trim();
    if (title == null || title.isEmpty) {
      return null;
    }
    final sourceId = (snapshot?.trackId ?? snapshot?.sourceUrl)?.trim();
    final artist = snapshot?.artist?.trim() ?? '';
    if (sourceId != null && sourceId.isNotEmpty) {
      return 'source:$sourceId';
    }
    return '${title.toLowerCase()}\u0000${artist.toLowerCase()}';
  },
);

/// Keeps an explicitly chosen LRCLIB result only for the current song and
/// only in memory. It survives closing/reopening the lyrics route, while a
/// track change immediately discards it.
final selectedLyricsControllerProvider =
    NotifierProvider<SelectedLyricsController, LyricsDocument?>(
      SelectedLyricsController.new,
    );

class SelectedLyricsController extends Notifier<LyricsDocument?> {
  String? _lastIdentity;

  @override
  LyricsDocument? build() {
    // Keep the identity provider alive even while the lyrics route is closed.
    // Rebuilding this notifier through ref.watch can otherwise invalidate it
    // lazily while LyricsPage itself is building, which Riverpod correctly
    // rejects as a build-phase state change.
    _lastIdentity = ref.read(_currentLyricsSelectionIdentityProvider);
    ref.listen<String?>(_currentLyricsSelectionIdentityProvider, (_, next) {
      // Loading/error snapshots may temporarily have no value while the same
      // remote song is being refreshed. They must not discard the listener's
      // manual choice; only another concrete track identity resets it.
      if (next == null) {
        return;
      }
      final previous = _lastIdentity;
      _lastIdentity = next;
      if (previous != next && state != null) {
        state = null;
      }
    });
    return null;
  }

  void select(LyricsDocument document) => state = document;

  void clear() => state = null;
}

typedef DesktopMediaSessionFactory = DesktopMediaSession? Function();

final desktopMediaSessionFactoryProvider = Provider<DesktopMediaSessionFactory>(
  (ref) =>
      () => AppPlatform.isDesktop || AppPlatform.isMobile
      ? createDesktopMediaSession()
      : null,
);

final desktopMediaSessionRetryBackoffProvider = Provider<List<Duration>>(
  (ref) => const <Duration>[Duration(milliseconds: 500), Duration(seconds: 2)],
);

final desktopMediaSessionProvider = Provider<DesktopMediaSession?>((ref) {
  final session = ref.watch(desktopMediaSessionFactoryProvider)();
  if (session == null) {
    return null;
  }

  PlayerSnapshot? latestSnapshot;
  var latestQueue = const PlaybackQueueState();

  Duration relativeSeekPosition(Duration offset) {
    final snapshot = latestSnapshot;
    if (snapshot == null) {
      return Duration.zero;
    }
    final duration = snapshot.duration;
    final maximum = duration == null || duration <= Duration.zero
        ? snapshot.position + offset.abs()
        : duration;
    final milliseconds = (snapshot.position + offset).inMilliseconds.clamp(
      0,
      maximum.inMilliseconds,
    );
    return Duration(milliseconds: milliseconds.toInt());
  }

  final callbacks = DesktopMediaSessionCallbacks(
    play: () => ref.read(playerControllerProvider.notifier).resume(),
    pause: () => ref.read(playerControllerProvider.notifier).pause(),
    togglePlayPause: () =>
        ref.read(playerControllerProvider.notifier).togglePlayPause(),
    next: () => ref.read(playerControllerProvider.notifier).playNext(),
    previous: () => ref.read(playerControllerProvider.notifier).playPrevious(),
    stop: () => ref.read(playerControllerProvider.notifier).stop(),
    seek: (position) =>
        ref.read(playerControllerProvider.notifier).seek(position),
    seekBy: (offset) => ref
        .read(playerControllerProvider.notifier)
        .seek(relativeSeekPosition(offset)),
    setShuffleEnabled: (enabled) async {
      ref.read(playerControllerProvider.notifier).setShuffleEnabled(enabled);
    },
    setRepeatMode: (mode) async {
      ref.read(playerControllerProvider.notifier).setRepeatMode(mode);
    },
    playQueueIndex: (index) =>
        ref.read(playerControllerProvider.notifier).playQueueIndex(index),
  );
  final binding = DesktopMediaSessionBinding(
    session,
    callbacks,
    retryBackoff: ref.watch(desktopMediaSessionRetryBackoffProvider),
  );

  void publishState() {
    final snapshot = latestSnapshot;
    if (snapshot == null) {
      return;
    }
    final queue = latestQueue;
    unawaited(
      binding.update(
        DesktopMediaSessionState(
          snapshot: snapshot,
          queue: queue.entries
              .map(
                (entry) => DesktopMediaQueueItem(
                  id: entry.id,
                  title: entry.title,
                  artist: entry.artist,
                  album: entry.album,
                  thumbnailUrl: entry.thumbnailUrl,
                ),
              )
              .toList(growable: false),
          currentIndex: queue.currentIndex,
        ),
      ),
    );
  }

  ref.listen<AsyncValue<PlayerSnapshot>>(playerControllerProvider, (_, next) {
    final snapshot = next.value;
    if (snapshot != null) {
      latestSnapshot = snapshot;
      publishState();
    }
  }, fireImmediately: true);
  ref.listen<PlaybackQueueState>(playbackQueueProvider, (_, next) {
    latestQueue = next;
    publishState();
  }, fireImmediately: true);

  binding.start();
  ref.onDispose(() {
    unawaited(() async {
      try {
        await binding.dispose();
      } catch (error, stackTrace) {
        debugPrint(
          'Desktop media session disposal failed: $error\n$stackTrace',
        );
      }
    }());
  });
  return session;
});

final databaseServiceFactoryProvider =
    Provider<LocalDatabaseService Function()>((ref) {
      return LocalDatabaseService.new;
    });

final localDatabaseShutdownCoordinatorProvider =
    Provider<LocalDatabaseShutdownCoordinator>((ref) {
      return LocalDatabaseShutdownCoordinator();
    });

final databaseServiceProvider = Provider<LocalDatabaseService>((ref) {
  final shutdownCoordinator = ref.watch(
    localDatabaseShutdownCoordinatorProvider,
  );
  final service = ref.watch(databaseServiceFactoryProvider)();
  ref.onDispose(() {
    unawaited(() async {
      try {
        await shutdownCoordinator.disposeDatabase(service);
      } catch (error, stackTrace) {
        debugPrint('Database disposal failed: $error\n$stackTrace');
      }
    }());
  });
  return service;
});

final catalogPlaylistsProvider = FutureProvider<List<CatalogPlaylist>>((
  ref,
) async {
  final database = ref.watch(databaseServiceProvider);
  final playlists = await database.getCatalogPlaylists();
  final resolved = await Future.wait(
    playlists.map((playlist) => database.getCatalogPlaylist(playlist.id)),
  );
  return List<CatalogPlaylist>.unmodifiable(
    resolved.whereType<CatalogPlaylist>(),
  );
});

final catalogPlaylistProvider = FutureProvider.family<CatalogPlaylist?, String>(
  (ref, playlistId) {
    return ref.watch(databaseServiceProvider).getCatalogPlaylist(playlistId);
  },
);

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    ref.watch(databaseServiceProvider),
    ref.watch(libraryOperationCoordinatorProvider),
  );
});

final libraryOperationCoordinatorProvider =
    Provider<LibraryOperationCoordinator>((ref) {
      final coordinator = LibraryOperationCoordinator();
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

final youtubeMusicSearchProvider = Provider<YouTubeMusicSearch>((ref) {
  final service = InnerTubeSearchService(
    visitorDataStore: const SharedPreferencesInnerTubeVisitorDataStore(),
    region: _innerTubeDeviceRegion(),
  );
  ref.onDispose(service.dispose);
  return service;
});

sealed class HomeRecommendationItem {
  const HomeRecommendationItem();
}

final class HomeRecommendationTrackItem extends HomeRecommendationItem {
  const HomeRecommendationTrackItem(this.track, {this.localTrackId});

  final TrackInfo track;

  /// Local-library identity for downloaded/imported recommendations.
  ///
  /// The presentation layer can prefer the existing file while retaining the
  /// YouTube identity in [track] for ranking and remote fallbacks.
  final String? localTrackId;
}

enum HomeRecommendationCollectionKind { mix, playlist, album }

class HomeRecommendationCollection {
  const HomeRecommendationCollection({
    required this.title,
    required this.browseId,
    required this.kind,
    this.subtitle,
    this.thumbnailUrl,
    this.playlistId,
  });

  final String title;
  final String? subtitle;
  final String? thumbnailUrl;
  final String browseId;
  final String? playlistId;
  final HomeRecommendationCollectionKind kind;

  bool get isMix => kind == HomeRecommendationCollectionKind.mix;
  bool get isAlbum => kind == HomeRecommendationCollectionKind.album;
}

final class HomeRecommendationCollectionItem extends HomeRecommendationItem {
  const HomeRecommendationCollectionItem(this.collection);

  final HomeRecommendationCollection collection;
}

class HomeRecommendationArtist {
  const HomeRecommendationArtist({
    required this.name,
    required this.browseId,
    this.thumbnailUrl,
    this.seedVideoId,
  });

  final String name;
  final String browseId;
  final String? thumbnailUrl;

  /// A real Home song associated with this artist, when available.
  ///
  /// Artist pages can use it as a playback/radio fallback without deriving a
  /// YouTube identity from display text.
  final String? seedVideoId;
}

final class HomeRecommendationArtistItem extends HomeRecommendationItem {
  const HomeRecommendationArtistItem(this.artist);

  final HomeRecommendationArtist artist;
}

/// Maximum time Home may spend enriching already-valid artist candidates.
///
/// Kept injectable so timeout behavior stays deterministic in provider tests.
final homeArtistEnrichmentBudgetProvider = Provider<Duration>(
  (_) => const Duration(seconds: 4),
);

class HomeRecommendationSection {
  HomeRecommendationSection({
    required String title,
    required List<TrackInfo> tracks,
    String? queueSourceId,
    PersonalizedSectionKind? personalizedKind,
  }) : this.items(
         title: title,
         queueSourceId: queueSourceId,
         personalizedKind: personalizedKind,
         items: tracks
             .map<HomeRecommendationItem>(HomeRecommendationTrackItem.new)
             .toList(growable: false),
       );

  HomeRecommendationSection.items({
    required this.title,
    required List<HomeRecommendationItem> items,
    this.queueSourceId,
    this.personalizedKind,
  }) : items = List.unmodifiable(items);

  final String title;
  final List<HomeRecommendationItem> items;
  final String? queueSourceId;
  final PersonalizedSectionKind? personalizedKind;

  bool get isContinueListening =>
      personalizedKind == PersonalizedSectionKind.continueListening;

  List<TrackInfo> get tracks => List.unmodifiable(
    items.whereType<HomeRecommendationTrackItem>().map((item) => item.track),
  );
}

/// Authenticated Home adapter when a validated YouTube Music session exists.
///
/// The adapter retains the catalog-facing [YouTubeMusicHome] contract while
/// the account gateway owns cookies, authorization headers, and client context.
final youtubeMusicAuthenticatedHomeProvider = Provider<YouTubeMusicHome?>((
  ref,
) {
  final gateway = ref.watch(youtubeMusicAuthenticatedAccountGatewayProvider);
  return gateway == null
      ? null
      : ytm_account.AuthenticatedYouTubeMusicHome(account: gateway);
});

/// The preferred `FEmusic_home` feed. A validated account is tried first and
/// expected authenticated read/format failures fall back once to the existing
/// anonymous service. Personalized sections are built and cached separately,
/// then combined by [homeRecommendationsProvider].
final youtubeMusicHomeRecommendationsProvider =
    FutureProvider<List<HomeRecommendationSection>>(
      (ref) async {
        final search = ref.watch(youtubeMusicSearchProvider);
        final anonymousHome = search is YouTubeMusicHome
            ? search as YouTubeMusicHome
            : null;
        final authenticatedHome = ref.watch(
          youtubeMusicAuthenticatedHomeProvider,
        );
        if (anonymousHome == null && authenticatedHome == null) {
          return const <HomeRecommendationSection>[];
        }
        final strings = ref.watch(appStringsProvider);
        final artistEnrichmentBudget = ref.watch(
          homeArtistEnrichmentBudgetProvider,
        );
        late final List<InnerTubeHomeSection> sections;
        var usedAuthenticatedHome = false;
        if (authenticatedHome == null) {
          sections = await anonymousHome!.getHome(
            maxSections: InnerTubeSearchService.maxHomeSections,
            maxItemsPerSection: 12,
          );
        } else {
          try {
            sections = await authenticatedHome.getHome(
              maxSections: InnerTubeSearchService.maxHomeSections,
              maxItemsPerSection: 12,
            );
            usedAuthenticatedHome = true;
          } catch (error) {
            if (anonymousHome == null ||
                !_isExpectedAuthenticatedHomeFailure(error)) {
              rethrow;
            }
            sections = await anonymousHome.getHome(
              maxSections: InnerTubeSearchService.maxHomeSections,
              maxItemsPerSection: 12,
            );
          }
        }
        final queueSourcePrefix = usedAuthenticatedHome
            ? 'youtube-account-home'
            : 'youtube-home';
        final recommendations = sections
            .map((section) {
              final items = section.items
                  .map(_homeRecommendationItemFromInnerTube)
                  .whereType<HomeRecommendationItem>()
                  .toList(growable: false);
              if (items.isEmpty ||
                  _isSpecificYourMixesSection(
                    title: section.title,
                    items: items,
                    strings: strings,
                  )) {
                return null;
              }
              return HomeRecommendationSection.items(
                title: section.title,
                queueSourceId: '$queueSourcePrefix:${section.title}',
                items: items,
              );
            })
            .whereType<HomeRecommendationSection>()
            .toList(growable: true);
        final artistItems = <HomeRecommendationItem>[];
        final seenArtistIds = <String>{};
        String? artistQueueSourceId;
        final regularSections = <HomeRecommendationSection>[];
        for (final section in recommendations) {
          if (_isHomeArtistOnlySection(section) &&
              artistQueueSourceId == null) {
            artistQueueSourceId = section.queueSourceId;
          }
          for (final item
              in section.items.whereType<HomeRecommendationArtistItem>()) {
            final browseId = item.artist.browseId.trim();
            final name = item.artist.name.trim();
            if (_isValidArtistBrowseId(browseId) &&
                name.isNotEmpty &&
                seenArtistIds.add(browseId)) {
              artistItems.add(item);
            }
          }
          final regularItems = section.items
              .where((item) => item is! HomeRecommendationArtistItem)
              .toList(growable: false);
          if (regularItems.isNotEmpty) {
            regularSections.add(
              HomeRecommendationSection.items(
                title: section.title,
                queueSourceId: section.queueSourceId,
                items: regularItems,
              ),
            );
          }
        }

        HomeRecommendationSection? artistSection;
        if (artistItems.isNotEmpty) {
          artistSection = HomeRecommendationSection.items(
            title: usedAuthenticatedHome
                ? strings.recommendedArtists
                : strings.popularArtists,
            queueSourceId:
                artistQueueSourceId ?? '$queueSourcePrefix:embedded-artists',
            items: artistItems.take(12).toList(growable: false),
          );
        } else {
          final popularArtists = await _popularArtistsHomeSection(
            search,
            sections,
            strings,
            fallbackCollections: regularSections
                .expand((section) => section.items)
                .whereType<HomeRecommendationCollectionItem>()
                .map((item) => item.collection)
                .toList(growable: false),
            enrichmentBudget: artistEnrichmentBudget,
            authenticated: usedAuthenticatedHome,
          );
          artistSection = popularArtists;
        }
        return List.unmodifiable(<HomeRecommendationSection>[
          ?artistSection,
          ...regularSections,
        ]);
      },
      // Home deliberately renders errors as local-only. Avoid Riverpod's
      // automatic retries so a manual refresh remains predictable.
      retry: (_, _) => null,
    );

bool _isExpectedAuthenticatedHomeFailure(Object error) {
  return error is ytm_account.YouTubeMusicAccountException ||
      error is InnerTubeException ||
      error is FormatException ||
      error is TimeoutException;
}

Future<HomeRecommendationSection?> _popularArtistsHomeSection(
  YouTubeMusicSearch search,
  List<InnerTubeHomeSection> homeSections,
  AppStrings strings, {
  required List<HomeRecommendationCollection> fallbackCollections,
  required Duration enrichmentBudget,
  required bool authenticated,
}) async {
  final enrichmentClock = Stopwatch()..start();
  Duration remainingBudget() {
    final remaining = enrichmentBudget - enrichmentClock.elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  final seedVideoIds = <String>[];
  final candidates = <_HomeArtistCandidate>[];
  final seenCandidateBrowseIds = <String>{};
  void collectSongCandidates(InnerTubeSong song) {
    final videoId = song.videoId.trim();
    if (videoId.isNotEmpty && !seedVideoIds.contains(videoId)) {
      seedVideoIds.add(videoId);
    }
    final artistCount = math.min(
      song.artists.length,
      song.artistBrowseIds.length,
    );
    for (var index = 0; index < artistCount; index += 1) {
      final name = song.artists[index].trim();
      final browseId = song.artistBrowseIds[index]?.trim() ?? '';
      if (name.isEmpty ||
          !_isValidArtistBrowseId(browseId) ||
          !seenCandidateBrowseIds.add(browseId)) {
        continue;
      }
      candidates.add(
        _HomeArtistCandidate(
          name: name,
          browseId: browseId,
          seedVideoId: videoId,
        ),
      );
    }
  }

  for (final section in homeSections) {
    for (final item in section.items) {
      if (item is InnerTubeHomeSongItem) {
        collectSongCandidates(item.song);
      }
    }
  }

  // Anonymous Home is the cold-start source of truth. Preserve its server
  // order so this shelf stays stable between rebuilds, and only inspect a few
  // of its own collections when the song rows do not provide enough artists.
  // This deliberately avoids deriving "similar" artists from one arbitrary
  // Home song through `/next`.
  if (candidates.length < 6 && search is YouTubeMusicCollectionLookup) {
    final validCollections = fallbackCollections
        .where((collection) => _isValidCollectionBrowseId(collection.browseId))
        .toList(growable: false);
    final regularCollections = validCollections
        .where((candidate) => !candidate.isMix)
        .toList(growable: false);
    final mixCollections = validCollections
        .where((candidate) => candidate.isMix)
        .toList(growable: false);
    final preferredCollections = <HomeRecommendationCollection>[
      ...regularCollections,
      ...mixCollections,
    ].take(3).toList(growable: false);
    final availableCollectionBudget = remainingBudget();
    final collectionBudget = Duration(
      microseconds: math.min(
        availableCollectionBudget.inMicroseconds,
        const Duration(seconds: 2).inMicroseconds,
      ),
    );
    if (preferredCollections.isNotEmpty && collectionBudget > Duration.zero) {
      final lookup = search as YouTubeMusicCollectionLookup;
      // Some Home variants expose several narrowly focused collections (one
      // or two artists each). Resolve at most three in parallel so the shelf
      // has useful variety without extending the existing total budget.
      final songBatches = await Future.wait(
        preferredCollections.map((collection) async {
          try {
            return await lookup
                .getCollectionSongs(collection.browseId, limit: 8)
                .timeout(collectionBudget);
          } on Object {
            return const <InnerTubeSong>[];
          }
        }),
      );
      for (final songs in songBatches) {
        for (final song in songs) {
          collectSongCandidates(song);
        }
      }
    }
  }
  if (seedVideoIds.isEmpty && candidates.isEmpty) {
    return null;
  }

  final items = <HomeRecommendationItem>[];
  final seenBrowseIds = <String>{};
  // Six enriched results already fill the visible mobile shelf comfortably.
  // Avoid delaying Home merely to append portraits that begin off-screen.
  final missingCandidates = items.length >= 6
      ? const <_HomeArtistCandidate>[]
      : candidates
            .where((candidate) => !seenBrowseIds.contains(candidate.browseId))
            .take(math.max(0, 8 - items.length))
            .toList(growable: false);
  final hydratedCandidates = await _hydrateHomeArtistCandidates(
    search,
    missingCandidates,
    hydrateProfiles: remainingBudget() > Duration.zero,
    requestBudget: remainingBudget(),
  );
  for (final artist in hydratedCandidates) {
    if (!seenBrowseIds.add(artist.browseId)) {
      continue;
    }
    items.add(HomeRecommendationArtistItem(artist));
  }

  if (items.isEmpty) {
    return null;
  }
  final queueSeed = seedVideoIds.firstOrNull;
  return HomeRecommendationSection.items(
    title: authenticated ? strings.recommendedArtists : strings.popularArtists,
    queueSourceId: queueSeed == null
        ? '${authenticated ? 'youtube-account-home' : 'youtube-home'}:popular-artists'
        : '${authenticated ? 'youtube-account-home' : 'youtube-home'}:popular-artists:$queueSeed',
    items: items.take(12).toList(growable: false),
  );
}

class _HomeArtistCandidate {
  const _HomeArtistCandidate({
    required this.name,
    required this.browseId,
    required this.seedVideoId,
  });

  final String name;
  final String browseId;
  final String seedVideoId;
}

Future<List<HomeRecommendationArtist>> _hydrateHomeArtistCandidates(
  YouTubeMusicSearch search,
  List<_HomeArtistCandidate> candidates, {
  required bool hydrateProfiles,
  required Duration requestBudget,
}) async {
  if (candidates.isEmpty) {
    return const [];
  }
  if (!hydrateProfiles ||
      requestBudget <= Duration.zero ||
      search is! YouTubeMusicArtistProfileLookup) {
    return candidates
        .map(
          (candidate) => HomeRecommendationArtist(
            name: candidate.name,
            browseId: candidate.browseId,
            seedVideoId: candidate.seedVideoId,
          ),
        )
        .toList(growable: false);
  }

  final lookup = search as YouTubeMusicArtistProfileLookup;
  // At most six portraits are requested in one bounded pass. The rest remain
  // valid circular cards with the local artist placeholder, so Home never
  // waits through a long sequence of profile timeouts.
  final profileCandidates = candidates.take(6).toList(growable: false);
  final results = await Future.wait(
    profileCandidates.map((candidate) async {
      try {
        final profile = await lookup
            .getArtistProfile(
              candidate.browseId,
              fallbackName: candidate.name,
              songLimit: 1,
              releaseLimit: 1,
            )
            .timeout(requestBudget);
        final profileName = profile.artist.name.trim();
        final profileBrowseId = profile.artist.browseId.trim();
        if (profileName.isNotEmpty &&
            profileBrowseId == candidate.browseId &&
            _isValidArtistBrowseId(profileBrowseId)) {
          return HomeRecommendationArtist(
            name: profileName,
            browseId: profileBrowseId,
            thumbnailUrl: profile.artist.thumbnailUrl,
            seedVideoId: candidate.seedVideoId,
          );
        }
      } on Object {
        // The Home endpoint already proved this artist identity.
      }
      return HomeRecommendationArtist(
        name: candidate.name,
        browseId: candidate.browseId,
        seedVideoId: candidate.seedVideoId,
      );
    }),
  );
  final hydrated = <HomeRecommendationArtist>[...results];
  for (final candidate in candidates.skip(profileCandidates.length)) {
    hydrated.add(
      HomeRecommendationArtist(
        name: candidate.name,
        browseId: candidate.browseId,
        seedVideoId: candidate.seedVideoId,
      ),
    );
  }
  return List.unmodifiable(hydrated);
}

bool _isValidArtistBrowseId(String browseId) =>
    RegExp(r'^(?:UC|MPLA)[A-Za-z0-9_-]{2,200}$').hasMatch(browseId.trim());

bool _isValidCollectionBrowseId(String browseId) =>
    RegExp(r'^VL[A-Za-z0-9_-]{1,200}$').hasMatch(browseId.trim());

abstract interface class PersonalizedHomeFeedSource {
  Future<CachedPersonalizedRecommendationFeed?> loadCachedFeed();

  Future<PersonalizedRecommendationFeed> refresh({bool forceNetwork = false});
}

abstract interface class HomeArtistRecommendationSource {
  /// Returns artists related to qualified local playback-history seeds and
  /// whether such history exists.
  ///
  /// Implementations must remain cache-only. The personalized feed refresh is
  /// responsible for filling related candidate pools, so Home never launches
  /// a duplicate InnerTube request solely for this shelf.
  Future<HomeArtistRecommendationResult> load({
    bool refresh = false,
    bool forceNetwork = false,
  });
}

class HomeArtistRecommendationResult {
  HomeArtistRecommendationResult({
    required List<HomeRecommendationArtist> artists,
    required this.hasQualifiedHistory,
  }) : artists = List<HomeRecommendationArtist>.unmodifiable(artists);

  final List<HomeRecommendationArtist> artists;

  /// Distinguishes a genuine cold start from a temporarily empty related
  /// cache. Anonymous Home artists must only be used for the former.
  final bool hasQualifiedHistory;
}

class RepositoryHomeArtistRecommendationSource
    implements HomeArtistRecommendationSource {
  RepositoryHomeArtistRecommendationSource({
    required this.repository,
    this.artistLookup,
    this.seedLimit = 6,
    this.artistSeedLimit = 3,
    this.resultLimit = 12,
    Duration? relatedTtl,
    DateTime Function()? clock,
  }) : relatedTtl =
           relatedTtl ?? const PersonalizedRecommendationConfig().relatedTtl,
       _clock = clock ?? DateTime.now;

  final RecommendationRepository repository;
  final YouTubeMusicArtistProfileLookup? artistLookup;
  final int seedLimit;
  final int artistSeedLimit;
  final int resultLimit;
  final Duration relatedTtl;
  final DateTime Function() _clock;

  @override
  Future<HomeArtistRecommendationResult> load({
    bool refresh = false,
    bool forceNetwork = false,
  }) async {
    // Leave [minListenedMs] at the repository default. Together with the
    // player's completion rule this admits only qualified listens (normally
    // 30 seconds), not every track the user merely skipped through.
    final histories = await Future.wait<List<RecommendationSeed>>([
      repository.getTopSeeds(limit: seedLimit * 2),
      repository.getRecentSeeds(limit: seedLimit * 2),
    ]);
    final topSeeds = histories[0];
    final recentSeeds = histories[1];
    final allSeeds = _uniqueHomeArtistSeeds(<RecommendationSeed>[
      ...recentSeeds,
      ...topSeeds,
    ]);
    if (allSeeds.isEmpty) {
      return HomeArtistRecommendationResult(
        artists: const <HomeRecommendationArtist>[],
        hasQualifiedHistory: false,
      );
    }

    final listenedBrowseIds = <String>{};
    final listenedNames = <String>{};
    for (final seed in allSeeds) {
      for (var index = 0; index < seed.artists.length; index += 1) {
        final name = _normalizedArtistName(seed.artists[index]);
        if (name.isNotEmpty) {
          listenedNames.add(name);
        }
        if (index < seed.artistBrowseIds.length) {
          final browseId = seed.artistBrowseIds[index]?.trim() ?? '';
          if (_isValidArtistBrowseId(browseId)) {
            listenedBrowseIds.add(browseId);
          }
        }
      }
    }

    final seeds = _balancedHomeArtistSeeds(
      topSeeds: topSeeds,
      recentSeeds: recentSeeds,
      limit: seedLimit,
    );
    final now = _clock().toUtc();
    final artistSeeds = seeds
        .map(_homeRelatedArtistSeed)
        .whereType<_HomeRelatedArtistSeed>()
        .take(artistSeedLimit)
        .toList(growable: false);
    final cachedStates = await Future.wait(
      artistSeeds.map(
        (seed) => _loadRelatedArtistCache(repository, seed, now: now),
      ),
    );

    if (refresh && artistLookup != null && artistSeeds.isNotEmpty) {
      final generation = repository.generation;
      await Future.wait(
        List<Future<void>>.generate(artistSeeds.length, (index) async {
          final cached = cachedStates[index];
          if (!forceNetwork && cached != null && !cached.isExpired) {
            return;
          }
          final seed = artistSeeds[index];
          try {
            final profile = await artistLookup!.getArtistProfile(
              seed.browseId,
              fallbackName: seed.name,
              songLimit: 1,
              releaseLimit: 1,
            );
            final artists = profile.relatedArtists
                .where(
                  (artist) =>
                      _isValidArtistBrowseId(artist.browseId) &&
                      artist.name.trim().isNotEmpty,
                )
                .map(
                  (artist) => HomeRecommendationArtist(
                    name: artist.name.trim(),
                    browseId: artist.browseId.trim(),
                    thumbnailUrl: artist.thumbnailUrl,
                    seedVideoId: seed.seed.videoId,
                  ),
                )
                .toList(growable: false);
            cachedStates[index] = _HomeRelatedArtistCacheState(
              artists: artists,
              isExpired: false,
            );
            await _saveRelatedArtistCache(
              repository,
              seed,
              artists,
              now: now,
              generation: generation,
              ttl: relatedTtl,
            );
          } on Object {
            // A stale profile shelf remains usable. Track-radio candidates
            // below are the final fallback when no artist shelf was cached.
          }
        }),
      );
    }

    final relatedArtistBuckets = <List<HomeRecommendationArtist>>[];
    for (final cached in cachedStates) {
      if (cached == null || cached.artists.isEmpty) {
        continue;
      }
      relatedArtistBuckets.add(
        _filterRecommendedArtists(
          cached.artists,
          listenedBrowseIds: listenedBrowseIds,
          listenedNames: listenedNames,
        ),
      );
    }
    final relatedArtists = _roundRobinHomeArtists(
      relatedArtistBuckets,
      limit: resultLimit,
    );
    if (relatedArtists.isNotEmpty) {
      return HomeArtistRecommendationResult(
        artists: relatedArtists,
        hasQualifiedHistory: true,
      );
    }

    final pools = await Future.wait(
      seeds.map(
        (seed) => repository.getRelatedCandidates(
          seed.trackKey,
          ttl: relatedTtl,
          now: now,
        ),
      ),
    );
    final radioArtistBuckets = <List<HomeRecommendationArtist>>[];
    for (var seedIndex = 0; seedIndex < seeds.length; seedIndex += 1) {
      final seenForSeed = <String>{};
      final artists = <HomeRecommendationArtist>[];
      for (
        var candidateIndex = 0;
        candidateIndex < pools[seedIndex].length;
        candidateIndex += 1
      ) {
        final candidate = pools[seedIndex][candidateIndex];
        final rank = candidate.rank >= 0 ? candidate.rank : candidateIndex;
        if (rank > 12 || candidate.artists.isEmpty) {
          continue;
        }
        // A radio track may credit several collaborators. Only its primary
        // artist is evidence for this shelf; treating every featured credit
        // as equally related caused unrelated names to leak into Home.
        const artistIndex = 0;
        final name = candidate.artists[artistIndex].trim();
        final normalizedName = _normalizedArtistName(name);
        final browseId = artistIndex < candidate.artistBrowseIds.length
            ? candidate.artistBrowseIds[artistIndex]?.trim() ?? ''
            : '';
        if (name.isEmpty ||
            normalizedName.isEmpty ||
            !_isValidArtistBrowseId(browseId) ||
            listenedBrowseIds.contains(browseId) ||
            listenedNames.contains(normalizedName) ||
            !seenForSeed.add(browseId)) {
          continue;
        }
        final videoId = candidate.videoId?.trim();
        artists.add(
          HomeRecommendationArtist(
            name: name,
            browseId: browseId,
            seedVideoId: videoId == null || videoId.isEmpty ? null : videoId,
          ),
        );
      }
      if (artists.isNotEmpty) {
        radioArtistBuckets.add(artists);
      }
    }
    return HomeArtistRecommendationResult(
      artists: _roundRobinHomeArtists(radioArtistBuckets, limit: resultLimit),
      hasQualifiedHistory: true,
    );
  }
}

const _relatedArtistCacheSchemaVersion = 1;
const _relatedArtistCacheKeyPrefix = 'related-artists-v1:';

class _HomeRelatedArtistSeed {
  const _HomeRelatedArtistSeed({
    required this.seed,
    required this.browseId,
    required this.name,
  });

  final RecommendationSeed seed;
  final String browseId;
  final String name;
}

class _HomeRelatedArtistCacheState {
  const _HomeRelatedArtistCacheState({
    required this.artists,
    required this.isExpired,
  });

  final List<HomeRecommendationArtist> artists;
  final bool isExpired;
}

_HomeRelatedArtistSeed? _homeRelatedArtistSeed(RecommendationSeed seed) {
  final count = math.min(seed.artists.length, seed.artistBrowseIds.length);
  for (var index = 0; index < count; index += 1) {
    final name = seed.artists[index].trim();
    final browseId = seed.artistBrowseIds[index]?.trim() ?? '';
    if (name.isNotEmpty && _isValidArtistBrowseId(browseId)) {
      return _HomeRelatedArtistSeed(seed: seed, browseId: browseId, name: name);
    }
  }
  return null;
}

Future<_HomeRelatedArtistCacheState?> _loadRelatedArtistCache(
  RecommendationRepository repository,
  _HomeRelatedArtistSeed seed, {
  required DateTime now,
}) async {
  try {
    final cache = await repository.loadFeed(
      '$_relatedArtistCacheKeyPrefix${seed.browseId}',
    );
    if (cache == null ||
        cache.payload['schemaVersion'] != _relatedArtistCacheSchemaVersion ||
        cache.payload['artists'] is! List) {
      return null;
    }
    final artists = <HomeRecommendationArtist>[];
    for (final value in cache.payload['artists']! as List) {
      if (value is! Map) continue;
      final name = value['name']?.toString().trim() ?? '';
      final browseId = value['browseId']?.toString().trim() ?? '';
      final thumbnailUrl = value['thumbnailUrl']?.toString().trim();
      if (name.isEmpty || !_isValidArtistBrowseId(browseId)) continue;
      artists.add(
        HomeRecommendationArtist(
          name: name,
          browseId: browseId,
          thumbnailUrl: thumbnailUrl == null || thumbnailUrl.isEmpty
              ? null
              : thumbnailUrl,
          seedVideoId: seed.seed.videoId,
        ),
      );
    }
    return _HomeRelatedArtistCacheState(
      artists: List.unmodifiable(artists),
      isExpired: cache.isExpiredAt(now),
    );
  } on Object {
    return null;
  }
}

Future<void> _saveRelatedArtistCache(
  RecommendationRepository repository,
  _HomeRelatedArtistSeed seed,
  List<HomeRecommendationArtist> artists, {
  required DateTime now,
  required int generation,
  required Duration ttl,
}) async {
  if (repository.generation != generation) return;
  try {
    await repository.saveFeed(
      RecommendationFeedCache(
        feedKey: '$_relatedArtistCacheKeyPrefix${seed.browseId}',
        generatedAt: now,
        expiresAt: now.add(ttl),
        payload: <String, Object?>{
          'schemaVersion': _relatedArtistCacheSchemaVersion,
          'seedArtistBrowseId': seed.browseId,
          'artists': artists
              .map(
                (artist) => <String, Object?>{
                  'name': artist.name,
                  'browseId': artist.browseId,
                  'thumbnailUrl': artist.thumbnailUrl,
                },
              )
              .toList(growable: false),
        },
      ),
      expectedGeneration: generation,
    );
  } on Object {
    // Recommendations remain usable in memory when optional cache writes fail.
  }
}

List<HomeRecommendationArtist> _filterRecommendedArtists(
  Iterable<HomeRecommendationArtist> artists, {
  required Set<String> listenedBrowseIds,
  required Set<String> listenedNames,
}) {
  final seen = <String>{};
  return artists
      .where((artist) {
        final browseId = artist.browseId.trim();
        final name = _normalizedArtistName(artist.name);
        return _isValidArtistBrowseId(browseId) &&
            name.isNotEmpty &&
            !listenedBrowseIds.contains(browseId) &&
            !listenedNames.contains(name) &&
            seen.add(browseId);
      })
      .toList(growable: false);
}

List<HomeRecommendationArtist> _roundRobinHomeArtists(
  List<List<HomeRecommendationArtist>> buckets, {
  required int limit,
}) {
  if (limit <= 0 || buckets.isEmpty) return const [];
  final result = <HomeRecommendationArtist>[];
  final positions = List<int>.filled(buckets.length, 0);
  final seen = <String>{};
  while (result.length < limit) {
    var added = false;
    for (
      var bucketIndex = 0;
      bucketIndex < buckets.length && result.length < limit;
      bucketIndex += 1
    ) {
      final bucket = buckets[bucketIndex];
      while (positions[bucketIndex] < bucket.length) {
        final artist = bucket[positions[bucketIndex]++];
        if (!seen.add(artist.browseId.trim())) continue;
        result.add(artist);
        added = true;
        break;
      }
    }
    if (!added) break;
  }
  return List.unmodifiable(result);
}

List<RecommendationSeed> _uniqueHomeArtistSeeds(
  Iterable<RecommendationSeed> seeds,
) {
  final seen = <String>{};
  return seeds
      .where((seed) => seed.trackKey.trim().isNotEmpty)
      .where((seed) => seen.add(seed.trackKey.trim()))
      .toList(growable: false);
}

List<RecommendationSeed> _balancedHomeArtistSeeds({
  required List<RecommendationSeed> topSeeds,
  required List<RecommendationSeed> recentSeeds,
  required int limit,
}) {
  final result = <RecommendationSeed>[];
  final seenTracks = <String>{};
  final seenArtists = <String>{};
  void add(RecommendationSeed seed) {
    if (result.length >= limit) {
      return;
    }
    final trackKey = seed.trackKey.trim();
    if (trackKey.isEmpty || !seenTracks.add(trackKey)) return;

    // Related queues are track-based, but this shelf recommends artists. A
    // listener who played several songs by the same artist must not give that
    // artist several independent radios and drown out the newest distinct
    // taste signal. Keep the newest qualified track for each primary artist.
    final artistIdentity = _homeArtistSeedIdentity(seed);
    if (!seenArtists.add(artistIdentity)) return;
    result.add(seed);
  }

  // Recent listening is the clearest signal. Fill it with distinct artists
  // first, then use historical top artists only for remaining capacity.
  for (final seed in recentSeeds) {
    add(seed);
  }
  for (final seed in topSeeds) {
    add(seed);
  }
  return List<RecommendationSeed>.unmodifiable(result);
}

String _homeArtistSeedIdentity(RecommendationSeed seed) {
  final length = math.max(seed.artists.length, seed.artistBrowseIds.length);
  for (var index = 0; index < length; index += 1) {
    final browseId = index < seed.artistBrowseIds.length
        ? seed.artistBrowseIds[index]?.trim() ?? ''
        : '';
    if (_isValidArtistBrowseId(browseId)) {
      return 'id:$browseId';
    }
    final name = index < seed.artists.length
        ? _normalizedArtistName(seed.artists[index])
        : '';
    if (name.isNotEmpty) {
      return 'name:$name';
    }
  }
  return 'track:${seed.trackKey.trim()}';
}

class EnginePersonalizedHomeFeedSource implements PersonalizedHomeFeedSource {
  const EnginePersonalizedHomeFeedSource(this.engine);

  final PersonalizedRecommendationEngine engine;

  @override
  Future<CachedPersonalizedRecommendationFeed?> loadCachedFeed() {
    return engine.loadCachedFeed();
  }

  @override
  Future<PersonalizedRecommendationFeed> refresh({bool forceNetwork = false}) {
    return engine.refresh(forceNetwork: forceNetwork);
  }
}

final personalizedHomeFeedSourceProvider =
    Provider<PersonalizedHomeFeedSource?>((ref) {
      final service = ref.watch(youtubeMusicSearchProvider);
      if (service is! YouTubeMusicRelated ||
          service is! YouTubeMusicArtistLookup) {
        return null;
      }
      final database = ref.watch(databaseServiceProvider);
      final coordinator = ref.watch(libraryOperationCoordinatorProvider);
      final engine = PersonalizedRecommendationEngine(
        repository: LocalDatabaseRecommendationRepository(
          database: database,
          coordinator: coordinator,
        ),
        catalog: InnerTubeRecommendationCatalog(
          related: service as YouTubeMusicRelated,
          artists: service as YouTubeMusicArtistLookup,
        ),
      );
      return EnginePersonalizedHomeFeedSource(engine);
    });

final homeArtistRecommendationSourceProvider =
    Provider<HomeArtistRecommendationSource?>((ref) {
      final database = ref.watch(databaseServiceProvider);
      final coordinator = ref.watch(libraryOperationCoordinatorProvider);
      final search = ref.watch(youtubeMusicSearchProvider);
      return RepositoryHomeArtistRecommendationSource(
        repository: LocalDatabaseRecommendationRepository(
          database: database,
          coordinator: coordinator,
        ),
        artistLookup: search is YouTubeMusicArtistProfileLookup
            ? search as YouTubeMusicArtistProfileLookup
            : null,
      );
    });

final homeRecommendationsProvider =
    AsyncNotifierProvider<
      HomeRecommendationsController,
      List<HomeRecommendationSection>
    >(HomeRecommendationsController.new, retry: (_, _) => null);

/// Cache-first controller for BStream's personalized feed plus the generic
/// YouTube Music home. Both inputs refresh independently and the last usable
/// combined value remains visible through loading and failures.
class HomeRecommendationsController
    extends AsyncNotifier<List<HomeRecommendationSection>> {
  PersonalizedHomeFeedSource? _personalizedSource;
  HomeArtistRecommendationSource? _artistSource;
  List<HomeRecommendationSection> _personalized = const [];
  List<HomeRecommendationSection> _youtubeMusic = const [];
  HomeRecommendationSection? _historyArtistSection;
  bool _hasQualifiedArtistHistory = false;
  Future<void>? _refreshInFlight;
  bool _inFlightForcesNetwork = false;
  bool _inFlightRefreshesYouTube = false;
  int _buildEpoch = 0;

  @override
  Future<List<HomeRecommendationSection>> build() async {
    // This controller intentionally reads (rather than watches) the generic
    // Home FutureProvider so it can retain its last usable combined value.
    // Observe the account identity explicitly so login, logout, restoration,
    // and channel-generation changes still rebuild and reject older results.
    ref.watch(
      youtubeMusicAuthControllerProvider.select(
        (auth) => (auth.phase, auth.generation, auth.profile?.channelId),
      ),
    );
    final epoch = ++_buildEpoch;
    // A dependency rebuild supersedes any older refresh. Old results are
    // rejected by [epoch], while this build remains free to start a new one.
    _refreshInFlight = null;
    _inFlightForcesNetwork = false;
    _inFlightRefreshesYouTube = false;
    final strings = ref.watch(appStringsProvider);
    _personalizedSource = ref.watch(personalizedHomeFeedSourceProvider);
    _artistSource = ref.watch(homeArtistRecommendationSourceProvider);
    _historyArtistSection = null;
    _hasQualifiedArtistHistory = false;

    final youtubeState = ref.read(youtubeMusicHomeRecommendationsProvider);
    _youtubeMusic = youtubeState.value ?? const [];

    final source = _personalizedSource;
    CachedPersonalizedRecommendationFeed? cached;
    if (source != null) {
      try {
        cached = await source.loadCachedFeed();
      } on Object {
        // A corrupt/unavailable cache is equivalent to a cold start. The
        // background refresh still gets a chance to rebuild it.
      }
    }
    if (!ref.mounted || epoch != _buildEpoch) {
      return const <HomeRecommendationSection>[];
    }
    _personalized = cached == null
        ? const []
        : _homeSectionsFromPersonalizedFeed(cached.feed, strings);
    final artistSource = _artistSource;
    if (artistSource != null) {
      try {
        final result = await artistSource.load();
        _historyArtistSection = _homeArtistSectionFromHistory(
          result.artists,
          strings,
        );
        _hasQualifiedArtistHistory = result.hasQualifiedHistory;
      } on Object {
        // Artist recommendations are optional; generic Home remains usable.
      }
    }
    if (!ref.mounted || epoch != _buildEpoch) {
      return const <HomeRecommendationSection>[];
    }
    final initial = _combineHomeRecommendationSections(
      _personalized,
      _youtubeMusic,
      historyArtistSection: _historyArtistSection,
      hasQualifiedArtistHistory: _hasQualifiedArtistHistory,
    );

    // Every provider reconstruction represents either app startup or a newly
    // qualified playback event. Publish cache first, then recalculate exactly
    // once; feed TTL must never pin an old Home after a new listen.
    Timer.run(() {
      if (!ref.mounted || epoch != _buildEpoch) {
        return;
      }
      unawaited(
        _refresh(
          forceNetwork: false,
          refreshYouTube: false,
          expectedEpoch: epoch,
        ),
      );
    });
    return initial;
  }

  Future<void> refresh() {
    return _refresh(
      forceNetwork: true,
      refreshYouTube: true,
      expectedEpoch: _buildEpoch,
    );
  }

  Future<void> _refresh({
    required bool forceNetwork,
    required bool refreshYouTube,
    required int expectedEpoch,
  }) {
    final current = _refreshInFlight;
    if (current != null) {
      final requestAlreadyCovered =
          (!forceNetwork || _inFlightForcesNetwork) &&
          (!refreshYouTube || _inFlightRefreshesYouTube);
      if (requestAlreadyCovered) {
        return current;
      }

      // Startup deliberately uses cached related data and keeps the generic
      // YouTube Home provider alive. If the user refreshes while that work is
      // still running, serialize one stronger pass behind it instead of
      // silently weakening the explicit request.
      final chainedForceNetwork = _inFlightForcesNetwork || forceNetwork;
      final chainedRefreshYouTube = _inFlightRefreshesYouTube || refreshYouTube;
      final chained = current.whenComplete(
        () => _performRefresh(
          forceNetwork: chainedForceNetwork,
          refreshYouTube: chainedRefreshYouTube,
          expectedEpoch: expectedEpoch,
        ),
      );
      return _trackRefresh(
        chained,
        forceNetwork: chainedForceNetwork,
        refreshYouTube: chainedRefreshYouTube,
      );
    }
    final operation = _performRefresh(
      forceNetwork: forceNetwork,
      refreshYouTube: refreshYouTube,
      expectedEpoch: expectedEpoch,
    );
    return _trackRefresh(
      operation,
      forceNetwork: forceNetwork,
      refreshYouTube: refreshYouTube,
    );
  }

  Future<void> _trackRefresh(
    Future<void> operation, {
    required bool forceNetwork,
    required bool refreshYouTube,
  }) {
    _refreshInFlight = operation;
    _inFlightForcesNetwork = forceNetwork;
    _inFlightRefreshesYouTube = refreshYouTube;
    return operation.whenComplete(() {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
        _inFlightForcesNetwork = false;
        _inFlightRefreshesYouTube = false;
      }
    });
  }

  Future<void> _performRefresh({
    required bool forceNetwork,
    required bool refreshYouTube,
    required int expectedEpoch,
  }) async {
    if (!ref.mounted || expectedEpoch != _buildEpoch) {
      return;
    }
    final strings = ref.read(appStringsProvider);
    final previous =
        state.asData?.value ??
        _combineHomeRecommendationSections(
          _personalized,
          _youtubeMusic,
          historyArtistSection: _historyArtistSection,
          hasQualifiedArtistHistory: _hasQualifiedArtistHistory,
        );
    const loadingState = AsyncLoading<List<HomeRecommendationSection>>();
    // ignore: invalid_use_of_internal_member
    state = loadingState.copyWithPrevious(AsyncData(previous));

    Object? firstError;
    StackTrace? firstStackTrace;
    void rememberError(Object error, StackTrace stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    final tasks = <Future<void>>[];
    final source = _personalizedSource;
    List<HomeRecommendationSection>? refreshedPersonalized;
    List<HomeRecommendationSection>? refreshedYouTubeMusic;
    if (source != null) {
      tasks.add(() async {
        try {
          final feed = await source.refresh(forceNetwork: forceNetwork);
          refreshedPersonalized = _homeSectionsFromPersonalizedFeed(
            feed,
            strings,
          );
        } catch (error, stackTrace) {
          rememberError(error, stackTrace);
        }
      }());
    }
    if (refreshYouTube) {
      ref.invalidate(youtubeMusicHomeRecommendationsProvider);
    }
    final youtubeMusicFuture = ref.read(
      youtubeMusicHomeRecommendationsProvider.future,
    );
    tasks.add(() async {
      try {
        refreshedYouTubeMusic = await youtubeMusicFuture;
      } catch (error, stackTrace) {
        rememberError(error, stackTrace);
      }
    }());
    await Future.wait(tasks);
    if (!ref.mounted || expectedEpoch != _buildEpoch) {
      return;
    }

    HomeRecommendationSection? refreshedHistoryArtistSection;
    var refreshedHasQualifiedArtistHistory = false;
    var historyArtistRefreshSucceeded = false;
    final artistSource = _artistSource;
    if (artistSource != null) {
      try {
        final result = await artistSource.load(
          refresh: true,
          forceNetwork: forceNetwork,
        );
        refreshedHistoryArtistSection = _homeArtistSectionFromHistory(
          result.artists,
          strings,
        );
        refreshedHasQualifiedArtistHistory = result.hasQualifiedHistory;
        historyArtistRefreshSucceeded = true;
      } on Object {
        // Retain the last valid shelf if the local recommendation store is
        // temporarily unavailable.
      }
    }
    if (!ref.mounted || expectedEpoch != _buildEpoch) {
      return;
    }

    _personalized = refreshedPersonalized ?? _personalized;
    _youtubeMusic = refreshedYouTubeMusic ?? _youtubeMusic;
    if (historyArtistRefreshSucceeded) {
      _historyArtistSection = refreshedHistoryArtistSection;
      _hasQualifiedArtistHistory = refreshedHasQualifiedArtistHistory;
    }

    final combined = _combineHomeRecommendationSections(
      _personalized,
      _youtubeMusic,
      historyArtistSection: _historyArtistSection,
      hasQualifiedArtistHistory: _hasQualifiedArtistHistory,
    );
    final error = firstError;
    if (error == null) {
      state = AsyncData(combined);
      return;
    }
    final errorState = AsyncError<List<HomeRecommendationSection>>(
      error,
      firstStackTrace ?? StackTrace.current,
    );
    // ignore: invalid_use_of_internal_member
    state = errorState.copyWithPrevious(AsyncData(combined));
  }
}

List<HomeRecommendationSection> _homeSectionsFromPersonalizedFeed(
  PersonalizedRecommendationFeed feed,
  AppStrings strings,
) {
  return List<HomeRecommendationSection>.unmodifiable(
    feed.sections
        .where((section) => section.kind != PersonalizedSectionKind.mixes)
        .map((section) {
          final items = section.items
              .map(
                (item) =>
                    _homeRecommendationItemFromPersonalized(item, strings),
              )
              .whereType<HomeRecommendationItem>()
              .toList(growable: false);
          return HomeRecommendationSection.items(
            title: switch (section.kind) {
              PersonalizedSectionKind.continueListening =>
                strings.continueListening,
              PersonalizedSectionKind.becauseYouListened =>
                strings.becauseYouListened(section.seedTitle),
              PersonalizedSectionKind.mixes => strings.yourMixes,
              PersonalizedSectionKind.newForYou => strings.newForYou,
              PersonalizedSectionKind.discovery => strings.discovery,
            },
            queueSourceId: 'personalized-home:${section.kind.name}',
            personalizedKind: section.kind,
            items: items,
          );
        })
        .where((section) => section.items.isNotEmpty),
  );
}

HomeRecommendationItem? _homeRecommendationItemFromPersonalized(
  PersonalizedRecommendationItem item,
  AppStrings strings,
) {
  return switch (item) {
    PersonalizedTrackItem() => _homeTrackItemFromPersonalized(item, strings),
    PersonalizedCollectionItem() => HomeRecommendationCollectionItem(
      HomeRecommendationCollection(
        title: item.title,
        subtitle: item.subtitle,
        thumbnailUrl: item.thumbnailUrl,
        browseId: item.browseId,
        playlistId: item.playlistId,
        kind: switch (item.kind) {
          PersonalizedCollectionKind.mix =>
            HomeRecommendationCollectionKind.mix,
          PersonalizedCollectionKind.release =>
            HomeRecommendationCollectionKind.album,
        },
      ),
    ),
  };
}

HomeRecommendationTrackItem? _homeTrackItemFromPersonalized(
  PersonalizedTrackItem item,
  AppStrings strings,
) {
  final videoId = item.videoId?.trim();
  final trackId = item.trackId.trim();
  if (trackId.isEmpty || item.title.trim().isEmpty) {
    return null;
  }
  final hasVideoId = videoId != null && videoId.isNotEmpty;
  final artists = item.artists
      .map((artist) => artist.trim())
      .where((artist) => artist.isNotEmpty)
      .toList(growable: false);
  final durationMs = item.durationMs;
  final track = TrackInfo(
    id: hasVideoId ? videoId : trackId,
    title: item.title,
    artist: artists.isEmpty ? strings.unknownArtist : artists.join(', '),
    artists: artists,
    artistBrowseIds: item.artistBrowseIds,
    album: item.album,
    duration: durationMs == null || durationMs <= 0
        ? null
        : Duration(milliseconds: durationMs),
    thumbnailUrl: hasVideoId
        ? youtubeThumbnailSourceForVideoId(videoId) ?? item.thumbnailUrl
        : item.thumbnailUrl,
    catalogThumbnailUrl: item.thumbnailUrl,
    url: hasVideoId
        ? Uri.https('www.youtube.com', '/watch', <String, String>{
            'v': videoId,
          }).toString()
        : '',
    metadataSource: TrackMetadataSource.youtubeMusic,
  );
  final localTrackId = switch (item.source) {
    PlaybackEventSource.downloaded ||
    PlaybackEventSource.local ||
    PlaybackEventSource.external => trackId,
    PlaybackEventSource.streaming || PlaybackEventSource.unknown => null,
  };
  return HomeRecommendationTrackItem(track, localTrackId: localTrackId);
}

HomeRecommendationSection? _homeArtistSectionFromHistory(
  List<HomeRecommendationArtist> artists,
  AppStrings strings,
) {
  if (artists.isEmpty) {
    return null;
  }
  return HomeRecommendationSection.items(
    title: strings.recommendedArtists,
    queueSourceId: 'personalized-home:recommended-artists',
    items: artists
        .map<HomeRecommendationItem>(HomeRecommendationArtistItem.new)
        .toList(growable: false),
  );
}

String _normalizedArtistName(String value) => value.trim().toLowerCase();

HomeRecommendationSection _reusePopularArtistArtwork(
  HomeRecommendationSection recommendedArtists,
  List<HomeRecommendationSection> popularArtistSections,
) {
  final popularByBrowseId = <String, HomeRecommendationArtist>{};
  for (final section in popularArtistSections) {
    for (final item
        in section.items.whereType<HomeRecommendationArtistItem>()) {
      popularByBrowseId.putIfAbsent(item.artist.browseId, () => item.artist);
    }
  }
  return HomeRecommendationSection.items(
    title: recommendedArtists.title,
    queueSourceId: recommendedArtists.queueSourceId,
    items: recommendedArtists.items
        .map((item) {
          if (item is! HomeRecommendationArtistItem ||
              item.artist.thumbnailUrl?.trim().isNotEmpty == true) {
            return item;
          }
          final popular = popularByBrowseId[item.artist.browseId];
          final thumbnailUrl = popular?.thumbnailUrl?.trim();
          if (thumbnailUrl == null || thumbnailUrl.isEmpty) {
            return item;
          }
          return HomeRecommendationArtistItem(
            HomeRecommendationArtist(
              name: item.artist.name,
              browseId: item.artist.browseId,
              thumbnailUrl: thumbnailUrl,
              seedVideoId: item.artist.seedVideoId,
            ),
          );
        })
        .toList(growable: false),
  );
}

bool _isAuthenticatedHomeArtistSection(HomeRecommendationSection section) =>
    _isHomeArtistOnlySection(section) &&
    (section.queueSourceId?.startsWith('youtube-account-home:') ?? false);

HomeRecommendationSection _mergeRecommendedArtistSections(
  HomeRecommendationSection local,
  List<HomeRecommendationSection> authenticated,
) {
  final buckets = <List<HomeRecommendationArtistItem>>[
    local.items.whereType<HomeRecommendationArtistItem>().toList(
      growable: false,
    ),
    ...authenticated.map(
      (section) => section.items
          .whereType<HomeRecommendationArtistItem>()
          .toList(growable: false),
    ),
  ];
  final positions = List<int>.filled(buckets.length, 0);
  final seen = <String>{};
  final items = <HomeRecommendationItem>[];
  while (items.length < 12) {
    var added = false;
    for (
      var bucketIndex = 0;
      bucketIndex < buckets.length && items.length < 12;
      bucketIndex += 1
    ) {
      final bucket = buckets[bucketIndex];
      while (positions[bucketIndex] < bucket.length) {
        final item = bucket[positions[bucketIndex]++];
        if (!seen.add(item.artist.browseId.trim())) continue;
        items.add(item);
        added = true;
        break;
      }
    }
    if (!added) break;
  }
  return HomeRecommendationSection.items(
    title: local.title,
    queueSourceId: 'personalized-home:recommended-artists+account',
    items: items,
  );
}

List<HomeRecommendationSection> _combineHomeRecommendationSections(
  List<HomeRecommendationSection> personalized,
  List<HomeRecommendationSection> youtubeMusic, {
  HomeRecommendationSection? historyArtistSection,
  bool hasQualifiedArtistHistory = false,
}) {
  final seenTracks = <String>{};
  final seenCollections = <String>{};
  final seenArtists = <String>{};
  final combined = <HomeRecommendationSection>[];
  final artistSections = youtubeMusic
      .where(_isHomeArtistOnlySection)
      .toList(growable: false);
  final regularYouTubeSections = youtubeMusic
      .where((section) => !_isHomeArtistOnlySection(section))
      .toList(growable: false);
  final authenticatedArtistSections = artistSections
      .where(_isAuthenticatedHomeArtistSection)
      .toList(growable: false);
  final personalizedArtists = historyArtistSection == null
      ? null
      : _reusePopularArtistArtwork(historyArtistSection, artistSections);
  final selectedArtistSections = personalizedArtists != null
      ? <HomeRecommendationSection>[
          authenticatedArtistSections.isEmpty
              ? personalizedArtists
              : _mergeRecommendedArtistSections(
                  personalizedArtists,
                  authenticatedArtistSections,
                ),
        ]
      : authenticatedArtistSections.isNotEmpty
      ? authenticatedArtistSections
      : hasQualifiedArtistHistory
      ? const <HomeRecommendationSection>[]
      : artistSections;
  final orderedSections = personalized.toList(growable: true);
  // The artist shelf replaces the removed personalized mixes shelf. Keep it
  // near the top (after Continue listening when present), while the ordinary
  // YouTube Music feed remains below all of BStream's existing sections.
  final continueIndex = orderedSections.indexWhere(
    (section) => section.isContinueListening,
  );
  orderedSections.insertAll(
    continueIndex < 0 ? 0 : continueIndex + 1,
    selectedArtistSections,
  );
  orderedSections.addAll(regularYouTubeSections);
  for (final section in orderedSections) {
    final items = <HomeRecommendationItem>[];
    for (final item in section.items) {
      final isNew = switch (item) {
        HomeRecommendationTrackItem(:final track) => seenTracks.add(
          track.id.trim(),
        ),
        HomeRecommendationCollectionItem(:final collection) =>
          seenCollections.add(collection.browseId.trim()),
        HomeRecommendationArtistItem(:final artist) => seenArtists.add(
          artist.browseId.trim(),
        ),
      };
      if (isNew) {
        items.add(item);
      }
    }
    if (items.isEmpty) {
      continue;
    }
    combined.add(
      HomeRecommendationSection.items(
        title: section.title,
        queueSourceId: section.queueSourceId,
        personalizedKind: section.personalizedKind,
        items: items,
      ),
    );
  }
  return List<HomeRecommendationSection>.unmodifiable(combined);
}

/// Keeps a recently closed remote detail page warm long enough for normal
/// back-and-forth navigation, without retaining every collection opened during
/// the whole application session.
final remoteDetailTracksCacheDurationProvider = Provider<Duration>(
  (_) => const Duration(minutes: 5),
);

void _retainRemoteDetailTracks(Ref ref) {
  final duration = ref.watch(remoteDetailTracksCacheDurationProvider);
  final cacheLink = ref.keepAlive();
  final cacheTimer = Timer(duration, cacheLink.close);
  ref.onDispose(cacheTimer.cancel);
}

/// Presentation-ready metadata and tracks for a public YouTube Music
/// collection. Nullable header fields let the detail page retain its localized
/// fallback labels for private or changing playlist layouts.
class RemoteCollectionData {
  RemoteCollectionData({
    required List<TrackInfo> tracks,
    this.title,
    this.subtitle,
    this.artworkSource,
  }) : tracks = List<TrackInfo>.unmodifiable(tracks);

  final String? title;
  final String? subtitle;
  final String? artworkSource;
  final List<TrackInfo> tracks;
}

typedef YouTubeMusicAuthenticatedPlaylistLoader =
    Future<ytm_account.RemotePlaylistSnapshot> Function(String playlistId);

/// Authenticated playlist reader kept as a narrow, injectable boundary.
///
/// Public collection pages continue to use anonymous InnerTube first. This
/// loader is only consulted by incoming playlist links when that public read
/// cannot expose any tracks (for example, a private playlist created by the
/// active BStream account).
final youtubeMusicAuthenticatedPlaylistLoaderProvider =
    Provider<YouTubeMusicAuthenticatedPlaylistLoader?>((ref) {
      final gateway = ref.watch(
        youtubeMusicAuthenticatedAccountGatewayProvider,
      );
      return gateway?.getPlaylist;
    });

String? _nonEmptyCollectionText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

final homeCollectionDetailProvider = FutureProvider.autoDispose
    .family<RemoteCollectionData, String>((ref, browseId) async {
      _retainRemoteDetailTracks(ref);
      final normalizedBrowseId = browseId.trim();
      if (normalizedBrowseId.isEmpty) {
        throw ArgumentError.value(browseId, 'browseId', 'Must not be empty.');
      }
      final search = ref.watch(youtubeMusicSearchProvider);
      if (search is YouTubeMusicCollectionDetailLookup) {
        final detail = await (search as YouTubeMusicCollectionDetailLookup)
            .getCollectionDetail(
              normalizedBrowseId,
              limit: innerTubeDetailResultLimit,
            );
        final tracks = detail.songs
            .map(trackInfoFromInnerTubeSong)
            .toList(growable: false);
        return RemoteCollectionData(
          title: _nonEmptyCollectionText(detail.title),
          subtitle: _nonEmptyCollectionText(detail.subtitle),
          artworkSource:
              _nonEmptyCollectionText(detail.thumbnailUrl) ??
              (tracks.isEmpty ? null : tracks.first.thumbnailUrl),
          tracks: tracks,
        );
      }

      // Compatibility path for test doubles and alternate catalog adapters
      // that only implement the original songs-only contract.
      final tracks = await ref.watch(
        homeCollectionTracksProvider(normalizedBrowseId).future,
      );
      return RemoteCollectionData(
        artworkSource: tracks.isEmpty ? null : tracks.first.thumbnailUrl,
        tracks: tracks,
      );
    });

/// Resolves a playlist opened from a public link without penalizing public
/// playlists: anonymous InnerTube remains first and wins whenever it returns
/// tracks. An authenticated account read is a bounded fallback for private
/// synchronized playlists whose anonymous representation is empty.
final incomingYouTubeMusicPlaylistDetailProvider = FutureProvider.autoDispose
    .family<RemoteCollectionData, String>((ref, browseId) async {
      _retainRemoteDetailTracks(ref);
      final normalizedBrowseId = browseId.trim();
      if (normalizedBrowseId.isEmpty) {
        throw ArgumentError.value(browseId, 'browseId', 'Must not be empty.');
      }

      final anonymousFuture = ref.watch(
        homeCollectionDetailProvider(normalizedBrowseId).future,
      );
      final authenticatedLoader = ref.watch(
        youtubeMusicAuthenticatedPlaylistLoaderProvider,
      );

      RemoteCollectionData? anonymous;
      Object? anonymousError;
      StackTrace? anonymousStackTrace;
      try {
        anonymous = await anonymousFuture;
        if (anonymous.tracks.isNotEmpty) {
          return anonymous;
        }
      } catch (error, stackTrace) {
        anonymousError = error;
        anonymousStackTrace = stackTrace;
      }

      final playlistId = canonicalYouTubeMusicPlaylistId(normalizedBrowseId);
      if (authenticatedLoader != null && playlistId != null) {
        try {
          final snapshot = await authenticatedLoader(playlistId);
          // Detail pages can safely present a bounded partial snapshot. A
          // very large private playlist is still more useful than the empty
          // anonymous representation, while synchronization keeps requiring
          // complete snapshots in its own stricter path.
          return _remoteCollectionDataFromAuthenticatedPlaylist(snapshot);
        } catch (error) {
          debugPrint('Authenticated playlist link fallback failed: $error');
        }
      }

      if (anonymous != null) {
        return anonymous;
      }
      if (anonymousError != null && anonymousStackTrace != null) {
        Error.throwWithStackTrace(anonymousError, anonymousStackTrace);
      }
      throw StateError('The playlist could not be resolved.');
    });

final incomingYouTubeMusicPlaylistTracksProvider = FutureProvider.autoDispose
    .family<List<TrackInfo>, String>((ref, browseId) async {
      final detail = await ref.watch(
        incomingYouTubeMusicPlaylistDetailProvider(browseId).future,
      );
      return detail.tracks;
    });

RemoteCollectionData _remoteCollectionDataFromAuthenticatedPlaylist(
  ytm_account.RemotePlaylistSnapshot snapshot,
) {
  final tracks = <TrackInfo>[];
  for (final entry in snapshot.entries) {
    final videoId = entry.videoId?.trim();
    if (!entry.isAvailable || videoId == null || videoId.isEmpty) {
      continue;
    }
    tracks.add(
      TrackInfo(
        id: videoId,
        title: entry.title,
        artist: entry.artist.isEmpty ? 'Desconocido' : entry.artist,
        artists: entry.artists,
        artistBrowseIds: entry.artistBrowseIds,
        album: entry.album,
        duration: entry.duration,
        thumbnailUrl:
            youtubeThumbnailSourceForVideoId(videoId) ?? entry.thumbnailUrl,
        catalogThumbnailUrl: entry.thumbnailUrl,
        url: Uri.https('www.youtube.com', '/watch', <String, String>{
          'v': videoId,
        }).toString(),
        metadataSource: TrackMetadataSource.youtubeMusic,
      ),
    );
  }
  final summary = snapshot.summary;
  return RemoteCollectionData(
    title: _nonEmptyCollectionText(summary?.title),
    subtitle: _nonEmptyCollectionText(summary?.owner),
    artworkSource:
        _nonEmptyCollectionText(summary?.thumbnailUrl) ??
        (tracks.isEmpty ? null : tracks.first.thumbnailUrl),
    tracks: tracks,
  );
}

final homeCollectionTracksProvider = FutureProvider.autoDispose
    .family<List<TrackInfo>, String>((ref, browseId) async {
      _retainRemoteDetailTracks(ref);
      final normalizedBrowseId = browseId.trim();
      if (normalizedBrowseId.isEmpty) {
        throw ArgumentError.value(browseId, 'browseId', 'Must not be empty.');
      }
      final search = ref.watch(youtubeMusicSearchProvider);
      const automixBrowsePrefix = 'VLRDAMVM';
      if (normalizedBrowseId.startsWith(automixBrowsePrefix) &&
          search is YouTubeMusicRelated) {
        final rawSeed = normalizedBrowseId.substring(
          automixBrowsePrefix.length,
        );
        final seedVideoId = const BStreamTrackLinkCodec().extractVideoId(
          rawSeed,
        );
        if (seedVideoId != null) {
          final page = await (search as YouTubeMusicRelated).getNext(
            seedVideoId,
            radio: true,
            limit: innerTubeDetailResultLimit,
          );
          return List.unmodifiable(page.songs.map(trackInfoFromInnerTubeSong));
        }
      }
      if (search is! YouTubeMusicCollectionLookup) {
        throw UnsupportedError(
          'The configured YouTube Music service cannot resolve collections.',
        );
      }
      final lookup = search as YouTubeMusicCollectionLookup;
      final songs = await lookup.getCollectionSongs(
        normalizedBrowseId,
        limit: innerTubeDetailResultLimit,
      );
      return List.unmodifiable(songs.map(trackInfoFromInnerTubeSong));
    });

final homeAlbumTracksProvider = FutureProvider.autoDispose
    .family<List<TrackInfo>, String>((ref, browseId) async {
      _retainRemoteDetailTracks(ref);
      final normalizedBrowseId = browseId.trim();
      if (normalizedBrowseId.isEmpty) {
        throw ArgumentError.value(browseId, 'browseId', 'Must not be empty.');
      }
      final search = ref.watch(youtubeMusicSearchProvider);
      if (search is! YouTubeMusicAlbumLookup) {
        throw UnsupportedError(
          'The configured YouTube Music service cannot resolve albums.',
        );
      }
      final lookup = search as YouTubeMusicAlbumLookup;
      final songs = await lookup.getAlbumSongs(
        normalizedBrowseId,
        limit: innerTubeDetailResultLimit,
      );
      return List.unmodifiable(songs.map(trackInfoFromInnerTubeSong));
    });

HomeRecommendationItem? _homeRecommendationItemFromInnerTube(
  InnerTubeHomeItem item,
) {
  if (item is InnerTubeHomeSongItem) {
    return HomeRecommendationTrackItem(trackInfoFromInnerTubeSong(item.song));
  }
  if (item is InnerTubeHomeCollection) {
    return HomeRecommendationCollectionItem(
      HomeRecommendationCollection(
        title: item.title,
        subtitle: item.subtitle,
        thumbnailUrl: item.thumbnailUrl,
        browseId: item.browseId,
        playlistId: item.playlistId,
        kind: switch (item.kind) {
          InnerTubeHomeCollectionKind.mix =>
            HomeRecommendationCollectionKind.mix,
          InnerTubeHomeCollectionKind.playlist =>
            HomeRecommendationCollectionKind.playlist,
        },
      ),
    );
  }
  if (item is InnerTubeHomeArtistItem) {
    final browseId = item.artist.browseId.trim();
    final name = item.artist.name.trim();
    if (!_isValidArtistBrowseId(browseId) || name.isEmpty) {
      return null;
    }
    return HomeRecommendationArtistItem(
      HomeRecommendationArtist(
        name: name,
        browseId: browseId,
        thumbnailUrl: item.artist.thumbnailUrl,
      ),
    );
  }
  return null;
}

bool _isHomeMixOnlySection(List<HomeRecommendationItem> items) {
  return items.isNotEmpty &&
      items.every(
        (item) =>
            item is HomeRecommendationCollectionItem && item.collection.isMix,
      );
}

bool _isSpecificYourMixesSection({
  required String title,
  required List<HomeRecommendationItem> items,
  required AppStrings strings,
}) {
  final normalizedTitle = title.trim().toLowerCase();
  final yourMixesTitles = <String>{
    strings.yourMixes.trim().toLowerCase(),
    'tus mixes',
    'your mixes',
  };
  return yourMixesTitles.contains(normalizedTitle) &&
      _isHomeMixOnlySection(items);
}

bool _isHomeArtistOnlySection(HomeRecommendationSection section) {
  return section.items.isNotEmpty &&
      section.items.every((item) => item is HomeRecommendationArtistItem);
}

final remoteMusicDataSourceProvider = Provider<RemoteMusicDataSource>((ref) {
  return RemoteMusicDataSource(
    ref.watch(downloaderServiceProvider),
    youtubeMusicSearch: ref.watch(youtubeMusicSearchProvider),
  );
});

final searchAlbumTracksProvider = FutureProvider.autoDispose
    .family<List<TrackInfo>, String>((ref, browseId) async {
      _retainRemoteDetailTracks(ref);
      final normalizedBrowseId = browseId.trim();
      if (normalizedBrowseId.isEmpty) {
        throw ArgumentError.value(browseId, 'browseId', 'Must not be empty.');
      }
      final search = ref
          .watch(remoteMusicDataSourceProvider)
          .youtubeMusicSearch;
      if (search is! YouTubeMusicAlbumLookup) {
        throw UnsupportedError(
          'The configured YouTube Music service cannot resolve albums.',
        );
      }
      final songs = await (search as YouTubeMusicAlbumLookup).getAlbumSongs(
        normalizedBrowseId,
        limit: innerTubeDetailResultLimit,
      );
      return List.unmodifiable(songs.map(trackInfoFromInnerTubeSong));
    });

final localMusicDataSourceProvider = Provider<LocalMusicDataSource>((ref) {
  return LocalMusicDataSource(ref.watch(databaseServiceProvider));
});

final musicRepositoryProvider = Provider<MusicRepository>((ref) {
  return MusicRepositoryImpl(ref.watch(remoteMusicDataSourceProvider));
});

final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  return LibraryRepositoryImpl(ref.watch(localMusicDataSourceProvider));
});

final localTrackFileProbeProvider = Provider<LocalTrackFileProbe>((ref) {
  return probeLocalTrackFile;
});

final localLibraryReconcilerProvider = Provider<LocalLibraryReconciler>((ref) {
  return LocalLibraryReconciler(
    ref.read(libraryRepositoryProvider),
    ref.read(localTrackFileProbeProvider),
  );
});

final localLibraryReconciliationProvider =
    FutureProvider<LocalLibraryReconciliationResult>((ref) async {
      // Android may migrate the managed media folder and rewrite stored paths
      // while settings initialize. Never inspect the old paths before it ends.
      await ref.read(settingsControllerProvider.future);
      final result = await ref.read(localLibraryReconcilerProvider).reconcile();
      if (result.changed) {
        ref
          ..invalidate(libraryTracksProvider)
          ..invalidate(historyProvider)
          ..invalidate(playlistsControllerProvider);
      }
      return result;
    });

final getTrackInfoProvider = Provider<GetTrackInfo>((ref) {
  return GetTrackInfo(ref.watch(musicRepositoryProvider));
});

final getPlaybackInfoProvider = Provider<GetPlaybackInfo>((ref) {
  return GetPlaybackInfo(ref.watch(musicRepositoryProvider));
});

final searchTracksProvider = Provider<SearchTracks>((ref) {
  return SearchTracks(ref.watch(musicRepositoryProvider));
});

final downloadAudioProvider = Provider<DownloadAudio>((ref) {
  return DownloadAudio(ref.watch(musicRepositoryProvider));
});

final audioStreamResolverProvider = Provider<AudioStreamResolver>((ref) {
  final resolver = InnerTubeAudioResolver(
    ref.watch(innerTubePlaybackServiceProvider),
  );
  ref.onDispose(() => unawaited(resolver.dispose()));
  return resolver;
});

/// Delay used between complete retries of the active remote playback chain.
///
/// Keeping it injectable makes cancellation and retry limits deterministic in
/// tests without changing the resolver used by background prefetches.
typedef RemotePlaybackRetryDelay = Future<void> Function(Duration duration);

final remotePlaybackRetryDelayProvider = Provider<RemotePlaybackRetryDelay>(
  (ref) =>
      (duration) => Future<void>.delayed(duration),
);

final getLibraryTracksProvider = Provider<GetLibraryTracks>((ref) {
  return GetLibraryTracks(ref.watch(libraryRepositoryProvider));
});

final getPlaylistsProvider = Provider<GetPlaylists>((ref) {
  return GetPlaylists(ref.watch(libraryRepositoryProvider));
});

final getHistoryProvider = Provider<GetHistory>((ref) {
  return GetHistory(ref.watch(libraryRepositoryProvider));
});

final libraryTracksProvider = FutureProvider<List<LocalTrack>>((ref) {
  return ref.watch(getLibraryTracksProvider).call();
});

final historyProvider = FutureProvider<List<LocalTrack>>((ref) {
  return ref.watch(getHistoryProvider).call();
});

final tiktokLiveCommandServiceProvider = Provider<TikTokLiveCommandService>((
  ref,
) {
  final service = TikTokLiveCommandService();
  ref.onDispose(service.dispose);
  return service;
});
