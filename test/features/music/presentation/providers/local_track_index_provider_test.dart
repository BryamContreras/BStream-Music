import 'package:bstream_music/features/music/domain/entities/local_track.dart';
import 'package:bstream_music/features/music/presentation/providers/local_track_index_provider.dart';
import 'package:bstream_music/features/music/presentation/providers/music_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recommendation lookup keeps the first match of either identity', () {
    final sourceMatch = _track('earlier', sourceId: ' video ');
    final localMatch = _track('selected', sourceId: 'other');
    final index = LocalTrackIndex([sourceMatch, localMatch]);

    expect(
      index.firstMatching(localId: ' selected ', sourceId: ' video '),
      same(sourceMatch),
    );
    expect(
      LocalTrackIndex([
        localMatch,
        sourceMatch,
      ]).firstMatching(localId: 'selected', sourceId: 'video'),
      same(localMatch),
    );
    // Playback has a separate ID-before-URL rule and can use these lookups.
    expect(index.firstById(' selected '), same(localMatch));
    expect(index.firstBySourceUrl(' https://example.com/audio '), sourceMatch);
    expect(index.firstMatching(localId: '', sourceId: ' '), isNull);
    expect(LocalTrackIndex([_track('')]).firstById(' '), isNull);
    expect(
      index.firstMatching(localId: 'missing', sourceId: 'unknown'),
      isNull,
    );
  });

  test('duplicate identities keep their first saved track', () {
    final first = _track('same', sourceId: 'video');
    final duplicate = _track('same', sourceId: ' video ');
    final index = LocalTrackIndex([first, duplicate]);
    expect(index.firstById('same'), same(first));
    expect(index.firstBySourceUrl(first.sourceUrl), same(first));
    expect(index.firstMatching(sourceId: 'video'), same(first));
    expect(
      index.forPlaylist(localId: ' same ', sourceId: 'video'),
      same(duplicate),
    );
    expect(index.forPlaylist(localId: null, sourceId: 'video'), same(first));
    expect(index.forPlaylist(localId: 'missing', sourceId: 'video'), isNull);
  });

  test('resolves any number of cards with one library traversal', () {
    var traversals = 0;
    Iterable<LocalTrack> tracks() sync* {
      traversals++;
      for (var i = 0; i < 200; i++) {
        yield _track('local-$i', sourceId: 'video-$i');
      }
    }

    final index = LocalTrackIndex(tracks());
    for (var i = 0; i < 1000; i++) {
      expect(index.firstMatching(sourceId: 'video-199')?.id, 'local-199');
    }
    expect(traversals, 1);
  });

  test(
    'shared index is reused and refreshed with the library snapshot',
    () async {
      final first = _track('first', sourceId: 'video');
      final latest = _track('latest', sourceId: 'video');
      final source = StateProvider<List<LocalTrack>>((ref) => [first]);
      final container = ProviderContainer(
        overrides: [
          libraryTracksProvider.overrideWith((ref) async => ref.watch(source)),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(localTrackIndexProvider, (_, _) {});
      addTearDown(subscription.close);
      await container.read(libraryTracksProvider.future);
      await container.pump();
      final initial = container.read(localTrackIndexProvider);
      expect(initial.firstMatching(sourceId: 'video'), same(first));
      expect(container.read(localTrackIndexProvider), same(initial));

      container.read(source.notifier).state = [latest];
      await container.read(libraryTracksProvider.future);
      await container.pump();
      final updated = container.read(localTrackIndexProvider);
      expect(updated, isNot(same(initial)));
      expect(updated.firstMatching(sourceId: 'video'), same(latest));
    },
  );
}

LocalTrack _track(String id, {String? sourceId}) => LocalTrack(
  id: id,
  title: id,
  artist: 'Artist',
  filePath: '/audio/$id.mp3',
  addedAt: DateTime.utc(2026),
  sourceId: sourceId,
  sourceUrl: 'https://example.com/audio',
);
