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
import '../../../../platform_channels/android_ytdl_channel.dart';
import '../../../../services/downloader/android_downloader_service.dart';
import '../../../../services/downloader/audio_stream_resolver.dart';
import '../../../../services/downloader/desktop_tool_locator.dart';
import '../../../../services/downloader/desktop_downloader_service.dart';
import '../../../../services/downloader/downloader_service.dart';
import '../../../../services/downloader/fallback_audio_resolver.dart';
import '../../../../services/downloader/yt_dlp_audio_resolver.dart';
import '../../../../services/downloader/adapters/youtube_explode/youtube_explode_audio_resolver.dart';
import '../../../../services/downloader/adapters/youtube_explode/youtube_explode_download_service.dart';
import '../../../../services/downloader/adapters/youtube_explode/youtube_explode_runtime.dart';
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
import '../../../../services/storage/backup_service.dart';
import '../../../../services/storage/library_csv_import_service.dart';
import '../../../../services/storage/library_csv_service.dart';
import '../../../../services/storage/library_operation_coordinator.dart';
import '../../../../services/storage/local_database_service.dart';
import '../../../../services/storage/local_database_shutdown_coordinator.dart';
import '../../../../services/storage/local_library_reconciler.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../../../services/youtube_music/shared_preferences_visitor_data_store.dart';
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

final youtubeExplodeRuntimeProvider = Provider<YoutubeExplodeRuntime>((ref) {
  final runtime = YoutubeExplodeRuntime(
    platform: AppPlatform.current,
    androidChannel: AppPlatform.isAndroid ? AndroidYtdlChannel() : null,
    denoExecutable: AppPlatform.isDesktop ? findBundledDenoExecutable() : null,
  );
  ref.onDispose(runtime.dispose);
  return runtime;
});

