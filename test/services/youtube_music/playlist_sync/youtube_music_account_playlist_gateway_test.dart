import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart'
    as account;
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/youtube_music_account_playlist_gateway.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/youtube_music_playlist_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('YouTubeMusicAccountPlaylistGateway reads', () {
    test('maps catalog metadata, privacy and duplicate occurrences', () async {
      final accountGateway = _FakeAccountGateway()
        ..savedPlaylists = account.RemotePlaylistCollection(
          playlists: const <account.RemotePlaylistSummary>[
            account.RemotePlaylistSummary(
              playlistId: 'PL-road',
              title: 'Road trip',
              visibility: account.RemotePlaylistVisibility.private,
              isEditable: false,
            ),
          ],
          termination: account.RemotePaginationTermination.exhausted,
          pagesFetched: 1,
        )
        ..playlistReads.add(
          _remoteSnapshot(
            title: 'Road trip',
            entries: <account.RemotePlaylistEntry>[
              _remoteEntry(position: 0, setVideoId: 'set-one'),
              _remoteEntry(position: 1, setVideoId: 'set-two'),
            ],
          ),
        );
      final gateway = _adapter(accountGateway);

      final summaries = await gateway.listRemotePlaylists(
        accountKey: _accountKey,
      );
      final snapshot = await gateway.fetchPlaylist(
        accountKey: _accountKey,
        remotePlaylistId: 'VLPL-road',
      );

      expect(summaries, hasLength(2));
      final road = summaries.singleWhere(
        (summary) => summary.remotePlaylistId == 'PL-road',
      );
      expect(road.remoteBrowseId, 'VLPL-road');
      expect(road.privacy, 'PRIVATE');
      expect(road.isEditable, isTrue);
      expect(snapshot, isNotNull);
      expect(snapshot!.items, hasLength(2));
      expect(snapshot.items.map((item) => item.videoId), const <String?>[
        'same-video',
        'same-video',
      ]);
      expect(snapshot.items.map((item) => item.setVideoId), const <String?>[
        'set-one',
        'set-two',
      ]);
      final track = snapshot.items.first.track;
      expect(track.key, 'youtube:same-video');
      expect(track.title, 'Repeated song');
      expect(track.artists, const <String>['Artist']);
      expect(track.artistBrowseIds, const <String?>['UC-artist']);
      expect(track.album, 'Album');
      expect(track.duration, const Duration(minutes: 3, seconds: 7));
      expect(track.thumbnailUrl, 'https://img.test/song.jpg');
      expect(track.sourceUrl, 'https://music.youtube.com/watch?v=same-video');
    });

    test('exposes Liked Music once and excludes Episodes for later', () async {
      final accountGateway = _FakeAccountGateway()
        ..savedPlaylists = account.RemotePlaylistCollection(
          playlists: const <account.RemotePlaylistSummary>[
            account.RemotePlaylistSummary(
              playlistId: 'LM',
              title: 'Liked Music',
            ),
            account.RemotePlaylistSummary(
              playlistId: 'VLLM',
              title: 'Liked Music browse form',
            ),
            account.RemotePlaylistSummary(
              playlistId: 'EPISODES_LATER',
              title: 'Episodios para después',
            ),
            account.RemotePlaylistSummary(
              playlistId: 'PL-road',
              title: 'Road trip',
            ),
          ],
          termination: account.RemotePaginationTermination.exhausted,
          pagesFetched: 1,
        );

      final summaries = await _adapter(
        accountGateway,
      ).listRemotePlaylists(accountKey: _accountKey);

      expect(
        summaries.map((summary) => summary.remotePlaylistId),
        const <String>['LM', 'PL-road'],
      );
      expect(summaries.first.isLikedMusic, isTrue);
    });

    test(
      'discovers canonical Liked Music when the saved shelf omits it',
      () async {
        final accountGateway = _FakeAccountGateway()
          ..savedPlaylists = account.RemotePlaylistCollection(
            playlists: const <account.RemotePlaylistSummary>[],
            termination: account.RemotePaginationTermination.exhausted,
            pagesFetched: 1,
          );

        final summaries = await _adapter(
          accountGateway,
        ).listRemotePlaylists(accountKey: _accountKey);

        expect(summaries, hasLength(1));
        expect(summaries.single.remotePlaylistId, 'LM');
        expect(summaries.single.remoteBrowseId, 'VLLM');
        expect(summaries.single.isLikedMusic, isTrue);
      },
    );

    test(
      'refuses incomplete account pages instead of syncing partial data',
      () async {
        final accountGateway = _FakeAccountGateway()
          ..savedPlaylists = account.RemotePlaylistCollection(
            playlists: const <account.RemotePlaylistSummary>[],
            termination: account.RemotePaginationTermination.pageLimit,
            pagesFetched: 40,
          );
        final gateway = _adapter(accountGateway);

        await expectLater(
          gateway.listRemotePlaylists(accountKey: _accountKey),
          throwsA(isA<PlaylistGatewayUnavailableException>()),
        );
      },
    );

    test('maps an explicit missing playlist response to null', () async {
      final accountGateway = _FakeAccountGateway()..playlistStatusCode = 404;

      final snapshot = await _adapter(
        accountGateway,
      ).fetchPlaylist(accountKey: _accountKey, remotePlaylistId: 'PL-deleted');

      expect(snapshot, isNull);
      expect(accountGateway.getPlaylistCalls, 1);
    });

    test(
      'preserves an unavailable occurrence without inventing a video id',
      () async {
        final accountGateway = _FakeAccountGateway()
          ..playlistReads.add(
            _remoteSnapshot(
              isEditable: false,
              visibility: account.RemotePlaylistVisibility.public,
              entries: <account.RemotePlaylistEntry>[
                account.RemotePlaylistEntry(
                  position: 0,
                  setVideoId: 'set-unavailable',
                  title: 'Unavailable song',
                  artists: const <String>['Artist'],
                  isAvailable: false,
                ),
              ],
            ),
          );

        final snapshot = await _adapter(
          accountGateway,
        ).fetchPlaylist(accountKey: _accountKey, remotePlaylistId: 'PL-list');

        expect(snapshot, isNotNull);
        expect(snapshot!.isEditable, isFalse);
        expect(snapshot.privacy, 'PUBLIC');
        expect(snapshot.items.single.videoId, isNull);
        expect(snapshot.items.single.setVideoId, 'set-unavailable');
        expect(snapshot.items.single.track.provider, CatalogProvider.legacy);
        expect(
          snapshot.items.single.track.key,
          'youtube-unavailable:PL-list:set-unavailable',
        );
      },
    );

    test('rejects a queued job from a different account identity', () async {
      final gateway = _adapter(_FakeAccountGateway());

      await expectLater(
        gateway.listRemotePlaylists(accountKey: 'another-channel'),
        throwsA(isA<PlaylistGatewayUnavailableException>()),
      );
    });
  });

  group('YouTubeMusicAccountPlaylistGateway mutations', () {
    test('creates duplicates once and maps requested visibility', () async {
      final accountGateway = _FakeAccountGateway()
        ..createResult =
            const account.YouTubeMusicMutationSuccess<
              account.RemotePlaylistCreated
            >(account.RemotePlaylistCreated(playlistId: 'PL-created'));
      final desired = PlaylistSyncSnapshot(
        title: 'Viaje',
        items: <PlaylistSyncItem>[
          _syncItem(videoId: 'same-video'),
          _syncItem(videoId: 'same-video'),
        ],
        privacy: 'UNLISTED',
      );

      final receipt = await _adapter(accountGateway).createPlaylist(
        accountKey: _accountKey,
        desired: desired,
        mutationToken: 'one-shot-token',
      );

      expect(receipt.status, RemoteMutationStatus.acknowledged);
      expect(receipt.remotePlaylistId, 'PL-created');
      expect(accountGateway.createCalls, 1);
      expect(accountGateway.createdTitles, const <String>['Viaje']);
      expect(
        accountGateway.createdVisibilities,
        const <account.RemotePlaylistVisibility>[
          account.RemotePlaylistVisibility.unlisted,
        ],
      );
      expect(accountGateway.createdVideoIds.single, const <String>[
        'same-video',
        'same-video',
      ]);
    });

    test(
      'Liked Music uses account like endpoints, not playlist edits',
      () async {
        final accountGateway = _FakeAccountGateway();
        final gateway = _adapter(accountGateway);
        final observed = PlaylistSyncSnapshot(
          remotePlaylistId: 'LM',
          title: 'Liked Music',
          items: <PlaylistSyncItem>[_syncItem(videoId: 'video-a')],
        );
        final desired = PlaylistSyncSnapshot(
          remotePlaylistId: 'LM',
          title: 'Favoritos',
          items: <PlaylistSyncItem>[_syncItem(videoId: 'video-b')],
        );

        final receipt = await gateway.applyLikedMusicState(
          accountKey: _accountKey,
          observed: observed,
          desired: desired,
          mutationToken: 'like-token',
        );

        expect(receipt.status, RemoteMutationStatus.acknowledged);
        expect(accountGateway.removedLikeVideoIds, <String>['video-a']);
        expect(accountGateway.likedVideoIds, <String>['video-b']);
        expect(accountGateway.addedVideoIds, isEmpty);
        expect(accountGateway.removedSetVideoIds, isEmpty);
      },
    );

    test(
      'preserves a created remote ID when the session changes after ACK',
      () async {
        final accountGateway = _FakeAccountGateway()
          ..createResult =
              const account.YouTubeMusicMutationSuccess<
                account.RemotePlaylistCreated
              >(account.RemotePlaylistCreated(playlistId: 'PL-created'));
        var generationChecks = 0;
        final gateway = YouTubeMusicAccountPlaylistGateway(
          accountGateway: accountGateway,
          accountKey: _accountKey,
          isSessionCurrent: () => ++generationChecks <= 1,
        );

        final receipt = await gateway.createPlaylist(
          accountKey: _accountKey,
          desired: _syncSnapshot(const <PlaylistSyncItem>[]),
          mutationToken: 'one-shot-token',
        );

        expect(receipt.status, RemoteMutationStatus.ambiguous);
        expect(receipt.remotePlaylistId, 'PL-created');
        expect(accountGateway.createCalls, 1);
        expect(generationChecks, 2);
      },
    );

    test(
      'reads back new setVideoIds before reordering a new duplicate',
      () async {
        final accountGateway = _FakeAccountGateway()
          ..playlistReads.add(
            _remoteSnapshot(
              entries: <account.RemotePlaylistEntry>[
                _remoteEntry(
                  position: 0,
                  videoId: 'video-a',
                  setVideoId: 'set-a',
                ),
                _remoteEntry(
                  position: 1,
                  videoId: 'video-b',
                  setVideoId: 'set-b',
                ),
                _remoteEntry(
                  position: 2,
                  videoId: 'video-a',
                  setVideoId: 'set-a-new',
                ),
              ],
            ),
          );
        final observed = _syncSnapshot(<PlaylistSyncItem>[
          _syncItem(videoId: 'video-a', setVideoId: 'set-a'),
          _syncItem(videoId: 'video-b', setVideoId: 'set-b'),
        ]);
        final desired = _syncSnapshot(<PlaylistSyncItem>[
          _syncItem(videoId: 'video-b', setVideoId: 'set-b'),
          _syncItem(videoId: 'video-a', setVideoId: 'set-a'),
          _syncItem(videoId: 'video-a'),
        ]);

        final receipt = await _adapter(accountGateway).applyDesiredState(
          accountKey: _accountKey,
          observed: observed,
          desired: desired,
          mutationToken: 'one-shot-token',
        );

        expect(receipt.status, RemoteMutationStatus.acknowledged);
        expect(accountGateway.addedVideoIds, const <String>['video-a']);
        expect(accountGateway.getPlaylistCalls, 1);
        expect(accountGateway.moves, const <_Move>[
          _Move(setVideoId: 'set-b', successorSetVideoId: 'set-a'),
        ]);
      },
    );

    test('removes only the selected duplicate occurrence', () async {
      final accountGateway = _FakeAccountGateway()
        ..playlistReads.add(
          _remoteSnapshot(
            entries: <account.RemotePlaylistEntry>[
              _remoteEntry(position: 0, setVideoId: 'set-keep'),
            ],
          ),
        );
      final observed = _syncSnapshot(<PlaylistSyncItem>[
        _syncItem(videoId: 'same-video', setVideoId: 'set-remove'),
        _syncItem(videoId: 'same-video', setVideoId: 'set-keep'),
      ]);
      final desired = _syncSnapshot(<PlaylistSyncItem>[
        _syncItem(videoId: 'same-video', setVideoId: 'set-keep'),
      ]);

      final receipt = await _adapter(accountGateway).applyDesiredState(
        accountKey: _accountKey,
        observed: observed,
        desired: desired,
        mutationToken: 'one-shot-token',
      );

      expect(
        receipt.status,
        RemoteMutationStatus.acknowledged,
        reason: receipt.message,
      );
      expect(accountGateway.removedSetVideoIds, const <String>['set-remove']);
      expect(accountGateway.addedVideoIds, isEmpty);
    });

    test('does not retry or continue after an ambiguous write', () async {
      final accountGateway = _FakeAccountGateway()
        ..addResults.add(
          const account.YouTubeMusicMutationAmbiguous<
            account.RemotePlaylistMutationApplied
          >(operation: 'addPlaylistEntry', reason: 'uncertain delivery'),
        );
      final desired = _syncSnapshot(<PlaylistSyncItem>[
        _syncItem(videoId: 'video-a'),
      ]);

      final receipt = await _adapter(accountGateway).applyDesiredState(
        accountKey: _accountKey,
        observed: _syncSnapshot(const <PlaylistSyncItem>[]),
        desired: desired,
        mutationToken: 'one-shot-token',
      );

      expect(receipt.status, RemoteMutationStatus.ambiguous);
      expect(accountGateway.addedVideoIds, const <String>['video-a']);
      expect(accountGateway.getPlaylistCalls, 0);
      expect(accountGateway.moves, isEmpty);
    });

    test('expires auth only for an explicit 401 or 403 result', () async {
      final accountGateway = _FakeAccountGateway()
        ..addResults.add(
          const account.YouTubeMusicMutationFailure<
            account.RemotePlaylistMutationApplied
          >(
            operation: 'addPlaylistEntry',
            reason: 'session expired',
            statusCode: 401,
          ),
        );
      var expirationNotifications = 0;
      final gateway = YouTubeMusicAccountPlaylistGateway(
        accountGateway: accountGateway,
        accountKey: _accountKey,
        onAuthenticationExpired: () => expirationNotifications += 1,
      );

      final receipt = await gateway.applyDesiredState(
        accountKey: _accountKey,
        observed: _syncSnapshot(const <PlaylistSyncItem>[]),
        desired: _syncSnapshot(<PlaylistSyncItem>[
          _syncItem(videoId: 'video-a'),
        ]),
        mutationToken: 'one-shot-token',
      );

      expect(receipt.status, RemoteMutationStatus.rejected);
      expect(expirationNotifications, 1);
      expect(accountGateway.addedVideoIds, const <String>['video-a']);
    });

    test('checks the immutable auth generation before every write', () async {
      final accountGateway = _FakeAccountGateway();
      var generationChecks = 0;
      final gateway = YouTubeMusicAccountPlaylistGateway(
        accountGateway: accountGateway,
        accountKey: _accountKey,
        isSessionCurrent: () => ++generationChecks <= 2,
      );

      await expectLater(
        gateway.applyDesiredState(
          accountKey: _accountKey,
          observed: _syncSnapshot(const <PlaylistSyncItem>[]),
          desired: _syncSnapshot(<PlaylistSyncItem>[
            _syncItem(videoId: 'video-a'),
            _syncItem(videoId: 'video-b'),
          ]),
          mutationToken: 'one-shot-token',
        ),
        throwsA(isA<PlaylistGatewayUnavailableException>()),
      );

      expect(accountGateway.addedVideoIds, const <String>['video-a']);
      expect(generationChecks, 3);
    });

    test('reports a partial acknowledged sequence as ambiguous', () async {
      final accountGateway = _FakeAccountGateway()
        ..addResults.addAll(<
          account.YouTubeMusicMutationResult<
            account.RemotePlaylistMutationApplied
          >
        >[
          const account.YouTubeMusicMutationSuccess<
            account.RemotePlaylistMutationApplied
          >(account.RemotePlaylistMutationApplied()),
          const account.YouTubeMusicMutationFailure<
            account.RemotePlaylistMutationApplied
          >(operation: 'addPlaylistEntry', reason: 'definitely rejected'),
        ]);
      final desired = _syncSnapshot(<PlaylistSyncItem>[
        _syncItem(videoId: 'video-a'),
        _syncItem(videoId: 'video-b'),
      ]);

      final receipt = await _adapter(accountGateway).applyDesiredState(
        accountKey: _accountKey,
        observed: _syncSnapshot(const <PlaylistSyncItem>[]),
        desired: desired,
        mutationToken: 'one-shot-token',
      );

      expect(receipt.status, RemoteMutationStatus.ambiguous);
      expect(accountGateway.addedVideoIds, const <String>[
        'video-a',
        'video-b',
      ]);
      expect(accountGateway.getPlaylistCalls, 0);
    });

    test(
      'never adds again when acknowledged changes are not visible yet',
      () async {
        final accountGateway = _FakeAccountGateway()
          ..playlistReads.add(_remoteSnapshot(entries: const []));
        final desired = _syncSnapshot(<PlaylistSyncItem>[
          _syncItem(videoId: 'video-a'),
        ]);

        final receipt = await _adapter(accountGateway).applyDesiredState(
          accountKey: _accountKey,
          observed: _syncSnapshot(const <PlaylistSyncItem>[]),
          desired: desired,
          mutationToken: 'one-shot-token',
        );

        expect(receipt.status, RemoteMutationStatus.ambiguous);
        expect(accountGateway.addedVideoIds, const <String>['video-a']);
        expect(accountGateway.getPlaylistCalls, 1);
        expect(accountGateway.moves, isEmpty);
      },
    );
  });
}

