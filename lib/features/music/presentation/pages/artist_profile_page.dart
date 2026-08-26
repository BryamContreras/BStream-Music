import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_ui.dart';
import '../../../../services/youtube_music/account/youtube_music_account.dart';
import '../../../../services/youtube_music/innertube_search_service.dart';
import '../../data/datasources/remote_music_datasource.dart';
import '../../domain/entities/track_info.dart';
import '../providers/music_providers.dart';
import '../providers/subscribed_artists_controller.dart';
import '../providers/youtube_music_auth_controller.dart';
import '../widgets/artwork_gradient_header_background.dart';
import '../widgets/mini_player.dart';
import '../widgets/source_image.dart';
import '../widgets/surface_detail_app_bar.dart';
import '../widgets/track_result_tile.dart';
import 'remote_collection_detail_page.dart';

typedef ArtistProfileRequest = ({
  String artistBrowseId,
  String artistName,
  String? artistThumbnailUrl,
});

final artistProfileProvider = FutureProvider.autoDispose
    .family<InnerTubeArtistProfile, ArtistProfileRequest>((ref, request) async {
      // Opening a profile again (or prefetching it during navigation) should
      // reuse the same browse response for a short period without retaining
      // an unbounded artist catalog for the whole application session.
      final cacheLink = ref.keepAlive();
      final cacheTimer = Timer(const Duration(minutes: 5), cacheLink.close);
      ref.onDispose(cacheTimer.cancel);
      final service = ref.watch(youtubeMusicSearchProvider);
      if (service is YouTubeMusicArtistProfileLookup) {
        return (service as YouTubeMusicArtistProfileLookup).getArtistProfile(
          request.artistBrowseId,
          fallbackName: request.artistName,
          fallbackThumbnailUrl: request.artistThumbnailUrl,
        );
      }
      if (service is YouTubeMusicArtistLookup) {
        final releases = await (service as YouTubeMusicArtistLookup)
            .getArtistReleases(request.artistBrowseId);
        return InnerTubeArtistProfile(
          artist: InnerTubeArtist(
            browseId: request.artistBrowseId,
            name: request.artistName,
            thumbnailUrl: request.artistThumbnailUrl,
          ),
          popularSongs: const <InnerTubeSong>[],
          albums: releases
              .where((release) => !_isSingleRelease(release))
              .toList(growable: false),
          singles: releases.where(_isSingleRelease).toList(growable: false),
        );
      }
      throw UnsupportedError('Artist profiles are not available.');
    });

final youtubeMusicArtistAccountProvider = Provider<YouTubeMusicArtistAccount?>((
  ref,
) {
  return ref.watch(youtubeMusicAuthenticatedAccountGatewayProvider);
});

final artistSubscriptionStateProvider = FutureProvider.autoDispose
    .family<RemoteArtistSubscriptionState?, String>((ref, artistBrowseId) {
      final account = ref.watch(youtubeMusicArtistAccountProvider);
      if (account == null) return Future.value(null);
      return account.getArtistSubscriptionState(artistBrowseId);
    });

class ArtistProfilePage extends ConsumerStatefulWidget {
  const ArtistProfilePage({
    required this.artistBrowseId,
    required this.artistName,
    required this.onOpenPlayer,
    this.artistThumbnailUrl,
    this.seedVideoId,
    super.key,
  });

  final String artistBrowseId;
  final String artistName;
  final String? artistThumbnailUrl;
  final String? seedVideoId;
  final VoidCallback onOpenPlayer;

  @override
  ConsumerState<ArtistProfilePage> createState() => _ArtistProfilePageState();
}

class _ArtistProfilePageState extends ConsumerState<ArtistProfilePage> {
  bool _subscriptionBusy = false;
  bool _radioBusy = false;
  bool _popularPlaybackBusy = false;
  bool? _subscriptionOverride;

  ArtistProfileRequest get _request => (
    artistBrowseId: widget.artistBrowseId,
    artistName: widget.artistName,
    artistThumbnailUrl: widget.artistThumbnailUrl,
  );

