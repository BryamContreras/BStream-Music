import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
import '../../../../services/downloader/desktop_downloader_service.dart';
import '../../../../services/downloader/downloader_service.dart';
import '../../../../services/downloader/fallback_audio_resolver.dart';
import '../../../../services/downloader/yt_dlp_audio_resolver.dart';
import '../../../../services/downloader/adapters/youtube_explode/youtube_explode_audio_resolver.dart';
import '../../../../services/downloader/adapters/youtube_explode/youtube_explode_download_service.dart';
import '../../../../services/live/tiktok_live_command_service.dart';
import '../../../../services/lyrics/lyrics_service.dart';
import '../../../../services/media_session/desktop_media_session.dart';
import '../../../../services/media_session/desktop_media_session_factory.dart';
import '../../../../services/player/just_audio_player_service.dart';
import '../../../../services/player/media_kit_player_service.dart';
import '../../../../services/player/player_service.dart';
import '../../../../services/sharing/bstream_track_link.dart';
import '../../../../services/sharing/incoming_track_link_service.dart';
import '../../../../services/sharing/track_share_service.dart';
import '../../../../services/storage/backup_service.dart';
import '../../../../services/storage/library_csv_import_service.dart';
import '../../../../services/storage/library_csv_service.dart';
import '../../../../services/storage/library_operation_coordinator.dart';
import '../../../../services/storage/local_database_service.dart';
import '../../../../services/storage/local_library_reconciler.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../data/datasources/local_music_datasource.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../data/models/track_info_model.dart';
import '../../data/repositories/library_repository_impl.dart';
import '../../data/repositories/music_repository_impl.dart';
import '../../domain/entities/download_options.dart';
import '../../domain/entities/download_result.dart';
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

export 'app_strings.dart';
export 'lyrics_animation_style.dart';

part 'app_strings_provider.dart';
part 'download_controller.dart';
part 'local_track_download_helper.dart';
part 'library_csv_transfer_controller.dart';
part 'lyrics_offset_controller.dart';
part 'player_controller.dart';
part 'playlists_controller.dart';
part 'remote_playback_cache.dart';
part 'remote_track_resolver.dart';
part 'search_controller.dart';
part 'settings_controller.dart';
part 'sleep_timer_controller.dart';
part 'tiktok_live_controller.dart';

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

  final service = YoutubeExplodeDownloadService(fallback: fallback);
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
  await ref.watch(downloaderServiceProvider).initialize();
});

final playerServiceProvider = Provider<PlayerService>((ref) {
  final service = AppPlatform.isDesktop
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
      () => AppPlatform.isDesktop ? createDesktopMediaSession() : null,
);

final desktopMediaSessionProvider = Provider<DesktopMediaSession?>((ref) {
  final session = ref.watch(desktopMediaSessionFactoryProvider)();
  if (session == null) {
    return null;
  }

  PlayerSnapshot? latestSnapshot;
  var latestQueue = const PlaybackQueueState();

  Future<void> runSafely(
    String operation,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      // A system media integration must never interrupt app playback.
      debugPrint('Desktop media session $operation failed: $error');
    }
  }

  void publishState() {
    final snapshot = latestSnapshot;
    if (snapshot == null) {
      return;
    }
    final queue = latestQueue;
    unawaited(
      runSafely(
        'update',
        () => session.update(
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
      ),
    );
  }

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

  unawaited(runSafely('initialization', () => session.initialize(callbacks)));
  ref.onDispose(() {
    unawaited(runSafely('disposal', session.dispose));
  });
  return session;
});

final databaseServiceProvider = Provider<LocalDatabaseService>((ref) {
  return LocalDatabaseService();
});

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
  final service = InnerTubeSearchService();
  ref.onDispose(service.dispose);
  return service;
});

sealed class HomeRecommendationItem {
  const HomeRecommendationItem();
}

final class HomeRecommendationTrackItem extends HomeRecommendationItem {
  const HomeRecommendationTrackItem(this.track);

  final TrackInfo track;
}

enum HomeRecommendationCollectionKind { mix, playlist }

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
}

final class HomeRecommendationCollectionItem extends HomeRecommendationItem {
  const HomeRecommendationCollectionItem(this.collection);

  final HomeRecommendationCollection collection;
}

class HomeRecommendationSection {
  HomeRecommendationSection({
    required String title,
    required List<TrackInfo> tracks,
  }) : this.items(
         title: title,
         items: tracks
             .map<HomeRecommendationItem>(HomeRecommendationTrackItem.new)
             .toList(growable: false),
       );

  HomeRecommendationSection.items({
    required this.title,
    required List<HomeRecommendationItem> items,
  }) : items = List.unmodifiable(items);

  final String title;
  final List<HomeRecommendationItem> items;

  List<TrackInfo> get tracks => List.unmodifiable(
    items.whereType<HomeRecommendationTrackItem>().map((item) => item.track),
  );
}

final homeRecommendationsProvider =
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

final homeCollectionTracksProvider =
    FutureProvider.family<List<TrackInfo>, String>((ref, browseId) async {
      final normalizedBrowseId = browseId.trim();
      if (normalizedBrowseId.isEmpty) {
        throw ArgumentError.value(browseId, 'browseId', 'Must not be empty.');
      }
      final search = ref.watch(youtubeMusicSearchProvider);
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
  final primary = YoutubeExplodeAudioResolver();
  final fallback = YtDlpAudioResolver(
    ref.watch(ytDlpDownloaderServiceProvider),
  );
  final resolver = FallbackAudioResolver([primary, fallback]);
  ref.onDispose(resolver.dispose);
  return resolver;
});

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