const String _accountKey = 'channel:UC-main';

YouTubeMusicAccountPlaylistGateway _adapter(
  _FakeAccountGateway accountGateway,
) => YouTubeMusicAccountPlaylistGateway(
  accountGateway: accountGateway,
  accountKey: _accountKey,
);

account.RemotePlaylistSnapshot _remoteSnapshot({
  String title = 'Playlist',
  List<account.RemotePlaylistEntry> entries = const [],
  account.RemotePaginationTermination termination =
      account.RemotePaginationTermination.exhausted,
  account.RemotePlaylistVisibility visibility =
      account.RemotePlaylistVisibility.private,
  bool isEditable = true,
}) => account.RemotePlaylistSnapshot(
  playlistId: 'PL-list',
  summary: account.RemotePlaylistSummary(
    playlistId: 'PL-list',
    title: title,
    visibility: visibility,
    isEditable: isEditable,
  ),
  entries: entries,
  termination: termination,
  pagesFetched: 1,
);

account.RemotePlaylistEntry _remoteEntry({
  required int position,
  String videoId = 'same-video',
  required String setVideoId,
}) => account.RemotePlaylistEntry(
  position: position,
  videoId: videoId,
  setVideoId: setVideoId,
  title: 'Repeated song',
  artists: const <String>['Artist'],
  artistBrowseIds: const <String?>['UC-artist'],
  album: 'Album',
  duration: const Duration(minutes: 3, seconds: 7),
  thumbnailUrl: 'https://img.test/song.jpg',
);