  @override
  Widget build(BuildContext context) {
    final strings = ref.watch(appStringsProvider);
    final profileState = ref.watch(artistProfileProvider(_request));
    final miniPlayerAppearance = ref.watch(
      settingsControllerProvider.select(
        (settings) => (
          mode: settings.value?.miniPlayerMode ?? defaultMiniPlayerMode,
          backgroundMode:
              settings.value?.miniPlayerBackgroundMode ??
              defaultMiniPlayerBackgroundMode,
        ),
      ),
    );
    final miniPlayerMode = miniPlayerAppearance.mode;
    final underlayMiniPlayer =
        miniPlayerMode == MiniPlayerMode.capsule ||
        miniPlayerAppearance.backgroundMode ==
            MiniPlayerBackgroundMode.transparent;
    final miniPlayerHeight = miniPlayerHeightFor(context, mode: miniPlayerMode);
    final profile =
        profileState.value ??
        InnerTubeArtistProfile(
          artist: InnerTubeArtist(
            browseId: widget.artistBrowseId,
            name: widget.artistName,
            thumbnailUrl: widget.artistThumbnailUrl,
          ),
          popularSongs: const <InnerTubeSong>[],
          albums: const <InnerTubeAlbum>[],
          singles: const <InnerTubeAlbum>[],
        );

    return Scaffold(
      key: const ValueKey('artist-profile-page'),
      extendBody: underlayMiniPlayer,
      extendBodyBehindAppBar: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: SurfaceDetailAppBar(
        appBarKey: const ValueKey('artist-profile-app-bar'),
        surfaceKey: const ValueKey('artist-profile-app-bar-surface'),
        blurKey: const ValueKey('artist-profile-app-bar-blur'),
        statusBarSurfaceKey: const ValueKey(
          'artist-profile-status-bar-surface',
        ),
        title: Text(
          strings.artistProfile,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      // Render the identity and artwork immediately. Mix pages feel faster
      // because their header metadata is already known before tracks load;
      // artist pages now follow the same progressive pattern.
      body: _buildProfile(
        context,
        profile,
        profileLoaded: profileState.hasValue,
        profileLoading: profileState.isLoading,
        profileFailed: profileState.hasError && !profileState.hasValue,
      ),
      bottomNavigationBar: ColoredBox(
        color: underlayMiniPlayer
            ? Colors.transparent
            : Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: miniPlayerHeight,
            child: MiniPlayer(
              mode: miniPlayerMode,
              backgroundMode: miniPlayerAppearance.backgroundMode,
              onOpenPlayer: _returnToPlayer,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfile(
    BuildContext context,
    InnerTubeArtistProfile profile, {
    required bool profileLoaded,
    required bool profileLoading,
    required bool profileFailed,
  }) {
    final strings = ref.watch(appStringsProvider);
    final tracks = profile.popularSongs
        .map(trackInfoFromInnerTubeSong)
        .toList(growable: false);
    final account = ref.watch(youtubeMusicArtistAccountProvider);
    final subscription = account == null || !profileLoaded
        ? const AsyncValue<RemoteArtistSubscriptionState?>.data(null)
        : ref.watch(artistSubscriptionStateProvider(widget.artistBrowseId));
    final remoteSubscription = subscription.value;
    final subscriptionChannelId = _firstYouTubeChannelId(<String?>[
      remoteSubscription?.channelId,
      profile.channelId,
      // Most artist browse IDs are already the concrete channel ID. Some
      // artist responses omit it from the subscription renderer, so retain
      // that safe fallback without ever treating an MPLA browse ID as a
      // channel accepted by the mutation endpoint.
      widget.artistBrowseId,
    ]);
    final subscribed =
        _subscriptionOverride ??
        remoteSubscription?.isSubscribed ??
        profile.isSubscribed ??
        false;
    return CustomScrollView(
      key: const ValueKey('artist-profile-scroll'),
      scrollCacheExtent: const ScrollCacheExtent.pixels(800),
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            key: const ValueKey('artist-profile-app-bar-spacer'),
            height: surfaceDetailAppBarBodyInset(context),
          ),
        ),
        SliverToBoxAdapter(
          child: RepaintBoundary(
            key: const ValueKey('artist-profile-header'),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ArtworkGradientHeaderBackground(
                    artworkSource: profile.artist.thumbnailUrl,
                    cacheWidth: 640,
                    keyPrefix: 'artist-profile',
                  ),
                ),
                _ArtistHeader(
                  profile: profile,
                  radioLabel: strings.artistMix,
                  subscribeLabel: subscribed
                      ? strings.unsubscribe
                      : strings.subscribe,
                  playLabel: strings.play,
                  showSubscription: account != null,
                  subscriptionTooltip:
                      profileLoaded && subscriptionChannelId == null
                      ? strings.artistSubscriptionUnavailable
                      : null,
                  subscriptionBusy:
                      _subscriptionBusy ||
                      profileLoading ||
                      (account != null && subscription.isLoading),
                  radioBusy: _radioBusy,
                  canStartRadio:
                      !_popularPlaybackBusy &&
                      ((profile.radioPlaylistId?.trim().isNotEmpty == true &&
                              (profile.radioSeedVideoId?.trim().isNotEmpty ==
                                      true ||
                                  tracks.isNotEmpty ||
                                  widget.seedVideoId?.trim().isNotEmpty ==
                                      true)) ||
                          tracks.isNotEmpty ||
                          widget.seedVideoId?.trim().isNotEmpty == true),
                  canPlayAll:
                      profileLoaded &&
                      !_radioBusy &&
                      (profile.playPlaylistId?.trim().isNotEmpty == true ||
                          tracks.isNotEmpty),
                  subscribed: subscribed,
                  playAllBusy: _popularPlaybackBusy,
                  onRadio: () => _startRadio(profile, tracks),
                  onPlayAll: () => _playArtistQueue(profile, tracks),
                  onSubscription: () {
                    if (account == null || subscriptionChannelId == null) {
                      _showMessage(strings.artistSubscriptionUnavailable);
                      return;
                    }
                    _toggleSubscription(
                      account,
                      subscriptionChannelId,
                      subscribed,
                      profile,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        if (profileLoading && !profileLoaded)
          const SliverToBoxAdapter(
            child: _ArtistStatus(
              key: ValueKey('artist-profile-loading'),
              child: CircularProgressIndicator(),
            ),
          )
        else if (profileFailed)
          SliverToBoxAdapter(
            child: _ArtistStatus(
              key: const ValueKey('artist-profile-error'),
              icon: Icons.cloud_off_rounded,
              message: strings.artistProfileLoadError,
              action: FilledButton.tonalIcon(
                onPressed: () =>
                    ref.invalidate(artistProfileProvider(_request)),
                icon: const Icon(Icons.refresh_rounded),
                label: Text(strings.retry),
              ),
            ),
          )
        else if (tracks.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _SectionTitle(
              key: const ValueKey('artist-popular-title'),
              title: strings.popularSongs,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            sliver: SliverList.separated(
              itemCount: tracks.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) {
                final track = tracks[index];
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: TrackResultTile(
                      key: ValueKey('artist-popular-${track.id}'),
                      track: track,
                      queue: tracks,
                      queueSourceId: 'artist:${widget.artistBrowseId}:popular',
                      onOpenPlayer: _returnToPlayer,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        if (profile.albums.isNotEmpty)
          SliverToBoxAdapter(
            child: _ReleaseShelf(
              key: const ValueKey('artist-albums-shelf'),
              title: strings.albums,
              releases: profile.albums,
              onOpen: _openRelease,
            ),
          ),
        if (profile.singles.isNotEmpty)
          SliverToBoxAdapter(
            child: _ReleaseShelf(
              key: const ValueKey('artist-singles-shelf'),
              title: strings.singles,
              releases: profile.singles,
              onOpen: _openRelease,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 30)),
      ],
    );
  }

  Future<void> _toggleSubscription(
    YouTubeMusicArtistAccount account,
    String channelId,
    bool currentlySubscribed,
    InnerTubeArtistProfile profile,
  ) async {
    if (_subscriptionBusy) return;
    setState(() => _subscriptionBusy = true);
    try {
      final result = currentlySubscribed
          ? await account.unsubscribeArtist(channelId)
          : await account.subscribeArtist(channelId);
      if (!mounted) return;
      if (result.isSuccess) {
        setState(() => _subscriptionOverride = !currentlySubscribed);
        final subscribedArtists = ref.read(subscribedArtistsProvider.notifier);
        if (currentlySubscribed) {
          subscribedArtists.recordUnsubscribed(
            artistBrowseId: widget.artistBrowseId,
            channelId: channelId,
          );
        } else {
          subscribedArtists.recordSubscribed(
            RemoteSubscribedArtist(
              browseId: widget.artistBrowseId,
              channelId: channelId,
              name: profile.artist.name,
              thumbnailUrl: profile.artist.thumbnailUrl,
            ),
          );
        }
        ref.invalidate(artistSubscriptionStateProvider(widget.artistBrowseId));
        return;
      }
      _showSubscriptionError();
    } on Object {
      if (mounted) _showSubscriptionError();
    } finally {
      if (mounted) setState(() => _subscriptionBusy = false);
    }
  }

  void _showSubscriptionError() {
    _showMessage(ref.read(appStringsProvider).artistSubscriptionFailed);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _playArtistQueue(
    InnerTubeArtistProfile profile,
    List<TrackInfo> visibleTracks,
  ) async {
    if (_popularPlaybackBusy || _radioBusy) return;
    setState(() => _popularPlaybackBusy = true);
    try {
      var queue = <TrackInfo>[];
      final playlistId = profile.playPlaylistId?.trim();
      final service = ref.read(youtubeMusicSearchProvider);
      if (playlistId?.isNotEmpty == true &&
          service is YouTubeMusicPlaylistQueueLookup) {
        try {
          final page = await (service as YouTubeMusicPlaylistQueueLookup)
              .getPlaylistNext(playlistId!, limit: 50);
          queue = _uniqueTracks(page.songs.map(trackInfoFromInnerTubeSong));
        } on Object catch (error) {
          // The advertised RDAO queue is the source used by YouTube Music's
          // artist Play action. Some regional/temporary responses can still
          // reject it, so keep the visible popular songs as a safe fallback.
          debugPrint(
            'Artist Play queue could not be loaded; using visible songs: '
            '$error',
          );
        }
      }
      if (queue.isEmpty) queue = _uniqueTracks(visibleTracks);
      if (queue.isEmpty || !mounted) {
        if (mounted) {
          _showMessage(ref.read(appStringsProvider).playbackError);
        }
        return;
      }
      final playback = ref
          .read(playerControllerProvider.notifier)
          .playRemote(
            queue.first,
            queue: queue,
            queueSourceId: 'artist:${widget.artistBrowseId}:play',
          );
      _returnToPlayer();
      await playback;
    } on Object {
      if (mounted) {
        _showMessage(ref.read(appStringsProvider).playbackError);
      }
    } finally {
      if (mounted) setState(() => _popularPlaybackBusy = false);
    }
  }

  Future<void> _startRadio(
    InnerTubeArtistProfile profile,
    List<TrackInfo> visibleTracks,
  ) async {
    if (_radioBusy || _popularPlaybackBusy) return;
    final fallbackSeed = widget.seedVideoId?.trim();
    final advertisedSeed = profile.radioSeedVideoId?.trim();
    final seedVideoId = advertisedSeed?.isNotEmpty == true
        ? advertisedSeed
        : visibleTracks.isNotEmpty
        ? visibleTracks.first.id
        : fallbackSeed;
    if (seedVideoId == null || seedVideoId.isEmpty) return;
    setState(() => _radioBusy = true);
    try {
      final service = ref.read(youtubeMusicSearchProvider);
      if (service is! YouTubeMusicRelated) {
        throw UnsupportedError('Artist radio is not available.');
      }
      final playlistId = profile.radioPlaylistId?.trim();
      final page =
          playlistId?.isNotEmpty == true &&
              service is YouTubeMusicPlaylistQueueLookup
          ? await (service as YouTubeMusicPlaylistQueueLookup).getPlaylistNext(
              playlistId!,
              videoId: seedVideoId,
              limit: 50,
            )
          : await (service as YouTubeMusicRelated).getNext(
              seedVideoId,
              radio: true,
              limit: 50,
            );
      final queue = page.songs
          .map(trackInfoFromInnerTubeSong)
          .toList(growable: false);
      if (queue.isEmpty) throw StateError('Artist radio is empty.');
      if (!mounted) return;
      final playback = ref
          .read(playerControllerProvider.notifier)
          .playRemote(
            queue.first,
            queue: queue,
            queueSourceId: 'artist:${widget.artistBrowseId}:radio',
          );
      _returnToPlayer();
      unawaited(playback);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(ref.read(appStringsProvider).artistMixLoadError),
          ),
        );
    } finally {
      if (mounted) setState(() => _radioBusy = false);
    }
  }

  List<TrackInfo> _uniqueTracks(Iterable<TrackInfo> tracks) {
    final seenIds = <String>{};
    return <TrackInfo>[
      for (final track in tracks)
        if (track.id.trim().isNotEmpty && seenIds.add(track.id)) track,
    ];
  }

  void _openRelease(InnerTubeAlbum release) {
    final strings = ref.read(appStringsProvider);
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RemoteCollectionDetailPage(
          title: release.title,
          subtitle: release.artist.trim().isEmpty
              ? widget.artistName
              : release.artist,
          artworkSource: release.thumbnailUrl,
          metadata: <String>[
            ?release.type?.trim().isEmpty == false ? release.type : null,
            ?release.year?.trim().isEmpty == false ? release.year : null,
          ],
          fallbackIcon: Icons.album_rounded,
          queueSourceId: 'artist:${widget.artistBrowseId}:${release.browseId}',
          tracksProvider: homeAlbumTracksProvider(release.browseId),
          emptyMessage: strings.albumWithoutSongs,
          errorMessage: strings.albumLoadError,
          onOpenPlayer: _returnToPlayer,
        ),
      ),
    );
  }

  void _returnToPlayer() {
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    widget.onOpenPlayer();
  }
}

class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({
    required this.profile,
    required this.radioLabel,
    required this.subscribeLabel,
    required this.playLabel,
    required this.showSubscription,
    required this.subscriptionBusy,
    required this.radioBusy,
    required this.playAllBusy,
    required this.canStartRadio,
    required this.canPlayAll,
    required this.subscribed,
    required this.onRadio,
    required this.onPlayAll,
    required this.onSubscription,
    this.subscriptionTooltip,
  });

  final InnerTubeArtistProfile profile;
  final String radioLabel;
  final String subscribeLabel;
  final String playLabel;
  final String? subscriptionTooltip;
  final bool showSubscription;
  final bool subscriptionBusy;
  final bool radioBusy;
  final bool playAllBusy;
  final bool canStartRadio;
  final bool canPlayAll;
  final bool subscribed;
  final VoidCallback onRadio;
  final VoidCallback onPlayAll;
  final VoidCallback onSubscription;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = profile.description?.trim();
    final subscriberCount = profile.subscriberCount?.trim();
    final monthlyListenerCount = profile.monthlyListenerCount?.trim();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 700;
              final artwork = ClipOval(
                key: const ValueKey('artist-profile-artwork'),
                child: SizedBox.square(
                  dimension: wide ? 216 : 176,
                  child: SourceImage(
                    source: profile.artist.thumbnailUrl,
                    cacheWidth: 640,
                    fit: BoxFit.cover,
                    fallback: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: Icon(
                        Icons.person_rounded,
                        size: wide ? 88 : 72,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              );
              final details = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: wide
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.center,
                children: [
                  Text(
                    key: const ValueKey('artist-profile-name'),
                    profile.artist.name,
                    textAlign: wide ? TextAlign.start : TextAlign.center,
                    style: theme.textTheme.headlineLarge?.copyWith(
                      color: AppColors.contentTitleFor(context),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  if (subscriberCount?.isNotEmpty == true ||
                      monthlyListenerCount?.isNotEmpty == true) ...[
                    const SizedBox(height: 5),
                    Column(
                      crossAxisAlignment: wide
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.center,
                      children: [
                        if (subscriberCount?.isNotEmpty == true)
                          Text(
                            key: const ValueKey('artist-subscriber-count'),
                            subscriberCount!,
                            textAlign: wide
                                ? TextAlign.start
                                : TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.contentSubtitleFor(context),
                            ),
                          ),
                        if (subscriberCount?.isNotEmpty == true &&
                            monthlyListenerCount?.isNotEmpty == true)
                          const SizedBox(height: 2),
                        if (monthlyListenerCount?.isNotEmpty == true)
                          Text(
                            key: const ValueKey(
                              'artist-monthly-listener-count',
                            ),
                            monthlyListenerCount!,
                            textAlign: wide
                                ? TextAlign.start
                                : TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.contentSubtitleFor(context),
                            ),
                          ),
                      ],
                    ),
                  ],
                  if (description != null && description.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      description,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      textAlign: wide ? TextAlign.start : TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: AppColors.contentSubtitleFor(context),
                        height: 1.4,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Wrap(
                          alignment: wide
                              ? WrapAlignment.start
                              : WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              key: const ValueKey('artist-mix'),
                              onPressed: canStartRadio && !radioBusy
                                  ? onRadio
                                  : null,
                              icon: radioBusy
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.radio_rounded),
                              label: Text(radioLabel),
                            ),
                            if (showSubscription)
                              Tooltip(
                                message: subscriptionTooltip ?? '',
                                child: FilledButton.tonalIcon(
                                  key: const ValueKey('artist-subscription'),
                                  onPressed: subscriptionBusy
                                      ? null
                                      : onSubscription,
                                  icon: subscriptionBusy
                                      ? const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : Icon(
                                          subscribed
                                              ? Icons
                                                    .notifications_active_rounded
                                              : Icons.add_rounded,
                                        ),
                                  label: Text(subscribeLabel),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox.square(
                        dimension: 54,
                        child: IconButton.filled(
                          key: const ValueKey('artist-play-all'),
                          tooltip: playLabel,
                          onPressed: canPlayAll && !playAllBusy
                              ? onPlayAll
                              : null,
                          icon: playAllBusy
                              ? const SizedBox.square(
                                  dimension: 21,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                  ),
                                )
                              : const Icon(Icons.play_arrow_rounded, size: 30),
                        ),
                      ),
                    ],
                  ),
                ],
              );
              if (!wide) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [artwork, const SizedBox(height: 16), details],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  artwork,
                  const SizedBox(width: 28),
                  Expanded(child: details),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 22, 18, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: AppColors.contentHeadingFor(context),
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReleaseShelf extends StatelessWidget {
  const _ReleaseShelf({
    required this.title,
    required this.releases,
    required this.onOpen,
    super.key,
  });

  final String title;
  final List<InnerTubeAlbum> releases;
  final ValueChanged<InnerTubeAlbum> onOpen;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final cardWidth = wide ? 176.0 : 148.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(title: title),
        SizedBox(
          height: wide ? 238 : 210,
          child: ListView.separated(
            scrollCacheExtent: const ScrollCacheExtent.pixels(760),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            scrollDirection: Axis.horizontal,
            itemCount: releases.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final release = releases[index];
              return _ReleaseCard(
                release: release,
                width: cardWidth,
                onTap: () => onOpen(release),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({
    required this.release,
    required this.width,
    required this.onTap,
  });

  final InnerTubeAlbum release;
  final double width;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      key: ValueKey('artist-release-${release.browseId}'),
      width: width,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(appCardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(appArtworkRadius),
                  child: SizedBox.square(
                    dimension: width - 8,
                    child: SourceImage(
                      source: release.thumbnailUrl,
                      cacheWidth: 512,
                      fit: BoxFit.cover,
                      fallback: ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.album_rounded, size: 46),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  release.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  <String>[
                    ?release.type?.trim().isEmpty == false
                        ? release.type!.trim()
                        : null,
                    ?release.year?.trim().isEmpty == false
                        ? release.year!.trim()
                        : null,
                  ].join(' \u2022 '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.contentSubtitleFor(context),
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

class _ArtistStatus extends StatelessWidget {
  const _ArtistStatus({
    super.key,
    this.icon,
    this.message,
    this.action,
    this.child,
  });

  final IconData? icon;
  final String? message;
  final Widget? action;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child:
            child ??
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 54),
                const SizedBox(height: 14),
                Text(message ?? '', textAlign: TextAlign.center),
                if (action != null) ...[const SizedBox(height: 16), action!],
              ],
            ),
      ),
    );
  }
}

bool _isSingleRelease(InnerTubeAlbum release) {
  final type = release.type?.trim().toLowerCase() ?? '';
  return type == 'single' || type == 'sencillo' || type == 'ep';
}

final RegExp _youtubeChannelIdPattern = RegExp(r'^UC[A-Za-z0-9_-]+$');

String? _firstYouTubeChannelId(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final normalized = candidate?.trim();
    if (normalized != null && _youtubeChannelIdPattern.hasMatch(normalized)) {
      return normalized;
    }
  }
  return null;
}
