import 'package:bstream_music/features/music/domain/entities/catalog_track.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_engine.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_store.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_three_way_merger.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/youtube_music_playlist_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PlaylistThreeWayMerger', () {
    var nextId = 0;
    late PlaylistThreeWayMerger merger;
    setUp(() {
      nextId = 0;
      merger = PlaylistThreeWayMerger(itemIdFactory: () => 'new-${nextId++}');
    });

    test('initial union preserves duplicates without doubling overlap', () {
      final local = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'local-a1'),
        _item('A', localId: 'local-a2'),
      ]);
      final remote = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'set-a1'),
      ]);

      final result = merger.merge(base: null, local: local, remote: remote);

      expect(result.hasConflicts, isFalse);
      expect(result.snapshot!.items, hasLength(2));
      expect(result.snapshot!.items.map((item) => item.localItemId), <String?>[
        'local-a1',
        'local-a2',
      ]);
      expect(result.snapshot!.items.first.setVideoId, 'set-a1');
    });

    test(
      'deletion wins over reorder and additions from both sides survive',
      () {
        final base = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
          _item('B', localId: 'b', setId: 'sb'),
        ]);
        final local = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
          _item('L', localId: 'l'),
        ]);
        final remote = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'sa'),
          _item('B', setId: 'sb'),
          _item('R', setId: 'sr'),
        ]);

        final merged = merger.merge(base: base, local: local, remote: remote);

        expect(merged.hasConflicts, isFalse);
        expect(
          merged.snapshot!.items.map((item) => item.videoId).toSet(),
          <String>{_video('A'), _video('L'), _video('R')},
        );
        expect(
          merged.snapshot!.items.map((item) => item.videoId),
          isNot(contains(_video('B'))),
        );
      },
    );

    test('same-video duplicates are deleted by occurrence identity', () {
      final base = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'a1', setId: 'set-1'),
        _item('A', localId: 'a2', setId: 'set-2'),
      ]);
      final local = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'a2', setId: 'set-2'),
      ]);
      final remote = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'set-1'),
        _item('A', setId: 'set-2'),
      ]);

      final merged = merger.merge(base: base, local: local, remote: remote);

      expect(merged.snapshot!.items, hasLength(1));
      expect(merged.snapshot!.items.single.localItemId, 'a2');
      expect(merged.snapshot!.items.single.setVideoId, 'set-2');
    });

    test('reports incompatible title and order changes', () {
      final base = _snapshot('Base', <PlaylistSyncItem>[
        _item('A', localId: 'a', setId: 'sa'),
        _item('B', localId: 'b', setId: 'sb'),
        _item('C', localId: 'c', setId: 'sc'),
      ]);
      final local = _snapshot('Local', <PlaylistSyncItem>[
        _item('B', localId: 'b'),
        _item('A', localId: 'a'),
        _item('C', localId: 'c'),
      ]);
      final remote = _snapshot('Remote', <PlaylistSyncItem>[
        _item('A', setId: 'sa'),
        _item('C', setId: 'sc'),
        _item('B', setId: 'sb'),
      ]);

      final result = merger.merge(base: base, local: local, remote: remote);

      expect(
        result.conflicts.map((conflict) => conflict.kind),
        containsAll(<PlaylistSyncConflictKind>{
          PlaylistSyncConflictKind.title,
          PlaylistSyncConflictKind.order,
        }),
      );
    });

    test('local-only entries remain local and outside remote projection', () {
      final localOnly = PlaylistSyncItem(
        localItemId: 'local-file',
        localTrackId: 'download',
        track: CatalogTrack.local(localTrackId: 'download', title: 'File'),
      );
      final merged = merger.merge(
        base: _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
        ]),
        local: _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a'),
          localOnly,
        ]),
        remote: _snapshot('Road', <PlaylistSyncItem>[_item('A', setId: 'sa')]),
      );

      expect(merged.snapshot!.items, contains(localOnly));
      expect(merged.snapshot!.remoteProjection.items, hasLength(1));
    });
  });

  group('PlaylistSyncEngine', () {
    final now = DateTime.utc(2026, 8, 22, 12);

    test('offline fetch is deferred without a mutation', () async {
      final store = _MemoryStore(_work());
      final gateway = _FakeGateway()..fetchError = const _Offline();
      final engine = _engine(store, gateway, now);

      final result = await engine.sync(store.work.binding.key);

      expect(result.disposition, PlaylistSyncDisposition.deferred);
      expect(gateway.mutationCount, 0);
      expect(store.work.intent?.status, PlaylistSyncIntentStatus.pending);
    });

    test(
      'a stale create ACK keeps its remote ID and freezes the write',
      () async {
        final initial = _work();
        final store = _MemoryStore(
          PlaylistSyncWork(
            binding: initial.binding.copyWith(remotePlaylistId: null),
            base: null,
            local: initial.local,
            localRevision: initial.localRevision,
            localDeleted: false,
            intent: initial.intent,
          ),
        );
        var sessionIsCurrent = true;
        final gateway = _FakeGateway()
          ..mutationReceipt = const RemoteMutationReceipt(
            status: RemoteMutationStatus.ambiguous,
            remotePlaylistId: 'created-before-switch',
          )
          ..onCreate = () => sessionIsCurrent = false;

        final result = await _engine(
          store,
          gateway,
          now,
          canPersist: () => sessionIsCurrent,
        ).sync(store.work.binding.key);

        expect(result.disposition, PlaylistSyncDisposition.deferred);
        expect(gateway.mutationCount, 1);
        expect(store.work.binding.remotePlaylistId, 'created-before-switch');
        expect(store.work.intent?.status, PlaylistSyncIntentStatus.ambiguous);
        expect(store.work.intent?.mutationToken, isNotEmpty);
      },
    );

    test('automatic sync respects a pending intent backoff', () async {
      final initial = _work();
      final store = _MemoryStore(
        PlaylistSyncWork(
          binding: initial.binding,
          base: initial.base,
          local: initial.local,
          localRevision: initial.localRevision,
          localDeleted: false,
          intent: PlaylistSyncIntent(
            key: initial.binding.key,
            requestedLocalRevision: initial.localRevision,
            reason: 'offline',
            status: PlaylistSyncIntentStatus.pending,
            attemptCount: 2,
            nextAttemptAt: now.add(const Duration(minutes: 1)),
            createdAt: now,
            updatedAt: now,
          ),
        ),
      );
      final gateway = _FakeGateway()..fetchError = const _Offline();

      final result = await _engine(
        store,
        gateway,
        now,
      ).sync(store.work.binding.key, trigger: PlaylistSyncTrigger.automatic);

      expect(result.disposition, PlaylistSyncDisposition.deferred);
      expect(store.work.intent!.attemptCount, 2);
      expect(gateway.mutationCount, 0);
    });

    test('ambiguous write commits only after successful read-back', () async {
      final base = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'a', setId: 'sa'),
      ]);
      final local = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'a', setId: 'sa'),
        _item('B', localId: 'b'),
      ]);
      final before = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'sa'),
      ]);
      final after = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'sa'),
        _item('B', setId: 'sb'),
      ]);
      final store = _MemoryStore(_work(base: base, local: local));
      final gateway = _FakeGateway()
        ..fetches.addAll(<PlaylistSyncSnapshot?>[before, after])
        ..mutationReceipt = const RemoteMutationReceipt(
          status: RemoteMutationStatus.ambiguous,
        );

      final result = await _engine(
        store,
        gateway,
        now,
      ).sync(store.work.binding.key);

      expect(result.disposition, PlaylistSyncDisposition.synchronized);
      expect(gateway.mutationCount, 1);
      expect(store.commits, 1);
      expect(store.work.intent, isNull);
    });

    test('unverified ambiguous write is never blindly retried', () async {
      final base = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'a', setId: 'sa'),
      ]);
      final local = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'a', setId: 'sa'),
        _item('B', localId: 'b'),
      ]);
      final unchanged = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'sa'),
      ]);
      final store = _MemoryStore(_work(base: base, local: local));
      final gateway = _FakeGateway()
        ..fetches.addAll(<PlaylistSyncSnapshot?>[
          unchanged,
          unchanged,
          unchanged,
        ])
        ..mutationReceipt = const RemoteMutationReceipt(
          status: RemoteMutationStatus.ambiguous,
        );
      final engine = _engine(store, gateway, now);

      expect(
        (await engine.sync(store.work.binding.key)).disposition,
        PlaylistSyncDisposition.deferred,
      );
      expect(store.work.intent?.status, PlaylistSyncIntentStatus.ambiguous);
      expect(
        (await engine.sync(store.work.binding.key)).disposition,
        PlaylistSyncDisposition.conflict,
      );
      expect(store.work.intent?.status, PlaylistSyncIntentStatus.conflict);
      expect(store.work.intent?.desiredSnapshot, isNotNull);
      expect(store.work.intent?.mutationToken, isNotNull);
      expect(
        (await engine.sync(store.work.binding.key)).disposition,
        PlaylistSyncDisposition.conflict,
      );
      expect(gateway.mutationCount, 1);
      expect(gateway.fetches, isEmpty);
    });

    test(
      'explicit keep-remote resolution is read-only and adopts remote',
      () async {
        final base = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
        ]);
        final local = _snapshot('Local edit', <PlaylistSyncItem>[
          _item('B', localId: 'b'),
        ]);
        final remote = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'sa'),
        ]);
        final store = _MemoryStore(
          _work(base: base, local: local, intent: _conflictIntent(now)),
        );
        final gateway = _FakeGateway()..fetches.add(remote);
        final engine = _engine(store, gateway, now);

        expect(
          (await engine.sync(store.work.binding.key)).disposition,
          PlaylistSyncDisposition.conflict,
        );
        expect(gateway.fetches, hasLength(1));
        await store.resolveConflict(
          key: store.work.binding.key,
          resolution: PlaylistSyncConflictResolution.keepRemote,
          expectedLocalRevision: store.work.localRevision,
          now: now,
        );

        final resolved = await engine.sync(store.work.binding.key);

        expect(resolved.disposition, PlaylistSyncDisposition.synchronized);
        expect(gateway.mutationCount, 0);
        expect(store.work.local.title, 'Road');
        expect(store.work.local.items.single.videoId, _video('A'));
      },
    );

    test(
      'explicit keep-local recreates a remotely deleted playlist exactly once',
      () async {
        final local = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
        ]);
        final recreated = PlaylistSyncSnapshot(
          remotePlaylistId: 'recreated-remote',
          title: 'Road',
          items: <PlaylistSyncItem>[_item('A', setId: 'sa')],
        );
        final store = _MemoryStore(_work(base: local, local: local));
        final gateway = _FakeGateway()
          ..fetches.addAll(<PlaylistSyncSnapshot?>[
            null,
            null,
            recreated,
            recreated,
          ])
          ..mutationReceipt = const RemoteMutationReceipt(
            status: RemoteMutationStatus.acknowledged,
            remotePlaylistId: 'recreated-remote',
          );
        final engine = _engine(store, gateway, now);

        final missing = await engine.sync(store.work.binding.key);
        expect(missing.disposition, PlaylistSyncDisposition.remoteDeleted);
        expect(store.work.intent?.status, PlaylistSyncIntentStatus.conflict);
        expect(gateway.createCount, 0);

        await store.resolveConflict(
          key: store.work.binding.key,
          resolution: PlaylistSyncConflictResolution.keepLocal,
          expectedLocalRevision: store.work.localRevision,
          now: now,
        );
        final recreatedResult = await engine.sync(store.work.binding.key);
        final idempotentResult = await engine.sync(store.work.binding.key);

        expect(
          recreatedResult.disposition,
          PlaylistSyncDisposition.synchronized,
        );
        expect(idempotentResult.disposition, PlaylistSyncDisposition.noChanges);
        expect(gateway.createCount, 1);
        expect(gateway.mutationCount, 1);
        expect(store.work.binding.remotePlaylistId, 'recreated-remote');
        expect(store.work.intent, isNull);
      },
    );

    test(
      'verified ambiguous write preserves a download linked while waiting',
      () async {
        final desired = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a'),
        ]);
        final local = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a').copyWith(localTrackId: 'download-a'),
        ]);
        final remote = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'verified-a'),
        ]);
        final store = _MemoryStore(
          _work(
            base: desired,
            local: local,
            intent: _ambiguousIntent(desired, now),
          ),
        );
        final gateway = _FakeGateway()..fetches.add(remote);

        final result = await _engine(
          store,
          gateway,
          now,
        ).sync(store.work.binding.key);

        expect(result.disposition, PlaylistSyncDisposition.synchronized);
        expect(gateway.mutationCount, 0);
        expect(store.commits, 1);
        expect(store.work.local.items.single.localTrackId, 'download-a');
        expect(store.work.local.items.single.setVideoId, 'verified-a');
      },
    );

    test(
      'verified old write keeps newer local content queued without another write',
      () async {
        final desired = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a'),
        ]);
        final local = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a'),
          _item('B', localId: 'b'),
        ]);
        final remote = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'verified-a'),
        ]);
        final store = _MemoryStore(
          _work(
            base: desired,
            local: local,
            intent: _ambiguousIntent(desired, now),
          ),
        );
        final gateway = _FakeGateway()..fetches.add(remote);

        final result = await _engine(
          store,
          gateway,
          now,
        ).sync(store.work.binding.key);

        expect(result.disposition, PlaylistSyncDisposition.deferred);
        expect(gateway.mutationCount, 0);
        expect(store.commits, 0);
        expect(store.baseOnlyCommits, 1);
        expect(store.conflicts, 0);
        expect(store.work.intent?.status, PlaylistSyncIntentStatus.pending);
        expect(store.work.intent?.mutationToken, isNull);
        expect(store.work.base!.items.map((item) => item.videoId), <String?>[
          _video('A'),
        ]);
        expect(store.work.base!.items.single.setVideoId, 'verified-a');
        expect(store.work.local.items.map((item) => item.videoId), <String?>[
          _video('A'),
          _video('B'),
        ]);
      },
    );

    test(
      'already equal snapshots are idempotent and issue no writes',
      () async {
        final equal = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
        ]);
        final remote = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'sa'),
        ]);
        final store = _MemoryStore(_work(base: equal, local: equal));
        final gateway = _FakeGateway()
          ..fetches.addAll(<PlaylistSyncSnapshot?>[remote, remote]);
        final engine = _engine(store, gateway, now);

        await engine.sync(store.work.binding.key);
        await engine.sync(store.work.binding.key);

        expect(gateway.mutationCount, 0);
        expect(store.conflicts, 0);
      },
    );

    test('a session fence rolls back a read-only local commit', () async {
      final equal = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', localId: 'a', setId: 'sa'),
      ]);
      final remote = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'sa'),
      ]);
      final store = _MemoryStore(_work(base: equal, local: equal));
      final gateway = _FakeGateway()..fetches.add(remote);
      var fenceChecks = 0;
      final engine = _engine(
        store,
        gateway,
        now,
        canPersist: () => ++fenceChecks <= 2,
      );

      final result = await engine.sync(store.work.binding.key);

      expect(result.disposition, PlaylistSyncDisposition.deferred);
      expect(gateway.mutationCount, 0);
      expect(store.commits, 0);
      expect(store.work.intent, isNull);
    });

    test(
      'a fence after a remote write preserves an ambiguous frozen intent',
      () async {
        final base = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
        ]);
        final local = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
          _item('B', localId: 'b'),
        ]);
        final before = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'sa'),
        ]);
        final after = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'sa'),
          _item('B', setId: 'sb'),
        ]);
        final store = _MemoryStore(_work(base: base, local: local));
        final gateway = _FakeGateway()
          ..fetches.addAll(<PlaylistSyncSnapshot?>[before, after]);
        var fenceChecks = 0;
        final engine = _engine(
          store,
          gateway,
          now,
          // load, initial read, pre-write, pre-readback and post-readback pass;
          // the transaction's final fence is the first rejected check.
          canPersist: () => ++fenceChecks <= 5,
        );

        final result = await engine.sync(store.work.binding.key);

        expect(result.disposition, PlaylistSyncDisposition.deferred);
        expect(gateway.mutationCount, 1);
        expect(store.commits, 0);
        expect(store.work.intent?.status, PlaylistSyncIntentStatus.ambiguous);
        expect(store.work.intent?.desiredSnapshot?.items, hasLength(2));
        expect(store.work.intent?.mutationToken, isNotEmpty);
      },
    );

    test(
      'alignment skips unavailable rows before and between playable songs',
      () async {
        final equal = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'old-a'),
          _item('B', localId: 'b', setId: 'old-b'),
        ]);
        final remote = _snapshot('Road', <PlaylistSyncItem>[
          _unavailable('unavailable-before'),
          _item('A', setId: 'verified-a'),
          _unavailable('unavailable-between'),
          _item('B', setId: 'verified-b'),
        ]);
        final store = _MemoryStore(_work(base: equal, local: equal));
        final gateway = _FakeGateway()..fetches.add(remote);

        final result = await _engine(
          store,
          gateway,
          now,
        ).sync(store.work.binding.key);

        expect(result.disposition, PlaylistSyncDisposition.noChanges);
        expect(gateway.mutationCount, 0);
        expect(store.commits, 1);
        final playable = store.work.local.items
            .where((item) => item.videoId != null)
            .toList(growable: false);
        expect(playable.map((item) => item.localItemId), <String?>['a', 'b']);
        expect(playable.map((item) => item.setVideoId), <String?>[
          'verified-a',
          'verified-b',
        ]);
      },
    );

    test('acknowledged delete commits after a successful read-back', () async {
      final remote = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'sa'),
      ]);
      final store = _MemoryStore(_work(localDeleted: true));
      final gateway = _FakeGateway()
        ..fetches.addAll(<PlaylistSyncSnapshot?>[remote, null])
        ..mutationReceipt = const RemoteMutationReceipt(
          status: RemoteMutationStatus.acknowledged,
        );

      final result = await _engine(
        store,
        gateway,
        now,
      ).sync(store.work.binding.key);

      expect(result.disposition, PlaylistSyncDisposition.localDeleted);
      expect(gateway.mutationCount, 1);
      expect(store.remoteDeletes, 1);
      expect(store.work.intent, isNull);
    });

    test('a local-only tombstone never reads or deletes the remote', () async {
      final store = _MemoryStore(
        _work(localDeleted: true, requestRemoteDelete: false),
      );
      final gateway = _FakeGateway()
        ..fetches.add(
          _snapshot('Road', <PlaylistSyncItem>[_item('A', setId: 'sa')]),
        );

      final result = await _engine(
        store,
        gateway,
        now,
      ).sync(store.work.binding.key);

      expect(result.disposition, PlaylistSyncDisposition.localDeleted);
      expect(gateway.fetches, hasLength(1));
      expect(gateway.mutationCount, 0);
      expect(store.remoteDeletes, 0);
      expect(store.work.binding.remotePlaylistId, 'remote');
    });

    test('rejected delete is a conflict and is not marked ambiguous', () async {
      final remote = _snapshot('Road', <PlaylistSyncItem>[
        _item('A', setId: 'sa'),
      ]);
      final store = _MemoryStore(_work(localDeleted: true));
      final gateway = _FakeGateway()
        ..fetches.add(remote)
        ..mutationReceipt = const RemoteMutationReceipt(
          status: RemoteMutationStatus.rejected,
          message: 'forbidden',
        );

      final result = await _engine(
        store,
        gateway,
        now,
      ).sync(store.work.binding.key);

      expect(result.disposition, PlaylistSyncDisposition.conflict);
      expect(
        result.conflicts.single.kind,
        PlaylistSyncConflictKind.remoteNotEditable,
      );
      expect(gateway.mutationCount, 1);
      expect(gateway.fetches, isEmpty);
      expect(store.work.intent?.status, PlaylistSyncIntentStatus.conflict);
      expect(store.conflicts, 1);
    });

    test(
      'ambiguous delete is read back once and never emitted again',
      () async {
        final remote = _snapshot('Road', <PlaylistSyncItem>[
          _item('A', setId: 'sa'),
        ]);
        final store = _MemoryStore(_work(localDeleted: true));
        final gateway = _FakeGateway()
          ..fetches.addAll(<PlaylistSyncSnapshot?>[remote, remote, remote])
          ..mutationReceipt = const RemoteMutationReceipt(
            status: RemoteMutationStatus.ambiguous,
            message: 'timeout',
          );
        final engine = _engine(store, gateway, now);

        final first = await engine.sync(store.work.binding.key);
        final frozenToken = store.work.intent?.mutationToken;
        final second = await engine.sync(store.work.binding.key);
        final third = await engine.sync(store.work.binding.key);

        expect(first.disposition, PlaylistSyncDisposition.deferred);
        expect(second.disposition, PlaylistSyncDisposition.conflict);
        expect(third.disposition, PlaylistSyncDisposition.conflict);
        expect(gateway.mutationCount, 1);
        expect(gateway.fetches, isEmpty);
        expect(store.work.intent?.status, PlaylistSyncIntentStatus.conflict);
        expect(store.work.intent?.mutationToken, frozenToken);
        expect(frozenToken, isNotEmpty);
        expect(store.remoteDeletes, 0);
      },
    );

    test('a non-editable remote is never deleted', () async {
      final remote = PlaylistSyncSnapshot(
        remotePlaylistId: 'remote',
        title: 'Road',
        items: <PlaylistSyncItem>[_item('A', setId: 'sa')],
        isEditable: false,
      );
      final store = _MemoryStore(_work(localDeleted: true));
      final gateway = _FakeGateway()..fetches.add(remote);

      final result = await _engine(
        store,
        gateway,
        now,
      ).sync(store.work.binding.key);

      expect(result.disposition, PlaylistSyncDisposition.conflict);
      expect(
        result.conflicts.single.kind,
        PlaylistSyncConflictKind.remoteNotEditable,
      );
      expect(gateway.mutationCount, 0);
      expect(store.remoteDeletes, 0);
      expect(store.work.intent?.status, PlaylistSyncIntentStatus.conflict);
    });
  });
}