PlaylistSyncSnapshot _syncSnapshot(List<PlaylistSyncItem> items) =>
    PlaylistSyncSnapshot(
      remotePlaylistId: 'PL-list',
      title: 'Playlist',
      items: items,
      isEditable: true,
      privacy: 'PRIVATE',
    );

PlaylistSyncItem _syncItem({required String videoId, String? setVideoId}) =>
    PlaylistSyncItem(
      videoId: videoId,
      setVideoId: setVideoId,
      track: CatalogTrack.youtube(
        videoId: videoId,
        title: videoId,
        artists: const <String>['Artist'],
      ),
    );

final class _Move {
  const _Move({required this.setVideoId, this.successorSetVideoId});

  final String setVideoId;
  final String? successorSetVideoId;

  @override
  bool operator ==(Object other) =>
      other is _Move &&
      setVideoId == other.setVideoId &&
      successorSetVideoId == other.successorSetVideoId;

  @override
  int get hashCode => Object.hash(setVideoId, successorSetVideoId);
}

final class _FakeAccountGateway implements account.YouTubeMusicAccountGateway {
  account.RemotePlaylistCollection savedPlaylists =
      account.RemotePlaylistCollection(
        playlists: const <account.RemotePlaylistSummary>[],
        termination: account.RemotePaginationTermination.exhausted,
        pagesFetched: 1,
      );
  final List<account.RemotePlaylistSnapshot> playlistReads =
      <account.RemotePlaylistSnapshot>[];
  int? playlistStatusCode;
  int getPlaylistCalls = 0;

