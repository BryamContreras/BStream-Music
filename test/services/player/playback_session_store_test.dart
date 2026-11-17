import 'dart:async';
import 'dart:convert';

import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/audio_sources/audio_format_details.dart';
import 'package:bstream_music/services/player/playback_session_store.dart';
import 'package:bstream_music/services/player/player_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('an empty installation has no saved playback', () async {
    expect(await SharedPreferencesPlaybackSessionStore().read(), isNull);
  });

  test(
    'restores a mixed queue, exact cursor and catalog metadata only',
    () async {
      final local = _local('download').copyWith(
        isExternal: true,
        thumbnailPath: '/art/cover.jpg',
        audioFormat: const AudioFormatDetails(
          codec: 'aac',
          sampleRate: 44100,
          bitrate: 320000,
          channels: 2,
        ),
      );
      final remote = _remote('catalog').copyWith(
        streamUrl: 'https://expired.example/audio?signature=private',
        streamSource: 'jiosaavn',
        streamCodec: 'aac',
        streamClientProfileKey: 'temporary-client',
        httpHeaders: const <String, String>{'Authorization': 'Bearer private'},
      );
      final session = PlaybackSession(
        entries: <PlaybackSessionEntry>[
          PlaybackSessionEntry(remote: remote, logicalEntryId: 'first'),
          PlaybackSessionEntry(
            local: local,
            remote: remote,
            logicalEntryId: 'hybrid',
          ),
          PlaybackSessionEntry(
            remote: remote,
            logicalEntryId: 'duplicate-song',
          ),
        ],
        currentIndex: 1,
        position: const Duration(microseconds: 42123456),
        shuffleEnabled: true,
        repeatMode: PlaybackRepeatMode.all,
        playedIndices: const <int>[1],
        shufflePlan: const <int>[2, 0],
        localSourceId: 'playlist:local',
        remoteSourceId: 'playlist:catalog',
        activePlaybackIsRemote: true,
        useNativeLocalQueue: false,
      );
      await SharedPreferencesPlaybackSessionStore().write(session);
      final restored = (await SharedPreferencesPlaybackSessionStore().read())!;
      expect(restored.entries.map((entry) => entry.logicalEntryId), <String>[
        'first',
        'hybrid',
        'duplicate-song',
      ]);
      expect(restored.entries.map((entry) => entry.remote?.id), <String>[
        'catalog',
        'catalog',
        'catalog',
      ]);
      expect(restored.currentIndex, 1);
      expect(restored.position, session.position);
      expect(restored.shuffleEnabled, isTrue);
      expect(restored.repeatMode, PlaybackRepeatMode.all);
      expect(restored.playedIndices, <int>{1});
      expect(restored.shufflePlan, <int>[2, 0]);
      expect(restored.localSourceId, 'playlist:local');
      expect(restored.remoteSourceId, 'playlist:catalog');
      expect(restored.activePlaybackIsRemote, isTrue);
      expect(restored.useNativeLocalQueue, isFalse);
      final restoredLocal = restored.entries[1].local!;
      expect(restoredLocal.id, local.id);
      expect(restoredLocal.filePath, local.filePath);
      expect(restoredLocal.isExternal, isTrue);
      expect(restoredLocal.duration, local.duration);
      expect(restoredLocal.audioFormat, local.audioFormat);
      expect(restoredLocal.thumbnailPath, '/art/cover.jpg');
      final restoredRemote = restored.entries[1].remote!;
      expect(restoredRemote.artists, remote.artists);
      expect(restoredRemote.artistBrowseIds, remote.artistBrowseIds);
      expect(restoredRemote.metadataSource, TrackMetadataSource.youtubeMusic);
      expect(restoredRemote.duration, remote.duration);
      expect(restoredRemote.streamUrl, isNull);
      expect(restoredRemote.streamSource, isNull);
      expect(restoredRemote.streamCodec, isNull);
      expect(restoredRemote.httpHeaders, isNull);
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(
        SharedPreferencesPlaybackSessionStore.queuePreferenceKey,
      )!;
      expect(encoded, isNot(contains('expired.example')));
      expect(encoded, isNot(contains('Bearer private')));
      expect(encoded, isNot(contains('temporary-client')));
      expect(encoded, isNot(contains('streamUrl')));
    },
  );

  test('position checkpoints reuse encoded queue metadata', () async {
    final entry = _ObservedEntry(_local('one'));
    final session = _session(<PlaybackSessionEntry>[entry]);
    final store = SharedPreferencesPlaybackSessionStore();
    await store.write(session);
    final prefs = await SharedPreferences.getInstance();
    final originalQueue = prefs.getString(
      SharedPreferencesPlaybackSessionStore.queuePreferenceKey,
    );
    await store.write(session.copyWith(position: const Duration(seconds: 8)));
    await store.write(session.copyWith(position: const Duration(seconds: 13)));
    expect(entry.encodes, 1);
    expect(
      prefs.getString(SharedPreferencesPlaybackSessionStore.queuePreferenceKey),
      originalQueue,
    );
    expect(
      (await SharedPreferencesPlaybackSessionStore().read())!.position,
      const Duration(seconds: 13),
    );
    expect(identical(session.entries, session.copyWith().entries), isTrue);
  });

  test('a hybrid cursor uses the duration of its active source', () async {
    final store = SharedPreferencesPlaybackSessionStore();
    final session = PlaybackSession(
      entries: <PlaybackSessionEntry>[
        PlaybackSessionEntry(
          local: _local(
            'hybrid',
          ).copyWith(duration: const Duration(seconds: 30)),
          remote: _remote(
            'hybrid',
          ).copyWith(duration: const Duration(minutes: 3)),
        ),
      ],
      currentIndex: 0,
      position: const Duration(seconds: 75),
      activePlaybackIsRemote: true,
    );
    await store.write(session);
    expect((await store.read())!.position, const Duration(seconds: 75));
    await store.write(session.copyWith(activePlaybackIsRemote: false));
    expect((await store.read())!.position, const Duration(seconds: 30));
  });

  test(
    'a cursor from a previous queue cannot select another recording',
    () async {
      final store = SharedPreferencesPlaybackSessionStore();
      final prefs = await SharedPreferences.getInstance();
      await store.write(
        _session(<PlaybackSessionEntry>[
          PlaybackSessionEntry(local: _local('old')),
        ]),
      );
      final oldCursor = prefs.getString(
        SharedPreferencesPlaybackSessionStore.cursorPreferenceKey,
      )!;
      final replacement = PlaybackSession(
        entries: <PlaybackSessionEntry>[
          PlaybackSessionEntry(local: _local('new-a')),
          PlaybackSessionEntry(local: _local('new-b')),
        ],
        currentIndex: 1,
        position: const Duration(seconds: 21),
      );
      await store.write(replacement);
      // Simulate process death between replacing metadata and its new cursor.
      await prefs.setString(
        SharedPreferencesPlaybackSessionStore.cursorPreferenceKey,
        oldCursor,
      );
      final restored = (await SharedPreferencesPlaybackSessionStore().read())!;
      expect(restored.entries[restored.currentIndex].local!.id, 'new-b');
      expect(restored.position, const Duration(seconds: 21));
    },
  );

  test(
    'malformed cursor recovers the queue without throwing on startup',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await SharedPreferencesPlaybackSessionStore().write(
        _session(<PlaybackSessionEntry>[
          PlaybackSessionEntry(local: _local('saved')),
        ]),
      );
      final cursor =
          jsonDecode(
                prefs.getString(
                  SharedPreferencesPlaybackSessionStore.cursorPreferenceKey,
                )!,
              )
              as Map<String, dynamic>;
      cursor['currentIndex'] = 9999;
      await prefs.setString(
        SharedPreferencesPlaybackSessionStore.cursorPreferenceKey,
        jsonEncode(cursor),
      );
      final restored = (await SharedPreferencesPlaybackSessionStore().read())!;
      expect(restored.currentIndex, 0);
      expect(restored.entries.single.local!.id, 'saved');
      expect(restored.position, const Duration(seconds: 3));
    },
  );

  test(
    'unknown or damaged queue data is ignored without clearing other prefs',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('unrelated-setting', 'keep');
      await prefs.setString(
        SharedPreferencesPlaybackSessionStore.queuePreferenceKey,
        '{broken',
      );
      expect(await SharedPreferencesPlaybackSessionStore().read(), isNull);
      await prefs.setString(
        SharedPreferencesPlaybackSessionStore.queuePreferenceKey,
        jsonEncode(<String, Object?>{'version': 999, 'entries': <Object>[]}),
      );
      expect(await SharedPreferencesPlaybackSessionStore().read(), isNull);
      expect(prefs.getString('unrelated-setting'), 'keep');
    },
  );

  test(
    'an interrupted queue replacement cannot use the previous cursor',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = SharedPreferencesPlaybackSessionStore();
      await store.write(
        _session(<PlaybackSessionEntry>[
          PlaybackSessionEntry(local: _local('old')),
        ]),
      );
      final oldCursor = prefs.getString(
        SharedPreferencesPlaybackSessionStore.cursorPreferenceKey,
      )!;
      await store.write(
        PlaybackSession(
          entries: <PlaybackSessionEntry>[
            PlaybackSessionEntry(local: _local('new-first')),
            PlaybackSessionEntry(local: _local('new-selected')),
          ],
          currentIndex: 1,
          position: const Duration(seconds: 12),
        ),
      );
      // Simulate process death after replacing metadata but before its cursor.
      await prefs.setString(
        SharedPreferencesPlaybackSessionStore.cursorPreferenceKey,
        oldCursor,
      );
      final restored = (await SharedPreferencesPlaybackSessionStore().read())!;
      expect(restored.currentIndex, 1);
      expect(restored.entries[1].local!.id, 'new-selected');
      expect(restored.position, const Duration(seconds: 12));
    },
  );

  test(
    'a temporary preference failure does not disable later checkpoints',
    () async {
      var attempts = 0;
      final store = SharedPreferencesPlaybackSessionStore(
        loadPreferences: () {
          if (++attempts == 1) throw StateError('Preferences not ready');
          return SharedPreferences.getInstance();
        },
      );
      final session = _session(<PlaybackSessionEntry>[
        PlaybackSessionEntry(local: _local('recoverable')),
      ]);
      await expectLater(store.write(session), throwsStateError);
      await store.write(session);
      expect((await store.read())!.entries.single.local!.id, 'recoverable');
      expect(attempts, 2);
    },
  );

  test(
    'clear waits for in-flight writes and cannot revive the old session',
    () async {
      final started = Completer<void>();
      final release = Completer<SharedPreferences>();
      final store = SharedPreferencesPlaybackSessionStore(
        loadPreferences: () {
          started.complete();
          return release.future;
        },
      );
      final write = store.write(
        _session(<PlaybackSessionEntry>[
          PlaybackSessionEntry(local: _local('before-clear')),
        ]),
      );
      await started.future;
      final clear = store.clear();
      release.complete(await SharedPreferences.getInstance());
      await Future.wait(<Future<void>>[write, clear]);
      expect(await SharedPreferencesPlaybackSessionStore().read(), isNull);
      await store.write(
        _session(<PlaybackSessionEntry>[
          PlaybackSessionEntry(local: _local('after-clear')),
        ]),
      );
      expect((await store.read())!.entries.single.local!.id, 'after-clear');
    },
  );

  test(
    'large queues retain order and are not truncated to widget limits',
    () async {
      final session = _session(
        List<PlaybackSessionEntry>.generate(
          1001,
          (index) => PlaybackSessionEntry(local: _local('track-$index')),
        ),
      );
      await SharedPreferencesPlaybackSessionStore().write(session);
      final restored = (await SharedPreferencesPlaybackSessionStore().read())!;
      expect(restored.entries.length, 1001);
      expect(restored.entries.first.local!.id, 'track-0');
      expect(restored.entries.last.local!.id, 'track-1000');
    },
  );

  test(
    'persisted collections cannot be changed through caller-owned lists',
    () {
      final artists = <String>['original'];
      final source = <PlaybackSessionEntry>[
        PlaybackSessionEntry(local: _local('one').copyWith(artists: artists)),
      ];
      final session = _session(source);
      artists.add('later');
      source.clear();
      expect(session.entries.length, 1);
      expect(session.entries.single.local!.artists, <String>['original']);
      expect(() => session.entries.clear(), throwsUnsupportedError);
      expect(() => session.shufflePlan.add(1), throwsUnsupportedError);
    },
  );

  test(
    'shuffle state discards invalid indices without losing repeated songs',
    () async {
      final entries = <PlaybackSessionEntry>[
        PlaybackSessionEntry(local: _local('duplicate')),
        PlaybackSessionEntry(local: _local('duplicate')),
        PlaybackSessionEntry(local: _local('third')),
      ];
      await SharedPreferencesPlaybackSessionStore().write(
        PlaybackSession(
          entries: entries,
          currentIndex: 0,
          position: const Duration(days: 1),
          shuffleEnabled: true,
          playedIndices: const <int>[-1, 0, 900],
          shufflePlan: const <int>[2, 2, -1, 0, 1, 900],
        ),
      );
      final restored = (await SharedPreferencesPlaybackSessionStore().read())!;
      expect(restored.entries.length, 3);
      expect(restored.playedIndices, <int>{0});
      expect(restored.shufflePlan, <int>[2, 1]);
      expect(restored.position, entries.first.local!.duration);
    },
  );
}

PlaybackSession _session(List<PlaybackSessionEntry> entries) => PlaybackSession(
  entries: entries,
  currentIndex: 0,
  position: const Duration(seconds: 3),
);

LocalTrack _local(String id) => LocalTrack(
  id: id,
  title: 'Local $id',
  artist: 'BStream Music',
  filePath: '/music/$id.m4a',
  addedAt: DateTime.utc(2026, 11, 17),
  duration: const Duration(microseconds: 240012345),
  artists: const <String>['BStream Music'],
);

TrackInfo _remote(String id) => TrackInfo(
  id: id,
  title: 'Remote $id',
  artist: 'A, B',
  url: 'https://music.youtube.com/watch?v=$id',
  album: 'Album',
  albumBrowseId: 'MPRE-album',
  duration: const Duration(microseconds: 180987654),
  artists: const <String>['A', 'B'],
  artistBrowseIds: const <String?>['UC-artist', null],
  metadataSource: TrackMetadataSource.youtubeMusic,
);

class _ObservedEntry extends PlaybackSessionEntry {
  _ObservedEntry(LocalTrack local) : super(local: local);

  var encodes = 0;

  @override
  Map<String, Object?> toJson() {
    encodes++;
    return super.toJson();
  }
}