PlaylistSyncEngine _engine(
  _MemoryStore store,
  _FakeGateway gateway,
  DateTime now, {
  bool Function()? canPersist,
}) {
  var id = 0;
  return PlaylistSyncEngine(
    store: store,
    gateway: gateway,
    merger: PlaylistThreeWayMerger(itemIdFactory: () => 'new-${id++}'),
    mutationTokenFactory: () => 'mutation-${id++}',
    clock: () => now,
    canPersist: canPersist,
  );
}

PlaylistSyncWork _work({
  PlaylistSyncSnapshot? base,
  PlaylistSyncSnapshot? local,
  bool localDeleted = false,
  bool requestRemoteDelete = true,
  PlaylistSyncIntent? intent,
}) {
  final now = DateTime.utc(2026, 8, 22);
  const key = PlaylistSyncKey(accountKey: 'account', playlistId: 'playlist');
  return PlaylistSyncWork(
    binding: PlaylistSyncBinding(
      key: key,
      remotePlaylistId: 'remote',
      mode: PlaylistSyncMode.automatic,
      localRevisionAtBase: 1,
      remoteDeleteRequestedAt: localDeleted && requestRemoteDelete ? now : null,
      createdAt: now,
      updatedAt: now,
    ),
    base:
        base ??
        _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
        ]),
    local:
        local ??
        _snapshot('Road', <PlaylistSyncItem>[
          _item('A', localId: 'a', setId: 'sa'),
        ]),
    localRevision: 1,
    localDeleted: localDeleted,
    intent: intent,
  );
}