  account.YouTubeMusicMutationResult<account.RemotePlaylistCreated>
  createResult =
      const account.YouTubeMusicMutationFailure<account.RemotePlaylistCreated>(
        operation: 'createPlaylist',
        reason: 'not configured',
      );
  int createCalls = 0;
  final List<String> createdTitles = <String>[];
  final List<account.RemotePlaylistVisibility> createdVisibilities =
      <account.RemotePlaylistVisibility>[];
  final List<List<String>> createdVideoIds = <List<String>>[];

  final List<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  addResults =
      <
        account.YouTubeMusicMutationResult<
          account.RemotePlaylistMutationApplied
        >
      >[];
  final List<String> addedVideoIds = <String>[];
  final List<String> likedVideoIds = <String>[];
  final List<String> removedLikeVideoIds = <String>[];
  final List<String> removedSetVideoIds = <String>[];
  final List<_Move> moves = <_Move>[];
  final List<String> renamedTitles = <String>[];

  @override
  Future<account.RemotePlaylistCollection> getSavedPlaylists() async =>
      savedPlaylists;

  @override
  Future<account.RemoteSubscribedArtistCollection>
  getSubscribedArtists() async => account.RemoteSubscribedArtistCollection(
    artists: const <account.RemoteSubscribedArtist>[],
    termination: account.RemotePaginationTermination.exhausted,
    pagesFetched: 1,
  );

