import 'package:bstream_music/services/spotify_canvas/spotify_canvas_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const track = SpotifyCanvasTrack(
    'Woman (Official Video)',
    'Doja Cat',
    Duration(seconds: 173),
  );

  Map<String, dynamic> result({
    String name = 'Woman',
    String artist = 'Doja Cat',
    int durationMs = 172626,
  }) => {
    'results': [
      {
        'trackId': '6Uj1ctrBOjOas8xZXGqKk4',
        'name': name,
        'artistNames': [artist],
        'durationMs': durationMs,
      },
    ],
  };

  Map<String, dynamic> canvas(String url) => {
    'hasCanvas': true,
    'canvases': [
      {'type': 'VIDEO', 'canvasUrl': url},
    ],
  };

  test('resolves verified track, caches result and sends title only', () async {
    final requests = <Uri>[];
    var mediaProbes = 0;
    final resolver = SpotifyCanvasResolver(
      fetchJson: (uri) async {
        requests.add(uri);
        if (uri.path == '/api/search') return result();
        return canvas('https://canvaz.scdn.co/upload/test.cnvs.mp4');
      },
      probeMediaSize: (_) async {
        mediaProbes++;
        return 4 * 1024 * 1024;
      },
    );

    final url = await resolver.resolve(track);
    expect(url?.host, 'canvaz.scdn.co');
    expect(await resolver.resolve(track), url);
    expect(requests, hasLength(2));
    expect(mediaProbes, 1);
    expect(requests.first.queryParameters['track'], 'Woman');
    expect(requests.last.queryParameters['id'], '6Uj1ctrBOjOas8xZXGqKk4');
  });

  test('does not show Canvas for wrong artist, title or duration', () async {
    for (final wrong in [
      result(artist: 'Another Artist'),
      result(name: 'Womanizer'),
      result(durationMs: 240000),
    ]) {
      var requests = 0;
      final resolver = SpotifyCanvasResolver(
        fetchJson: (_) async {
          requests++;
          return wrong;
        },
      );
      expect(await resolver.resolve(track), isNull);
      expect(requests, 1);
    }
  });

  test(
    'matches non-Latin song and artist names without transliteration',
    () async {
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async => uri.path == '/api/search'
            ? {
                'results': [
                  {
                    'trackId': '6Uj1ctrBOjOas8xZXGqKk4',
                    'name': '光',
                    'artistNames': ['宇多田ヒカル'],
                    'durationMs': 200000,
                  },
                ],
              }
            : canvas('https://canvaz.scdn.co/upload/test.cnvs.mp4'),
        probeMediaSize: (_) async => 4 * 1024 * 1024,
      );
      expect(
        await resolver.resolve(
          const SpotifyCanvasTrack('光', '宇多田ヒカル', Duration(seconds: 200)),
        ),
        isNotNull,
      );
    },
  );

  test('rejects unexpected video host and handles absent Canvas', () async {
    for (final response in [
      canvas('https://example.com/track.mp4'),
      {'hasCanvas': false, 'canvases': []},
    ]) {
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async =>
            uri.path == '/api/search' ? result() : response,
      );
      expect(await resolver.resolve(track), isNull);
    }
  });

  test('network failure returns no Canvas and is coalesced', () async {
    var requests = 0;
    final resolver = SpotifyCanvasResolver(
      fetchJson: (_) async {
        requests++;
        throw const FormatException('offline');
      },
    );
    final values = await Future.wait([
      resolver.resolve(track),
      resolver.resolve(track),
    ]);
    expect(values, [null, null]);
    expect(requests, 1);
  });

  test('does not load oversized or unmeasurable Canvas files', () async {
    for (final bytes in <int?>[
      SpotifyCanvasResolver.maxCanvasBytes + 1,
      null,
    ]) {
      final resolver = SpotifyCanvasResolver(
        fetchJson: (uri) async => uri.path == '/api/search'
            ? result()
            : canvas('https://canvaz.scdn.co/upload/test.cnvs.mp4'),
        probeMediaSize: (_) async => bytes,
      );
      expect(await resolver.resolve(track), isNull);
    }
  });
}
