import 'package:bstream_music/features/music/presentation/providers/app_strings.dart';
import 'package:bstream_music/features/music/presentation/widgets/youtube_music_playlist_conflicts_dialog.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_models.dart';
import 'package:bstream_music/services/youtube_music/playlist_sync/playlist_sync_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const strings = AppStrings(AppLanguage.english);

  testWidgets('lists every unresolved playlist conflict and its actions', (
    tester,
  ) async {
    final conflicts = <PlaylistSyncUnresolvedConflict>[
      _conflict(
        playlistId: 'road-trip',
        title: 'Road trip',
        message: 'Both playlist orders changed.',
      ),
      _conflict(
        playlistId: 'focus',
        title: 'Focus',
        message: 'The last YouTube Music write was uncertain.',
      ),
    ];
    await tester.pumpWidget(
      _ConflictDialogLauncher(
        conflicts: conflicts,
        onResolve: (_, _) async => true,
      ),
    );

    await tester.tap(find.byKey(const Key('open-conflicts')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('youtube-music-playlist-conflicts-dialog')),
      findsOneWidget,
    );
    expect(find.text(strings.playlistSyncConflictWarning), findsOneWidget);
    expect(find.text('Road trip'), findsOneWidget);
    expect(find.text('Both playlist orders changed.'), findsOneWidget);
    expect(find.text('Focus'), findsOneWidget);
    expect(
      find.text('The last YouTube Music write was uncertain.'),
      findsOneWidget,
    );
    expect(find.text(strings.keepBStreamPlaylist), findsNWidgets(2));
    expect(find.text(strings.keepYouTubeMusicPlaylist), findsNWidgets(2));
  });

  testWidgets(
    'resolves with BStream or YouTube Music and closes after the last row',
    (tester) async {
      final calls = <_ResolutionCall>[];
      final roadTrip = _conflict(playlistId: 'road-trip', title: 'Road trip');
      final focus = _conflict(playlistId: 'focus', title: 'Focus');
      await tester.pumpWidget(
        _ConflictDialogLauncher(
          conflicts: <PlaylistSyncUnresolvedConflict>[roadTrip, focus],
          onResolve: (conflict, resolution) async {
            calls.add(_ResolutionCall(conflict, resolution));
            return true;
          },
        ),
      );
      await tester.tap(find.byKey(const Key('open-conflicts')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey('youtube-music-conflict-keep-local-road-trip'),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.conflict, same(roadTrip));
      expect(calls.single.resolution, PlaylistSyncConflictResolution.keepLocal);
      expect(
        find.byKey(const ValueKey('youtube-music-conflict-road-trip')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('youtube-music-conflict-focus')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('youtube-music-playlist-conflicts-dialog')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('youtube-music-conflict-keep-remote-focus')),
      );
      await tester.pumpAndSettle();

      expect(calls, hasLength(2));
      expect(calls.last.conflict, same(focus));
      expect(calls.last.resolution, PlaylistSyncConflictResolution.keepRemote);
      expect(
        find.byKey(const Key('youtube-music-playlist-conflicts-dialog')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'groups repeated records for one playlist key into one keyed action row',
    (tester) async {
      final calls = <_ResolutionCall>[];
      final first = _conflict(
        playlistId: 'road-trip',
        title: 'Road trip',
        message: 'The title changed on both sides.',
        kind: PlaylistSyncConflictKind.title,
      );
      final second = _conflict(
        playlistId: 'road-trip',
        title: 'Road trip',
        message: 'The order also changed on both sides.',
        kind: PlaylistSyncConflictKind.order,
        detectedAt: DateTime.utc(2026, 8, 22, 0, 1),
      );
      await tester.pumpWidget(
        _ConflictDialogLauncher(
          conflicts: <PlaylistSyncUnresolvedConflict>[first, second],
          onResolve: (conflict, resolution) async {
            calls.add(_ResolutionCall(conflict, resolution));
            return true;
          },
        ),
      );

      await tester.tap(find.byKey(const Key('open-conflicts')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('youtube-music-conflict-road-trip')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('youtube-music-conflict-keep-local-road-trip'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('youtube-music-conflict-keep-remote-road-trip'),
        ),
        findsOneWidget,
      );
      expect(find.text('Road trip'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(
          const ValueKey('youtube-music-conflict-keep-local-road-trip'),
        ),
      );
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(calls.single.resolution, PlaylistSyncConflictResolution.keepLocal);
      expect(
        find.byKey(const Key('youtube-music-playlist-conflicts-dialog')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a resolver error keeps the row and reports a safe failure', (
    tester,
  ) async {
    final conflict = _conflict(playlistId: 'road-trip', title: 'Road trip');
    var calls = 0;
    await tester.pumpWidget(
      _ConflictDialogLauncher(
        conflicts: <PlaylistSyncUnresolvedConflict>[conflict],
        onResolve: (_, _) async {
          calls += 1;
          throw StateError('private backend detail');
        },
      ),
    );
    await tester.tap(find.byKey(const Key('open-conflicts')));
    await tester.pumpAndSettle();

    final keepLocal = find.byKey(
      const ValueKey('youtube-music-conflict-keep-local-road-trip'),
    );
    await tester.tap(keepLocal);
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(
      find.byKey(const ValueKey('youtube-music-conflict-road-trip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('youtube-music-playlist-conflicts-dialog')),
      findsOneWidget,
    );
    expect(find.text(strings.playlistConflictResolveFailed), findsOneWidget);
    expect(find.textContaining('private backend detail'), findsNothing);
    expect(tester.widget<OutlinedButton>(keepLocal).onPressed, isNotNull);
  });
}

class _ConflictDialogLauncher extends StatelessWidget {
  const _ConflictDialogLauncher({
    required this.conflicts,
    required this.onResolve,
  });

  final List<PlaylistSyncUnresolvedConflict> conflicts;
  final YouTubeMusicPlaylistConflictResolver onResolve;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            key: const Key('open-conflicts'),
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => YouTubeMusicPlaylistConflictsDialog(
                conflicts: conflicts,
                strings: const AppStrings(AppLanguage.english),
                onResolve: onResolve,
              ),
            ),
            child: const Text('Open conflicts'),
          ),
        ),
      ),
    );
  }
}

class _ResolutionCall {
  const _ResolutionCall(this.conflict, this.resolution);

  final PlaylistSyncUnresolvedConflict conflict;
  final PlaylistSyncConflictResolution resolution;
}

PlaylistSyncUnresolvedConflict _conflict({
  required String playlistId,
  required String title,
  String? message,
  PlaylistSyncConflictKind kind = PlaylistSyncConflictKind.ambiguousMutation,
  DateTime? detectedAt,
}) => PlaylistSyncUnresolvedConflict(
  key: PlaylistSyncKey(accountKey: 'test-account', playlistId: playlistId),
  playlistTitle: title,
  localRevision: 7,
  kind: kind,
  detectedAt: detectedAt ?? DateTime.utc(2026, 8, 22),
  message: message,
);