final downloaderServiceProvider = Provider<DownloaderService>((ref) {
  late final DownloaderService fallback;
  if (AppPlatform.isAndroid) {
    fallback = AndroidDownloaderService(AndroidYtdlChannel());
  } else if (AppPlatform.isDesktop) {
    final service = DesktopDownloaderService();
    ref.onDispose(service.dispose);
    fallback = service;
  } else {
    throw const UnsupportedPlatformException(
      'BStream Music soporta Android, Windows, Linux y macOS.',
    );
  }

  final service = YoutubeExplodeDownloadService(
    fallback: fallback,
    client: DefaultYoutubeExplodeDownloadClient(
      runtime: ref.watch(youtubeExplodeRuntimeProvider),
    ),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// The yt-dlp implementation behind the primary download decorator.
/// Tests and alternate integrations that override [downloaderServiceProvider]
/// continue to work without knowing about the production wrapper.
final ytDlpDownloaderServiceProvider = Provider<DownloaderService>((ref) {
  final service = ref.watch(downloaderServiceProvider);
  return service is YoutubeExplodeDownloadService ? service.fallback : service;
});

final downloaderWarmupProvider = FutureProvider<void>((ref) async {
  final runtime = ref.watch(youtubeExplodeRuntimeProvider);
  if (AppPlatform.isAndroid) {
    unawaited(runtime.prewarmPoTokens());
  }
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
      () => AppPlatform.isDesktop || AppPlatform.isAndroid
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

/// The unmodified anonymous `FEmusic_home` feed. Personalized sections are
/// intentionally built and cached separately, then combined by
/// [homeRecommendationsProvider].
final youtubeMusicHomeRecommendationsProvider =
    FutureProvider<List<HomeRecommendationSection>>(
      (ref) async {
        final search = ref.watch(youtubeMusicSearchProvider);
        if (search is! YouTubeMusicHome) {
          return const <HomeRecommendationSection>[];
        }
        final home = search as YouTubeMusicHome;
        final sections = await home.getHome(
          maxSections: 5,
          maxItemsPerSection: 12,
        );
        return List.unmodifiable(
          sections
              .map(
                (section) => HomeRecommendationSection.items(
                  title: section.title,
                  queueSourceId: 'youtube-home:${section.title}',
                  items: section.items
                      .map(_homeRecommendationItemFromInnerTube)
                      .whereType<HomeRecommendationItem>()
                      .toList(growable: false),
                ),
              )
              .where((section) => section.items.isNotEmpty),
        );
      },
      // Home deliberately renders errors as local-only. Avoid Riverpod's
      // automatic retries so a manual refresh remains predictable.
      retry: (_, _) => null,
    );

abstract interface class PersonalizedHomeFeedSource {
  Future<CachedPersonalizedRecommendationFeed?> loadCachedFeed();

  Future<PersonalizedRecommendationFeed> refresh({bool forceNetwork = false});
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
  List<HomeRecommendationSection> _personalized = const [];
  List<HomeRecommendationSection> _youtubeMusic = const [];
  Future<void>? _refreshInFlight;
  bool _inFlightForcesNetwork = false;
  bool _inFlightRefreshesYouTube = false;
  int _buildEpoch = 0;

  @override
  Future<List<HomeRecommendationSection>> build() async {
    final epoch = ++_buildEpoch;
    // A dependency rebuild supersedes any older refresh. Old results are
    // rejected by [epoch], while this build remains free to start a new one.
    _refreshInFlight = null;
    _inFlightForcesNetwork = false;
    _inFlightRefreshesYouTube = false;
    final strings = ref.watch(appStringsProvider);
    _personalizedSource = ref.watch(personalizedHomeFeedSourceProvider);

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
    final initial = _combineHomeRecommendationSections(
      _personalized,
      _youtubeMusic,
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
    final previous =
        state.asData?.value ??
        _combineHomeRecommendationSections(_personalized, _youtubeMusic);
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
    final strings = ref.read(appStringsProvider);
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

    _personalized = refreshedPersonalized ?? _personalized;
    _youtubeMusic = refreshedYouTubeMusic ?? _youtubeMusic;

    final combined = _combineHomeRecommendationSections(
      _personalized,
      _youtubeMusic,
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

List<HomeRecommendationSection> _combineHomeRecommendationSections(
  List<HomeRecommendationSection> personalized,
  List<HomeRecommendationSection> youtubeMusic,
) {
  final seenTracks = <String>{};
  final seenCollections = <String>{};
  final combined = <HomeRecommendationSection>[];
  for (final section in <HomeRecommendationSection>[
    ...personalized,
    ...youtubeMusic,
  ]) {
    final items = <HomeRecommendationItem>[];
    for (final item in section.items) {
      final isNew = switch (item) {
        HomeRecommendationTrackItem(:final track) => seenTracks.add(
          track.id.trim(),
        ),
        HomeRecommendationCollectionItem(:final collection) =>
          seenCollections.add(collection.browseId.trim()),
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

final homeCollectionTracksProvider =
    FutureProvider.family<List<TrackInfo>, String>((ref, browseId) async {
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

final homeAlbumTracksProvider = FutureProvider.family<List<TrackInfo>, String>((
  ref,
  browseId,
) async {
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
  return null;
}

final remoteMusicDataSourceProvider = Provider<RemoteMusicDataSource>((ref) {
  return RemoteMusicDataSource(
    ref.watch(downloaderServiceProvider),
    youtubeMusicSearch: ref.watch(youtubeMusicSearchProvider),
  );
});

final searchAlbumTracksProvider =
    FutureProvider.family<List<TrackInfo>, String>((ref, browseId) async {
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
  final primary = YoutubeExplodeAudioResolver(
    runtime: ref.watch(youtubeExplodeRuntimeProvider),
  );
  final fallback = YtDlpAudioResolver(
    ref.watch(ytDlpDownloaderServiceProvider),
  );
  final resolver = FallbackAudioResolver([primary, fallback]);
  ref.onDispose(resolver.dispose);
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