PlaylistSyncIntent _ambiguousIntent(
  PlaylistSyncSnapshot desired,
  DateTime now,
) => PlaylistSyncIntent(
  key: const PlaylistSyncKey(accountKey: 'account', playlistId: 'playlist'),
  requestedLocalRevision: 1,
  reason: 'ambiguous_mutation',
  status: PlaylistSyncIntentStatus.ambiguous,
  desiredSnapshot: desired,
  desiredSnapshotHash: desired.semanticHash,
  mutationToken: 'frozen-token',
  attemptCount: 1,
  createdAt: now,
  updatedAt: now,
);

PlaylistSyncIntent _conflictIntent(DateTime now) => PlaylistSyncIntent(
  key: const PlaylistSyncKey(accountKey: 'account', playlistId: 'playlist'),
  requestedLocalRevision: 1,
  reason: 'conflict_ambiguousMutation',
  status: PlaylistSyncIntentStatus.conflict,
  attemptCount: 1,
  createdAt: now,
  updatedAt: now,
);

PlaylistSyncSnapshot _snapshot(String title, List<PlaylistSyncItem> items) {
  return PlaylistSyncSnapshot(
    remotePlaylistId: 'remote',
    title: title,
    items: items,
  );
}

PlaylistSyncItem _item(String seed, {String? localId, String? setId}) {
  final videoId = _video(seed);
  return PlaylistSyncItem(
    localItemId: localId,
    videoId: videoId,
    setVideoId: setId,
    track: CatalogTrack.youtube(videoId: videoId, title: seed),
  );
}