  @override
  Future<account.RemotePlaylistSnapshot> getPlaylist(String playlistId) async {
    getPlaylistCalls += 1;
    final statusCode = playlistStatusCode;
    if (statusCode != null) {
      throw account.YouTubeMusicAccountException(
        'read failed',
        statusCode: statusCode,
      );
    }
    if (playlistReads.isEmpty) {
      throw StateError('No playlist read fixture remains.');
    }
    return playlistReads.removeAt(0);
  }

  @override
  Future<account.YouTubeMusicMutationResult<account.RemotePlaylistCreated>>
  createPlaylist(
    String title, {
    account.RemotePlaylistVisibility visibility =
        account.RemotePlaylistVisibility.private,
    List<String> initialVideoIds = const <String>[],
  }) async {
    createCalls += 1;
    createdTitles.add(title);
    createdVisibilities.add(visibility);
    createdVideoIds.add(List<String>.of(initialVideoIds));
    return createResult;
  }

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  addPlaylistEntry({
    required String playlistId,
    required String videoId,
  }) async {
    addedVideoIds.add(videoId);
    if (addResults.isNotEmpty) {
      return addResults.removeAt(0);
    }
    return const account.YouTubeMusicMutationSuccess<
      account.RemotePlaylistMutationApplied
    >(account.RemotePlaylistMutationApplied());
  }

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  removePlaylistEntry({
    required String playlistId,
    required account.RemotePlaylistEntry entry,
  }) async {
    removedSetVideoIds.add(entry.setVideoId!);
    return const account.YouTubeMusicMutationSuccess<
      account.RemotePlaylistMutationApplied
    >(account.RemotePlaylistMutationApplied());
  }

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  likeVideo(String videoId) async {
    likedVideoIds.add(videoId);
    return const account.YouTubeMusicMutationSuccess<
      account.RemotePlaylistMutationApplied
    >(account.RemotePlaylistMutationApplied());
  }

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  removeLike(String videoId) async {
    removedLikeVideoIds.add(videoId);
    return const account.YouTubeMusicMutationSuccess<
      account.RemotePlaylistMutationApplied
    >(account.RemotePlaylistMutationApplied());
  }

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  movePlaylistEntry({
    required String playlistId,
    required String setVideoId,
    String? successorSetVideoId,
  }) async {
    moves.add(
      _Move(setVideoId: setVideoId, successorSetVideoId: successorSetVideoId),
    );
    return const account.YouTubeMusicMutationSuccess<
      account.RemotePlaylistMutationApplied
    >(account.RemotePlaylistMutationApplied());
  }

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  renamePlaylist({required String playlistId, required String title}) async {
    renamedTitles.add(title);
    return const account.YouTubeMusicMutationSuccess<
      account.RemotePlaylistMutationApplied
    >(account.RemotePlaylistMutationApplied());
  }

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  setPlaylistDescription({
    required String playlistId,
    required String description,
  }) async =>
      const account.YouTubeMusicMutationSuccess<
        account.RemotePlaylistMutationApplied
      >(account.RemotePlaylistMutationApplied());

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  deletePlaylist(String playlistId) async =>
      const account.YouTubeMusicMutationSuccess<
        account.RemotePlaylistMutationApplied
      >(account.RemotePlaylistMutationApplied());

  @override
  Future<account.RemoteAccountProfile?> getProfile() async => null;

  @override
  Future<Object?> readMusicHomePage({String? continuation}) async =>
      const <String, Object?>{};

  @override
  Future<account.RemoteAccountDirectory> getAccounts() async =>
      account.RemoteAccountDirectory();

  @override
  Future<account.RemoteArtistSubscriptionState?> getArtistSubscriptionState(
    String artistBrowseId,
  ) async => null;

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  subscribeArtist(String channelId) async =>
      const account.YouTubeMusicMutationSuccess<
        account.RemotePlaylistMutationApplied
      >(account.RemotePlaylistMutationApplied());

  @override
  Future<
    account.YouTubeMusicMutationResult<account.RemotePlaylistMutationApplied>
  >
  unsubscribeArtist(String channelId) async =>
      const account.YouTubeMusicMutationSuccess<
        account.RemotePlaylistMutationApplied
      >(account.RemotePlaylistMutationApplied());
}
