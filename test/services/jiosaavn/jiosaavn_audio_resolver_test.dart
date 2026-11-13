import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bstream_music/features/music/domain/entities/track_info.dart';
import 'package:bstream_music/services/downloader/audio_stream_resolver.dart';
import 'package:bstream_music/services/jiosaavn/jiosaavn_audio_resolver.dart';
import 'package:bstream_music/services/jiosaavn/jiosaavn_http_transport.dart';
import 'package:bstream_music/services/jiosaavn/jiosaavn_recording_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mp4_fixture.dart';

// Independent DES/ECB/PKCS7 fixture generated with .NET's DES implementation.
const _encodedUrl =
    'ID2ieOjCrwfgWvL5sXl4B1ImC5QfbsDyFSR1/uWi61EAjO6vTHbzEK0z/DoyxrV/'
    'Rk8/3xHgiZysaOvHYriyNBgU7MasW8n/';
const _target = TrackInfo(
  id: 'youtube-id',
  title: 'Coraz\u00f3n',
  artist: 'BStream Music',
  artists: ['BStream Music'],
  album: 'Original Album',
  duration: Duration(seconds: 180),
  url: 'https://music.youtube.com/watch?v=youtube-id',
);

void main() {
  test(
    'the current Dame Hombro catalog recording matches its 124 second counterpart',
    () {
      const target = TrackInfo(
        id: 'K3-OCB6lfs8',
        title: 'Dame Hombro',
        artist: 'Bulin 47, Kevin Wai, Breyco En Producidera',
        artists: ['Bulin 47', 'Kevin Wai', 'Breyco En Producidera'],
        album: 'Dame Hombro',
        duration: Duration(seconds: 125),
        url: 'https://music.youtube.com/watch?v=K3-OCB6lfs8',
        streamCodec: 'opus',
        streamBitrate: 139000,
      );
      const original = JioSaavnSong(
        id: 'RPZzG6xs',
        title: 'Dame Hombro',
        artists: ['Bulin 47', 'Kevin Wai', 'Breyco En Producidera'],
        album: 'Dame Hombro',
        duration: Duration(seconds: 124),
        supports320: true,
        explicit: true,
      );
      const alternate = JioSaavnSong(
        id: 'vpBNTsMB',
        title: 'Dame Hombro (Drako Version)',
        artists: ['Drako Martinez', 'Bulin 47', 'Kevin Wai'],
        album: 'Dame Hombro (Drako Version)',
        duration: Duration(seconds: 124),
        supports320: true,
        explicit: true,
      );
      expect(
        const JioSaavnRecordingMatcher().rankedMatches(target, [
          alternate,
          original,
        ]),
        [original],
      );
    },
  );

  test(
    'DES URL decoding preserves access query and selects the actual path',
    () {
      expect(
        decodeJioSaavn320Uri(_encodedUrl)?.toString(),
        'https://aac.saavncdn.com/123/song_320.mp4?token=keep%2Bvalue#part',
      );
      for (final value in [
        '',
        'invalid-base64',
        base64.encode(List.filled(8, 0)),
        // Valid encrypted URL with an untrusted origin.
        'ID2ieOjCrwdZENEJmV3zZvtmpx45xpH14nWBwalU1hKD8xWi/2ivew==',
        // Valid CDN URL whose path does not identify a known rendition.
        'ID2ieOjCrwfgWvL5sXl4B1ImC5QfbsDyFSR1/uWi61Fd2VeG8v6D6Q==',
      ]) {
        expect(decodeJioSaavn320Uri(value), isNull);
      }
    },
  );

  test(
    'matches the same recording while rejecting alternate takes and covers',
    () {
      const matcher = JioSaavnRecordingMatcher();
      final good = _song();
      expect(matcher.rankedMatches(_target, [good]), [good]);
      final variants = [
        _song(title: 'Coraz\u00f3n (Live)'),
        _song(title: 'Coraz\u00f3n (Remix)'),
        _song(title: 'Coraz\u00f3n (Karaoke)'),
        _song(title: 'Coraz\u00f3n', artists: ['A cover artist']),
        _song(duration: const Duration(seconds: 183)),
        _song(album: 'Live at the Arena'),
        _song(title: 'Otro Coraz\u00f3n'),
      ];
      expect(matcher.rankedMatches(_target, variants), isEmpty);
      expect(
        matcher.rankedMatches(_target.copyWith(title: 'Coraz\u00f3n (Live)'), [
          good,
        ]),
        isEmpty,
      );
    },
  );

  test(
    'normalizes packaging, credits and entities without losing versions',
    () {
      const matcher = JioSaavnRecordingMatcher();
      final target = _target.copyWith(
        title: 'Coraz\u00f3n (Official Audio)',
        artist: 'BStream Music, Guest',
        artists: ['BStream Music', 'Guest'],
      );
      final song = _song(title: 'Corazon (feat. Guest)');
      expect(matcher.rankedMatches(target, [song]), [song]);
      expect(
        decodeJioSaavnText('A &amp; B &quot;C&quot; &#x1f3b5;'),
        'A & B "C" \u{1f3b5}',
      );
      expect(matcher.searchQueries(target), [
        'corazon bstream music',
        'corazon',
      ]);
    },
  );

  test(
    'the requested release wins over another album a second closer in runtime, while unidentified release collisions stay on YouTube',
    () {
      const matcher = JioSaavnRecordingMatcher();
      final requested = _song(duration: const Duration(seconds: 181));
      final other = _song(album: 'Different Recording');
      expect(matcher.rankedMatches(_target, [other, requested]), [requested]);
      final noAlbum = TrackInfo(
        id: _target.id,
        title: _target.title,
        artist: _target.artist,
        artists: _target.artists,
        duration: _target.duration,
        url: _target.url,
      );
      expect(matcher.rankedMatches(noAlbum, [requested, other]), isEmpty);
    },
  );

  test(
    'an unmarked target keeps YouTube when otherwise matching catalog entries disagree on the clean or explicit edition',
    () {
      const matcher = JioSaavnRecordingMatcher();
      final clean = _song(id: 'clean', explicit: false);
      final explicit = _song(id: 'explicit', explicit: true);
      expect(matcher.rankedMatches(_target, [clean, explicit]), isEmpty);
      expect(matcher.rankedMatches(_target, [explicit, clean]), isEmpty);
    },
  );

  test(
    'an explicitly requested clean edition rejects an explicit catalog flag',
    () {
      const matcher = JioSaavnRecordingMatcher();
      final target = _target.copyWith(title: 'Corazon (Clean)');
      final clean = _song(
        id: 'clean',
        title: 'Corazon (Clean)',
        explicit: false,
      );
      final explicit = _song(
        id: 'explicit',
        title: 'Corazon (Clean)',
        explicit: true,
      );
      expect(matcher.rankedMatches(target, [explicit]), isEmpty);
      expect(matcher.rankedMatches(target, [explicit, clean]), [clean]);
    },
  );

  test(
    'returns verified 320 transport without replacing catalog metadata',
    () async {
      final transport = _Transport();
      final resolver = JioSaavnAudioResolver(transport: transport);
      addTearDown(resolver.dispose);
      final result = await resolver.findUpgrade(
        _target,
        currentBitrate: 128000,
      );
      expect(result?.source, AudioStreamSource.jioSaavn);
      expect(result?.bitrate, 320000);
      expect(result?.codec, 'aac');
      expect(result?.sampleRate, isNull);
      expect(result?.channels, isNull);
      expect(result?.streamExtension, 'm4a');
      expect(result?.formatId, 'jiosaavn:saavn-id:320');
      expect(transport.requests, hasLength(3));
      expect(transport.requests.last.headers['Range'], 'bytes=0-4095');
      expect(transport.requests.last.maximumBytes, 4096);
      expect(transport.requests.last.readPrefix, isTrue);
      final catalogRequests = transport.requests.where(
        (request) => request.uri.host == 'www.jiosaavn.com',
      );
      expect(catalogRequests, hasLength(2));
      for (final request in catalogRequests) {
        expect(request.uri.path, '/api.php');
        expect(request.headers['X-Forwarded-For'], '49.36.0.1');
        expect(request.headers['X-Real-IP'], '49.36.0.1');
      }
      expect(
        transport.requests
            .where((request) => request.uri.host != 'www.jiosaavn.com')
            .any(
              (request) => request.headers.keys.any(
                (key) =>
                    key.toLowerCase().contains('forwarded') ||
                    key.toLowerCase().contains('real-ip'),
              ),
            ),
        isFalse,
      );
      expect(
        result?.httpHeaders?.keys.any(
          (key) =>
              key.toLowerCase().contains('forwarded') ||
              key.toLowerCase().contains('real-ip'),
        ),
        isFalse,
      );
      expect(_target.title, 'Coraz\u00f3n');
      expect(_target.id, 'youtube-id');
    },
  );

  test('supports both keyed and songs-array detail envelopes', () async {
    for (final arrayEnvelope in [false, true]) {
      final transport = _Transport(arrayEnvelope: arrayEnvelope);
      final resolver = JioSaavnAudioResolver(transport: transport);
      expect(await resolver.findUpgrade(_target), isNotNull);
      await resolver.dispose();
    }
  });

  test(
    'propagates measured AAC bitrate, sample rate and channels from the CDN',
    () async {
      final transport = _Transport(
        probe: _probe(bytes: mp4Prefix(moov: aacMoov())),
      );
      final resolver = JioSaavnAudioResolver(transport: transport);
      addTearDown(resolver.dispose);
      final result = await resolver.findUpgrade(
        _target,
        currentBitrate: 128000,
      );
      expect(result?.codec, 'aac');
      expect(result?.bitrate, 312999);
      expect(result?.sampleRate, 44100);
      expect(result?.channels, 2);
      expect(result?.formatId, 'jiosaavn:saavn-id:320');
      expect(transport.requests, hasLength(3));
      expect(await resolver.findUpgrade(_target), same(result));
      expect(transport.requests, hasLength(3));
    },
  );

  test('optional header seek failure preserves the verified upgrade', () async {
    final transport = _Transport(
      probe: _probe(bytes: mp4Prefix(tailOffset: 6500000)),
    );
    final resolver = JioSaavnAudioResolver(transport: transport);
    addTearDown(resolver.dispose);
    // The fake ignores the follow-up Range. Its invalid seek response must
    // leave technical details unknown without discarding the valid rendition.
    final result = await resolver.findUpgrade(_target);
    expect(result?.source, AudioStreamSource.jioSaavn);
    expect(result?.bitrate, 320000);
    expect(result?.sampleRate, isNull);
    expect(result?.channels, isNull);
    expect(transport.requests, hasLength(4));
  });

  test('does not claim an upgrade without the catalog 320 offer', () async {
    final transport = _Transport(supports320: false);
    final resolver = JioSaavnAudioResolver(transport: transport);
    addTearDown(resolver.dispose);
    expect(await resolver.findUpgrade(_target), isNull);
    expect(transport.requests, hasLength(2));
    expect(
      transport.requests.every(
        (request) => request.uri.host == 'www.jiosaavn.com',
      ),
      isTrue,
    );
  });

  test('rechecks identity and availability in the details response', () async {
    for (final changed in [
      {'title': 'Corazon (Remix)'},
      {'id': 'a-different-id'},
      {
        'more_info': {..._row()['more_info'] as Map, '320kbps': 'false'},
      },
    ]) {
      final transport = _Transport(detailsOverride: changed);
      final resolver = JioSaavnAudioResolver(transport: transport);
      expect(await resolver.findUpgrade(_target), isNull);
      expect(transport.requests, hasLength(2));
      await resolver.dispose();
    }
  });

  test(
    'a missing, invalid or lower-bitrate CDN rendition keeps YouTube',
    () async {
      for (final response in [
        _probe(status: 403),
        _probe(status: 302),
        _probe(totalBytes: 2000000),
        JioSaavnHttpResponse(
          statusCode: 206,
          body: Uint8List.fromList(utf8.encode('<html>error</html>')),
          headers: {'content-range': 'bytes 0-4095/7200000'},
        ),
        JioSaavnHttpResponse(statusCode: 206, body: _ftyp, headers: const {}),
      ]) {
        final transport = _Transport(probe: response);
        final resolver = JioSaavnAudioResolver(transport: transport);
        expect(await resolver.findUpgrade(_target), isNull);
        await resolver.dispose();
      }
    },
  );

  test('uses a bounded negative cache and retries after it expires', () async {
    var now = DateTime(2026);
    final transport = _Transport(searchRows: const []);
    final resolver = JioSaavnAudioResolver(
      transport: transport,
      now: () => now,
    );
    addTearDown(resolver.dispose);
    expect(await resolver.findUpgrade(_target), isNull);
    expect(await resolver.findUpgrade(_target), isNull);
    expect(transport.requests, hasLength(2));
    now = now.add(const Duration(minutes: 3));
    expect(await resolver.findUpgrade(_target), isNull);
    expect(transport.requests, hasLength(4));
  });

  test(
    'successful cached lookups do not repeat search, details or probe',
    () async {
      final transport = _Transport();
      final resolver = JioSaavnAudioResolver(transport: transport);
      addTearDown(resolver.dispose);
      final first = await resolver.findUpgrade(_target);
      final second = await resolver.findUpgrade(_target);
      expect(second, same(first));
      expect(transport.requests, hasLength(3));
      expect(
        await resolver.findUpgrade(_target, currentBitrate: 320000),
        isNull,
      );
      expect(transport.requests, hasLength(3));
    },
  );

  test(
    'concurrent requests share work and one obsolete caller cannot cancel another',
    () async {
      final gate = Completer<void>();
      final transport = _Transport(firstSearchGate: gate.future);
      final resolver = JioSaavnAudioResolver(transport: transport);
      addTearDown(resolver.dispose);
      var firstCurrent = true;
      final first = resolver.findUpgrade(
        _target,
        shouldContinue: () => firstCurrent,
      );
      final second = resolver.findUpgrade(_target, shouldContinue: () => true);
      firstCurrent = false;
      gate.complete();
      expect(await first, isNull);
      expect(await second, isNotNull);
      expect(transport.requests, hasLength(3));
    },
  );

  test(
    'cancelled work stops between requests and does not poison the cache',
    () async {
      var current = true;
      final transport = _Transport(onRequest: (_) => current = false);
      final resolver = JioSaavnAudioResolver(transport: transport);
      addTearDown(resolver.dispose);
      expect(
        await resolver.findUpgrade(_target, shouldContinue: () => current),
        isNull,
      );
      expect(transport.requests, hasLength(1));
      transport.onRequest = null;
      current = true;
      expect(
        await resolver.findUpgrade(_target, shouldContinue: () => current),
        isNotNull,
      );
      expect(transport.requests, hasLength(4));
    },
  );

  test(
    'lookup concurrency is bounded and an obsolete queued song never makes an API request',
    () async {
      final gate = Completer<void>();
      final transport = _Transport(
        firstSearchGate: gate.future,
        holdAllSearches: true,
      );
      final resolver = JioSaavnAudioResolver(transport: transport);
      addTearDown(resolver.dispose);
      var thirdCurrent = true;
      final first = resolver.findUpgrade(_target.copyWith(id: 'one'));
      final second = resolver.findUpgrade(_target.copyWith(id: 'two'));
      final third = resolver.findUpgrade(
        _target.copyWith(id: 'three'),
        shouldContinue: () => thirdCurrent,
      );
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(2));
      thirdCurrent = false;
      gate.complete();
      expect(await first, isNotNull);
      expect(await second, isNotNull);
      expect(await third, isNull);
      expect(transport.requests, hasLength(6));
    },
  );

  test(
    'unknown runtimes and lossless/current-high sources make no network requests',
    () async {
      final transport = _Transport();
      final resolver = JioSaavnAudioResolver(transport: transport);
      addTearDown(resolver.dispose);
      const unknown = TrackInfo(
        id: 'x',
        title: 'Corazon',
        artist: 'BStream Music',
        url: 'https://music.youtube.com/watch?v=x',
      );
      expect(await resolver.findUpgrade(unknown), isNull);
      expect(
        await resolver.findUpgrade(
          _target.copyWith(artist: 'Unknown Artist', artists: const []),
        ),
        isNull,
      );
      expect(
        await resolver.findUpgrade(_target.copyWith(streamCodec: 'flac')),
        isNull,
      );
      expect(
        await resolver.findUpgrade(_target.copyWith(streamBitrate: 320000)),
        isNull,
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'the least recently used lookup is evicted when the cache is full',
    () async {
      final transport = _Transport();
      final resolver = JioSaavnAudioResolver(
        transport: transport,
        maximumCacheEntries: 2,
      );
      addTearDown(resolver.dispose);
      await resolver.findUpgrade(_target);
      await resolver.findUpgrade(_target.copyWith(id: 'two'));
      await resolver.findUpgrade(_target.copyWith(id: 'three'));
      expect(transport.requests, hasLength(9));
      await resolver.findUpgrade(_target);
      expect(transport.requests, hasLength(12));
    },
  );

  test(
    'HTTP failures and malformed responses fall back without throwing',
    () async {
      for (final response in [
        JioSaavnHttpResponse(statusCode: 403, body: Uint8List(0)),
        JioSaavnHttpResponse(
          statusCode: 200,
          body: Uint8List.fromList(utf8.encode('<html>blocked</html>')),
        ),
      ]) {
        final transport = _Transport(apiOverride: response);
        final resolver = JioSaavnAudioResolver(transport: transport);
        expect(await resolver.findUpgrade(_target), isNull);
        await resolver.dispose();
      }
    },
  );

  test(
    'dispose closes the owned client and prevents additional work',
    () async {
      final transport = _Transport();
      final resolver = JioSaavnAudioResolver(transport: transport);
      await resolver.dispose();
      await resolver.dispose();
      expect(transport.closes, 1);
      expect(await resolver.findUpgrade(_target), isNull);
      expect(transport.requests, isEmpty);
    },
  );
}

JioSaavnSong _song({
  String id = 'song',
  String title = 'Corazon',
  List<String> artists = const ['BStream Music'],
  Duration duration = const Duration(seconds: 180),
  String album = 'Original Album',
  bool explicit = false,
}) => JioSaavnSong(
  id: id,
  title: title,
  artists: artists,
  duration: duration,
  supports320: true,
  explicit: explicit,
  album: album,
);

Map<String, Object?> _row({bool supports320 = true}) => {
  'id': 'saavn-id',
  'title': 'Corazon',
  'explicit_content': '1',
  'more_info': {
    'album': 'Original Album',
    'duration': '180',
    '320kbps': supports320.toString(),
    'encrypted_media_url': _encodedUrl,
    'artistMap': {
      'primary_artists': [
        {'name': 'BStream Music'},
      ],
    },
  },
};

final _ftyp = Uint8List.fromList([
  0,
  0,
  0,
  24,
  ...ascii.encode('ftypM4A '),
  ...List.filled(12, 0),
]);
JioSaavnHttpResponse _probe({
  int status = 206,
  int totalBytes = 7200000,
  Uint8List? bytes,
}) => JioSaavnHttpResponse(
  statusCode: status,
  body: bytes ?? _ftyp,
  headers: {
    'content-range': 'bytes 0-4095/$totalBytes',
    'content-length': '$totalBytes',
  },
);

class _Request {
  const _Request(this.uri, this.headers, this.maximumBytes, this.readPrefix);
  final Uri uri;
  final Map<String, String> headers;
  final int maximumBytes;
  final bool readPrefix;
}

class _Transport implements JioSaavnHttpTransport {
  _Transport({
    this.supports320 = true,
    this.arrayEnvelope = false,
    this.detailsOverride,
    this.searchRows,
    this.probe,
    this.firstSearchGate,
    this.holdAllSearches = false,
    this.apiOverride,
    this.onRequest,
  });
  final bool supports320;
  final bool arrayEnvelope;
  final Map<String, Object?>? detailsOverride;
  final List<Object?>? searchRows;
  final JioSaavnHttpResponse? probe;
  final Future<void>? firstSearchGate;
  final bool holdAllSearches;
  final JioSaavnHttpResponse? apiOverride;
  void Function(Uri)? onRequest;
  final requests = <_Request>[];
  int closes = 0;

  @override
  Future<JioSaavnHttpResponse> get(
    Uri uri, {
    Map<String, String> headers = const {},
    int maximumBytes = 512 * 1024,
    bool readPrefix = false,
    Duration? timeout,
  }) async {
    requests.add(_Request(uri, headers, maximumBytes, readPrefix));
    onRequest?.call(uri);
    if (uri.host != 'www.jiosaavn.com') return probe ?? _probe();
    if (apiOverride != null) return apiOverride!;
    final row = _row(supports320: supports320);
    final Object response;
    if (uri.queryParameters['__call'] == 'search.getResults') {
      if (requests.length == 1 || holdAllSearches) await firstSearchGate;
      response = {
        'results': searchRows ?? [row],
      };
    } else {
      final details = {...row, ...?detailsOverride};
      response = arrayEnvelope
          ? {
              'songs': [details],
            }
          : {'saavn-id': details};
    }
    return JioSaavnHttpResponse(
      statusCode: 200,
      body: Uint8List.fromList(utf8.encode(jsonEncode(response))),
    );
  }

  @override
  Future<void> close() async => closes++;
}