PlaylistSyncItem _unavailable(String setId) => PlaylistSyncItem(
  setVideoId: setId,
  track: CatalogTrack(
    key: 'unavailable:$setId',
    provider: CatalogProvider.legacy,
    providerId: setId,
    title: 'Unavailable',
  ),
);

String _video(String seed) => '${seed.padRight(10, '0')}1';

class _FakeGateway implements YouTubeMusicPlaylistGateway {
  final List<PlaylistSyncSnapshot?> fetches = <PlaylistSyncSnapshot?>[];
  Object? fetchError;
  void Function()? onFetch;
  void Function()? onCreate;
  RemoteMutationReceipt mutationReceipt = const RemoteMutationReceipt(
    status: RemoteMutationStatus.acknowledged,
  );
  int mutationCount = 0;
  int createCount = 0;

  @override
  Future<PlaylistSyncSnapshot?> fetchPlaylist({
    required String accountKey,
    required String remotePlaylistId,
  }) async {
    final error = fetchError;
    if (error != null) {
      throw error;
    }
    final result = fetches.removeAt(0);
    onFetch?.call();
    return result;
  }

  @override
  Future<RemoteMutationReceipt> applyDesiredState({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    mutationCount += 1;
    return mutationReceipt;
  }

  @override
  Future<RemoteMutationReceipt> createPlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot desired,
    required String mutationToken,
  }) async {
    mutationCount += 1;
    createCount += 1;
    onCreate?.call();
    return mutationReceipt;
  }

  @override
  Future<RemoteMutationReceipt> deletePlaylist({
    required String accountKey,
    required PlaylistSyncSnapshot observed,
    required String mutationToken,
  }) async {
    mutationCount += 1;
    return mutationReceipt;
  }
}

