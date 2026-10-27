import 'package:bstream_music/features/music/presentation/providers/spotify_canvas_provider.dart';
import 'package:bstream_music/services/spotify_canvas/spotify_canvas_resolver.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _unknown = SpotifyCanvasTrack('vampire', 'Olivia Rodrigo', Duration.zero);
const _known = SpotifyCanvasTrack(
  'vampire',
  'Olivia Rodrigo',
  Duration(seconds: 220),
);

void main() {
  testWidgets('looks up a Canvas even when native duration stays unavailable', (
    tester,
  ) async {
    final resolver = _RecordingResolver();
    final container = _container(resolver);
    addTearDown(container.dispose);
    final subscription = container.listen(
      spotifyCanvasUrlProvider(_unknown),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await tester.pump();
    expect(resolver.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 399));
    expect(resolver.requests, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(resolver.requests, [_unknown]);
    expect(
      container.read(spotifyCanvasUrlProvider(_unknown)).value,
      resolver.url,
    );
  });

  testWidgets('known duration starts lookup immediately', (tester) async {
    final resolver = _RecordingResolver();
    final container = _container(resolver);
    addTearDown(container.dispose);
    final subscription = container.listen(
      spotifyCanvasUrlProvider(_known),
      (_, _) {},
    );
    addTearDown(subscription.close);
    await tester.pump();
    expect(resolver.requests, [_known]);
    expect(
      container.read(spotifyCanvasUrlProvider(_known)).value,
      resolver.url,
    );
  });

  testWidgets('early duration update cancels the redundant unknown lookup', (
    tester,
  ) async {
    final resolver = _RecordingResolver();
    final container = _container(resolver);
    addTearDown(container.dispose);
    final unknown = container.listen(
      spotifyCanvasUrlProvider(_unknown),
      (_, _) {},
    );
    await tester.pump(const Duration(milliseconds: 100));
    unknown.close();
    final known = container.listen(spotifyCanvasUrlProvider(_known), (_, _) {});
    addTearDown(known.close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(resolver.requests, [_known]);
  });

  testWidgets('leaving the player cancels the pending metadata grace period', (
    tester,
  ) async {
    final resolver = _RecordingResolver();
    final container = _container(resolver);
    addTearDown(container.dispose);
    final subscription = container.listen(
      spotifyCanvasUrlProvider(_unknown),
      (_, _) {},
    );
    await tester.pump(const Duration(milliseconds: 100));
    subscription.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(resolver.requests, isEmpty);
  });
}

ProviderContainer _container(_RecordingResolver resolver) => ProviderContainer(
  overrides: [spotifyCanvasResolverProvider.overrideWithValue(resolver)],
);

class _RecordingResolver extends SpotifyCanvasResolver {
  final requests = <SpotifyCanvasTrack>[];
  final url = Uri.https('canvaz.scdn.co', '/fixture.mp4');

  @override
  Future<Uri?> resolve(SpotifyCanvasTrack track) async {
    requests.add(track);
    return url;
  }
}