class _MemoryStore implements PlaylistSyncStore {
  _MemoryStore(this.work);

  PlaylistSyncWork work;
  int commits = 0;
  int baseOnlyCommits = 0;
  int conflicts = 0;
  int remoteDeletes = 0;

  @override
  Future<PlaylistSyncWork?> loadWork(PlaylistSyncKey key) async => work;

  @override
  Future<List<PlaylistSyncBinding>> listBindings({String? accountKey}) async =>
      <PlaylistSyncBinding>[work.binding];

  @override
  Future<List<PlaylistSyncUnresolvedConflict>> listUnresolvedConflicts({
    required String accountKey,
  }) async => const <PlaylistSyncUnresolvedConflict>[];

  @override
  Future<void> upsertBinding(
    PlaylistSyncBinding binding, {
    bool Function()? canCommit,
  }) async {
    _ensureMemoryCommitAllowed(canCommit);
    work = PlaylistSyncWork(
      binding: binding,
      base: work.base,
      local: work.local,
      localRevision: work.localRevision,
      localDeleted: work.localDeleted,
      intent: work.intent,
    );
  }

  @override
  Future<PlaylistSyncImportResult> importRemotePlaylistAtomically({
    required PlaylistSyncBinding binding,
    required String localPlaylistName,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    _ensureMemoryCommitAllowed(canCommit);
    if (work.binding.key.accountKey == binding.key.accountKey &&
        work.binding.remotePlaylistId == binding.remotePlaylistId) {
      return PlaylistSyncImportResult(binding: work.binding, created: false);
    }
    work = PlaylistSyncWork(
      binding: binding,
      local: PlaylistSyncSnapshot(title: localPlaylistName, items: const []),
      localRevision: requestedLocalRevision,
      localDeleted: false,
      intent: PlaylistSyncIntent(
        key: binding.key,
        requestedLocalRevision: requestedLocalRevision,
        reason: reason,
        status: PlaylistSyncIntentStatus.pending,
        attemptCount: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
    return PlaylistSyncImportResult(binding: binding, created: true);
  }

  @override
  Future<void> enqueueIntent({
    required PlaylistSyncKey key,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    _ensureMemoryCommitAllowed(canCommit);
  }

  @override
  Future<void> commitSynchronized({
    required PlaylistSyncKey key,
    required PlaylistSyncSnapshot mergedLocal,
    required PlaylistSyncSnapshot verifiedRemote,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    _ensureMemoryCommitAllowed(canCommit);
    commits += 1;
    work = PlaylistSyncWork(
      binding: work.binding,
      base: mergedLocal,
      local: mergedLocal,
      localRevision: work.localRevision,
      localDeleted: false,
    );
  }

  @override
  Future<void> commitVerifiedBaseWithNewerLocal({
    required PlaylistSyncKey key,
    required PlaylistSyncSnapshot verifiedBase,
    required PlaylistSyncSnapshot verifiedRemote,
    required int verifiedLocalRevision,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    if (work.localRevision != expectedLocalRevision) {
      throw const PlaylistSyncRevisionChanged();
    }
    _ensureMemoryCommitAllowed(canCommit);
    baseOnlyCommits += 1;
    work = PlaylistSyncWork(
      binding: work.binding.copyWith(
        remotePlaylistId: verifiedRemote.remotePlaylistId,
        isEditable: verifiedRemote.isEditable,
        privacy: verifiedRemote.privacy,
        baseTitle: verifiedBase.title,
        baseSnapshotHash: verifiedRemote.semanticHash,
        remoteRevision: verifiedRemote.revisionToken,
        localRevisionAtBase: verifiedLocalRevision,
        lastSyncedAt: now,
        lastRemoteSeenAt: now,
        updatedAt: now,
      ),
      base: verifiedBase,
      local: work.local,
      localRevision: work.localRevision,
      localDeleted: work.localDeleted,
      intent: PlaylistSyncIntent(
        key: key,
        requestedLocalRevision: expectedLocalRevision,
        reason: 'newer_local_after_verified_ambiguous',
        status: PlaylistSyncIntentStatus.pending,
        attemptCount: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  @override
  Future<void> recordDeferred({
    required PlaylistSyncKey key,
    required int requestedLocalRevision,
    required String reason,
    required DateTime now,
    required DateTime nextAttemptAt,
    PlaylistSyncSnapshot? desired,
    String? mutationToken,
    String? error,
    bool ambiguous = false,
  }) async {
    work = PlaylistSyncWork(
      binding: work.binding,
      base: work.base,
      local: work.local,
      localRevision: work.localRevision,
      localDeleted: work.localDeleted,
      intent: PlaylistSyncIntent(
        key: key,
        requestedLocalRevision: requestedLocalRevision,
        reason: reason,
        status: ambiguous
            ? PlaylistSyncIntentStatus.ambiguous
            : PlaylistSyncIntentStatus.pending,
        desiredSnapshot: desired,
        desiredSnapshotHash: desired?.semanticHash,
        mutationToken: mutationToken,
        attemptCount: (work.intent?.attemptCount ?? 0) + 1,
        nextAttemptAt: nextAttemptAt,
        lastError: error,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  @override
  Future<void> recordConflict({
    required PlaylistSyncKey key,
    required PlaylistSyncConflict conflict,
    required PlaylistSyncSnapshot? base,
    required PlaylistSyncSnapshot local,
    required PlaylistSyncSnapshot? remote,
    required DateTime now,
  }) async {
    conflicts += 1;
    final previous = work.intent;
    work = PlaylistSyncWork(
      binding: work.binding,
      base: work.base,
      local: work.local,
      localRevision: work.localRevision,
      localDeleted: work.localDeleted,
      intent: PlaylistSyncIntent(
        key: key,
        requestedLocalRevision:
            previous?.requestedLocalRevision ?? work.localRevision,
        reason: 'conflict_${conflict.kind.name}',
        status: PlaylistSyncIntentStatus.conflict,
        desiredSnapshot: previous?.desiredSnapshot,
        desiredSnapshotHash: previous?.desiredSnapshotHash,
        mutationToken: previous?.mutationToken,
        attemptCount: previous?.attemptCount ?? 0,
        nextAttemptAt: previous?.nextAttemptAt,
        lastError: previous?.lastError,
        createdAt: previous?.createdAt ?? now,
        updatedAt: now,
      ),
    );
  }

  @override
  Future<void> resolveConflict({
    required PlaylistSyncKey key,
    required PlaylistSyncConflictResolution resolution,
    required int expectedLocalRevision,
    required DateTime now,
  }) async {
    if (work.localRevision != expectedLocalRevision) {
      throw const PlaylistSyncRevisionChanged();
    }
    if (work.intent?.status != PlaylistSyncIntentStatus.conflict) {
      throw StateError('No unresolved playlist sync conflict exists.');
    }
    work = PlaylistSyncWork(
      binding: work.binding,
      base: work.base,
      local: work.local,
      localRevision: work.localRevision,
      localDeleted: work.localDeleted,
      intent: PlaylistSyncIntent(
        key: key,
        requestedLocalRevision: expectedLocalRevision,
        reason: playlistSyncConflictResolutionReason(resolution),
        status: PlaylistSyncIntentStatus.pending,
        attemptCount: 0,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  @override
  Future<void> commitRemoteDeleted({
    required PlaylistSyncKey key,
    required int expectedLocalRevision,
    required DateTime now,
    bool Function()? canCommit,
  }) async {
    _ensureMemoryCommitAllowed(canCommit);
    remoteDeletes += 1;
  }
}

void _ensureMemoryCommitAllowed(bool Function()? canCommit) {
  if (canCommit != null && !canCommit()) {
    throw const PlaylistSyncFenceChanged();
  }
}

class _Offline implements Exception {
  const _Offline();
}
