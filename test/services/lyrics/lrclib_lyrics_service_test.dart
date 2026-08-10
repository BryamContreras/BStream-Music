import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/lyrics.dart';
import 'package:bstream_music/services/lyrics/lrclib_lyrics_service.dart';
import 'package:bstream_music/services/lyrics/lrclib_request_pacing.dart';
import 'package:bstream_music/services/lyrics/lrclib_transport.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _FakeTransport transport;

  setUp(() {
    transport = _FakeTransport();
  });

  LrclibLyricsService createService({
    LrclibDelay? delay,
    LrclibClock? clock,
    LrclibMonotonicClock? monotonicClock,
    Duration requestTimeout = const Duration(seconds: 10),
    Duration exactRequestTimeout = const Duration(milliseconds: 1500),
    Duration lookupTimeout = const Duration(seconds: 9),
    Duration cacheTtl = const Duration(minutes: 30),
    int maxCacheEntries = 64,
  }) {
    var virtualElapsed = Duration.zero;
    final virtualDelay = delay == null
        ? null
        : (Duration duration) async {
            await delay(duration);
            virtualElapsed += duration;
          };
    final service = LrclibLyricsService(
      userAgent: 'BStreamMusic/1.2.1 (lyrics tests)',
      transport: transport,
      delay: virtualDelay,
      clock: clock,
      monotonicClock:
          monotonicClock ?? (delay == null ? null : () => virtualElapsed),
      requestTimeout: requestTimeout,
      exactRequestTimeout: exactRequestTimeout,
      lookupTimeout: lookupTimeout,
      cacheTtl: cacheTtl,
      maxCacheEntries: maxCacheEntries,
    );
    addTearDown(service.dispose);
    return service;
  }

  test('is exposed through the LyricsService public contract', () {
    final LyricsService service = createService();
    expect(service, isA<LrclibLyricsService>());
  });

  test(
    'default manual search skips empty titles and forwards context',
    () async {
      final service = _DefaultManualSearchService();
      const context = LyricsLookup(
        title: 'Original title',
        artist: 'Context artist',
        duration: Duration(seconds: 121),
        album: 'Context album',
        sourceId: 'youtube:titan',
      );

      expect(
        await service.searchLyricsByTitle('   ', context: context),
        isEmpty,
      );
      expect(service.lookups, isEmpty);

      expect(
        await service.searchLyricsByTitle(
          '  Lady Baby Mayday  ',
          context: context,
          limit: 3,
        ),
        isEmpty,
      );
      expect(service.lookups.single.title, 'Lady Baby Mayday');
      expect(service.lookups.single.artist, context.artist);
      expect(service.lookups.single.duration, context.duration);
      expect(service.lookups.single.album, context.album);
      expect(service.lookups.single.sourceId, context.sourceId);
      expect(service.limits.single, 3);
    },
  );

  test('requires a non-empty User-Agent', () {
    expect(
      () => LrclibLyricsService(userAgent: ' ', transport: transport),
      throwsArgumentError,
    );
  });

  test('returns no lyrics for a title made only of decorations', () async {
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(title: '🤫 💙 ✨', artist: 'Channel'),
    );

    expect(result, isNull);
    expect(transport.requests, isEmpty);
  });

  test('uses cleaned Artist - Song metadata for the exact request', () async {
    transport.responder = (uri) {
      final query = uri.queryParameters;
      if (query['track_name'] == 'Me Duele Amarte' &&
          query['artist_name'] == 'Reik') {
        return _jsonResponse(
          HttpStatus.ok,
          uri.path.endsWith('/get')
              ? _record(
                  id: 17,
                  trackName: 'Me Duele Amarte',
                  artistName: 'Reik',
                  albumName: 'Secuencia',
                  duration: 194,
                  syncedLyrics: '[00:01.20]First line',
                )
              : [
                  _record(
                    id: 17,
                    trackName: 'Me Duele Amarte',
                    artistName: 'Reik',
                    albumName: 'Secuencia',
                    duration: 194,
                    syncedLyrics: '[00:01.20]First line',
                  ),
                ],
        );
      }
      return uri.path.endsWith('/get')
          ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
          : _jsonResponse(HttpStatus.ok, const []);
    };
    final service = createService(delay: (_) async {});

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Reik - Me Duele Amarte (Letra/Lyrics)',
        artist: 'Chilleando Beats',
        duration: Duration(seconds: 194),
        album: 'Secuencia',
        sourceId: 'youtube:abc',
      ),
    );

    expect(result?.provider, 'LRCLIB');
    expect(result?.providerId, '17');
    expect(result?.hasSyncedLyrics, isTrue);
    expect(result?.lines.single.timestamp, const Duration(milliseconds: 1200));
    final request = transport.requests.firstWhere(
      (request) =>
          request.uri.queryParameters['track_name'] == 'Me Duele Amarte' &&
          request.uri.queryParameters['artist_name'] == 'Reik',
    );
    expect(request.uri.path, '/api/search');
    expect(request.uri.queryParameters, {
      'track_name': 'Me Duele Amarte',
      'artist_name': 'Reik',
    });
    expect(request.headers['User-Agent'], contains('BStreamMusic'));
    expect(request.headers['Accept'], 'application/json');
  });

  test(
    'finds Song - Artist metadata with a bare lyrics suffix and unrelated channel',
    () async {
      final delays = <Duration>[];
      transport.responder = (uri) {
        final query = uri.queryParameters;
        if (query['track_name'] == 'Bonsai' &&
            query['artist_name'] ==
                'Alan Sutton y las Criaturitas de la Ansiedad') {
          return _jsonResponse(HttpStatus.ok, [
            _record(
              id: 6952743,
              trackName: 'Bonsai',
              artistName: 'Alan Sutton y las criaturitas de la ansiedad',
              albumName: 'Algo Tiene Que Cambiar',
              duration: 188,
              syncedLyrics: '[00:08.10]Aunque esté todo mal',
            ),
          ]);
        }
        return uri.path.endsWith('/get')
            ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
            : _jsonResponse(HttpStatus.ok, const []);
      };
      final service = createService(
        delay: (duration) async {
          delays.add(duration);
        },
      );

      final result = await service.findLyrics(
        const LyricsLookup(
          title:
              'Bonsai - Alan Sutton y las Criaturitas de la Ansiedad // Letra',
          artist: 'Canciones Que Debes Escuchar Antes de Morir',
          duration: Duration(seconds: 186),
          sourceId: 'youtube:bonsai',
        ),
      );

      expect(result?.providerId, '6952743');
      expect(result?.hasSyncedLyrics, isTrue);
      expect(delays, isNotEmpty);
      expect(transport.requests.length, lessThanOrEqualTo(6));
      expect(
        transport.requests.any((request) {
          final query = request.uri.queryParameters;
          return query['track_name'] == 'Bonsai' &&
              query['artist_name'] ==
                  'Alan Sutton y las Criaturitas de la Ansiedad';
        }),
        isTrue,
      );
    },
  );

  test(
    'broad search scores composite LRCLIB titles against both orientations',
    () async {
      final delays = <Duration>[];
      transport.responder = (uri) {
        if (uri.queryParameters['q'] ==
            'Bonsai Alan Sutton y las Criaturitas de la Ansiedad') {
          return _jsonResponse(HttpStatus.ok, [
            _record(
              id: 34743956,
              trackName:
                  'BONSAI (Videolyric) - Alan Sutton y las criaturitas de la ansiedad',
              artistName: 'Alan Sutton y las criaturitas de la ansiedad',
              duration: 189,
              syncedLyrics: '[00:08.10]Line',
            ),
          ]);
        }
        return uri.path.endsWith('/get')
            ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
            : _jsonResponse(HttpStatus.ok, const []);
      };
      final service = createService(
        delay: (duration) async {
          delays.add(duration);
        },
      );

      final result = await service.findLyrics(
        const LyricsLookup(
          title:
              'Bonsai - Alan Sutton y las Criaturitas de la Ansiedad | Lyrics',
          artist: 'A lyrics channel',
          duration: Duration(seconds: 186),
        ),
      );

      expect(result?.providerId, '34743956');
      expect(delays, isNotEmpty);
      expect(
        delays.every((delay) => delay == const Duration(milliseconds: 250)),
        isTrue,
      );
      expect(transport.requests.last.uri.queryParameters, {
        'q': 'Bonsai Alan Sutton y las Criaturitas de la Ansiedad',
      });
    },
  );

  test(
    'removes decorative emoji and retries a title without parenthetical blocks',
    () async {
      transport
        ..enqueue(_jsonResponse(HttpStatus.notFound, {'message': 'missing'}))
        ..enqueue(_jsonResponse(HttpStatus.ok, const []))
        ..enqueue(
          _jsonResponse(HttpStatus.ok, [
            _record(
              id: 100,
              trackName: 'Palabras Sobran',
              artistName: 'Blessd',
              duration: 228,
              syncedLyrics: '[00:01.00]Line',
            ),
          ]),
        );
      final service = createService(delay: (_) async {});

      final result = await service.findLyrics(
        const LyricsLookup(
          title: 'BLESSD | 🤫 PALABRAS SOBRAN ( VIAJE 2 )',
          artist: 'SIEMPRE BLESSD 💙',
          duration: Duration(seconds: 229),
        ),
      );

      expect(result?.providerId, '100');
      expect(transport.requests, hasLength(3));
      expect(transport.requests[0].uri.queryParameters, {
        'track_name': 'PALABRAS SOBRAN ( VIAJE 2 )',
        'artist_name': 'BLESSD',
        'duration': '229',
      });
      expect(transport.requests[1].uri.queryParameters, {
        'track_name': 'PALABRAS SOBRAN ( VIAJE 2 )',
        'artist_name': 'BLESSD',
      });
      expect(transport.requests[2].uri.queryParameters, {
        'track_name': 'PALABRAS SOBRAN',
        'artist_name': 'BLESSD',
      });
      expect(
        transport.requests.every(
          (request) => !request.uri.toString().contains('🤫'),
        ),
        isTrue,
      );
    },
  );

  test('extracts collaborators and title around adjacent emoji', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 101,
          trackName: 'Palabras Sobran [Remix]',
          artistName: 'Blessd',
          duration: 304,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title:
            'BLESSD❌RYAN CASTRO❌BRYANT MYERS❌HADES 66 '
            '👀💙PALABRAS SOBRAN REMIX (VIDEO OFICIAL)',
        artist: 'SIEMPRE BLESSD 💙',
        duration: Duration(seconds: 304),
      ),
    );

    expect(result?.providerId, '101');
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': 'PALABRAS SOBRAN REMIX',
      'artist_name': 'BLESSD',
      'duration': '304',
    });
  });

  test('uses the leading title before a double-pipe subtitle', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 102,
          trackName: 'Yo Soy Tu Titán (Lady Baby Mayday)',
          artistName: 'Pamorkil',
          duration: 121,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title:
            'YO SOY TU TITÁN || Mikasa Music Waifu #1 - '
            'Pamorkil (Lyric Video)',
        artist: 'Pamorkil',
        duration: Duration(seconds: 121),
      ),
    );

    expect(result?.providerId, '102');
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': 'YO SOY TU TITÁN',
      'artist_name': 'Pamorkil',
      'duration': '121',
    });
  });

  test('finds the real Barak title around quoted pipe decorations', () async {
    // LRCLIB currently returns 404 for /get with this identity, but its
    // structured /search endpoint contains the exact synchronized record.
    transport.responder = (uri) {
      final query = uri.queryParameters;
      if (query['track_name'] == 'Libre Soy' &&
          query['artist_name'] == 'Barak') {
        return _jsonResponse(HttpStatus.ok, [
          _record(
            id: 35562385,
            trackName: 'Libre Soy (feat. Alex Campos)',
            artistName: 'BARAK',
            albumName: 'BARAK Videos',
            duration: 308,
            syncedLyrics: '[00:20.99]¡Dilo conmigo!',
          ),
        ]);
      }
      return uri.path.endsWith('/get')
          ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
          : _jsonResponse(HttpStatus.ok, const []);
    };
    final service = createService(delay: (_) async {});

    final result = await service.findLyrics(
      const LyricsLookup(
        title:
            'Barak ft. Alex Campos -  Libre Soy  | "Video Oficial"| '
            'Radical Live',
        artist: 'Grupo Barak',
        duration: Duration(seconds: 308),
        sourceId: 'youtube:053BvHDfIdI',
      ),
    );

    expect(result?.providerId, '35562385');
    expect(
      transport.requests.any((request) {
        final query = request.uri.queryParameters;
        return query['track_name'] == 'Libre Soy' &&
            query['artist_name'] == 'Barak';
      }),
      isTrue,
    );
  });

  test(
    'accepts small spelling differences with corroborating artist',
    () async {
      transport
        ..enqueue(_jsonResponse(HttpStatus.notFound, {'message': 'missing'}))
        ..enqueue(
          _jsonResponse(HttpStatus.ok, [
            _record(
              id: 120,
              trackName: 'Palabras Sobran',
              artistName: 'Blessd',
              duration: 228,
              syncedLyrics: '[00:01.00]Line',
            ),
          ]),
        )
        ..enqueue(_jsonResponse(HttpStatus.ok, const []));
      final service = createService(delay: (_) async {});

      final result = await service.findLyrics(
        const LyricsLookup(
          title: 'Palabraz Sobram',
          artist: 'Blessd',
          duration: Duration(seconds: 228),
        ),
      );

      expect(result?.providerId, '120');
    },
  );

  test(
    'rejects a generic one-word overlap despite matching metadata',
    () async {
      transport.responder = (uri) {
        if (uri.path.endsWith('/get')) {
          return _jsonResponse(HttpStatus.notFound, {'message': 'missing'});
        }
        return _jsonResponse(HttpStatus.ok, [
          _record(
            id: 121,
            trackName: 'Titán Hardcore',
            artistName: 'Pamorkil',
            duration: 121,
            syncedLyrics: '[00:01.00]Wrong song',
          ),
        ]);
      };
      final service = createService(delay: (_) async {});

      final result = await service.findLyrics(
        const LyricsLookup(
          title: 'Yo Soy Tu Titán',
          artist: 'Pamorkil',
          duration: Duration(seconds: 121),
        ),
      );

      expect(result, isNull);
    },
  );

  test(
    'aggregates similar searches, deduplicates, and excludes unsafe results',
    () async {
      transport.responder = (uri) {
        final query = uri.queryParameters['q'] ?? '';
        if (query == 'Barak Libre Soy') {
          return _jsonResponse(HttpStatus.ok, [
            _record(
              id: 130,
              trackName: 'Libre Para Siempre',
              artistName: 'BARAK',
              duration: 308,
              plainLyrics: 'Plain duplicate',
            ),
            _record(
              id: 133,
              trackName: 'Dancing in the Dark',
              artistName: 'Someone Else',
              duration: 600,
              syncedLyrics: '[00:01.00]Wrong song',
            ),
            _record(
              id: 134,
              trackName: 'Libre Soy',
              artistName: 'Barak',
              duration: 308,
              instrumental: true,
            ),
          ]);
        }
        if (query.contains('Alex Campos')) {
          return _jsonResponse(HttpStatus.ok, [
            _record(
              id: 135,
              trackName: 'Libre Para Siempre',
              artistName: 'BARAK',
              duration: 308,
              syncedLyrics: '[00:01.00]Repeated from another query',
            ),
            _record(
              id: 132,
              trackName: 'Libre Soy (feat. Alex Campos)',
              artistName: 'Barak',
              duration: 308,
              syncedLyrics: '[00:01.00]Featured version',
            ),
          ]);
        }
        return _jsonResponse(HttpStatus.ok, const []);
      };
      final service = createService();

      final result = await service.findSimilarLyrics(
        const LyricsLookup(
          title:
              'Barak ft. Alex Campos - Libre Soy | "Video Oficial"| '
              'Radical Live',
          artist: 'Grupo Barak',
          duration: Duration(seconds: 308),
        ),
      );

      expect(transport.requests.length, inInclusiveRange(2, 5));
      expect(transport.requests.first.uri.path, '/api/search');
      expect(transport.requests.first.uri.queryParameters, {
        'q': 'Barak Libre Soy',
      });
      expect(
        transport.requests
            .map((request) => request.uri.queryParameters['q'])
            .whereType<String>(),
        contains(predicate<String>((query) => query.contains('Alex Campos'))),
      );
      expect(result.map((candidate) => candidate.document.providerId), {
        '135',
        '132',
      });
      expect(
        result.every((candidate) => candidate.document.hasSyncedLyrics),
        isTrue,
      );
    },
  );

  test('manual title search finds an alias and uses only its text', () async {
    transport.enqueue(
      _jsonResponse(HttpStatus.ok, [
        _record(
          id: 140,
          trackName: 'Yo Soy Tu Titán (Lady Baby Mayday)',
          artistName: 'Pamorkil',
          duration: 121,
          syncedLyrics: '[00:01.00]Soy tu titán',
        ),
      ]),
    );
    final service = createService();

    final result = await service.searchLyricsByTitle(
      'Lady Baby Mayday',
      context: const LyricsLookup(
        title: 'YO SOY TU TITÁN || Mikasa Music Waifu #1',
        artist: 'Pamorkil',
        duration: Duration(seconds: 122),
      ),
    );

    expect(result.single.document.providerId, '140');
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.uri.path, '/api/search');
    expect(transport.requests.single.uri.queryParameters, {
      'q': 'Lady Baby Mayday',
    });
  });

  test('manual title search does no request for empty input', () async {
    final service = createService();

    expect(
      await service.searchLyricsByTitle(
        '   ',
        context: const LyricsLookup(title: 'Song', artist: 'Artist'),
      ),
      isEmpty,
    );
    expect(transport.requests, isEmpty);
  });

  test(
    'manual title search deduplicates results and obeys its limit',
    () async {
      transport.enqueue(
        _jsonResponse(HttpStatus.ok, [
          _record(
            id: 141,
            trackName: 'Yo Soy Tu Titán',
            artistName: 'Pamorkil',
            duration: 121,
            plainLyrics: 'Plain duplicate',
          ),
          _record(
            id: 142,
            trackName: 'Yo Soy Tu Titán',
            artistName: 'Pamorkil',
            duration: 121,
            syncedLyrics: '[00:01.00]Synced duplicate',
          ),
          _record(
            id: 143,
            trackName: 'Yo Soy Tu Titán Remix',
            artistName: 'Pamorkil',
            duration: 151,
            syncedLyrics: '[00:01.00]Remix',
          ),
          _record(
            id: 144,
            trackName: 'Yo Soy Tu Titán Acoustic',
            artistName: 'Pamorkil',
            duration: 181,
            syncedLyrics: '[00:01.00]Acoustic',
          ),
        ]),
      );
      final service = createService();

      final result = await service.searchLyricsByTitle(
        'Yo Soy Tu Titan',
        context: const LyricsLookup(
          title: 'Noisy YouTube title',
          artist: 'Pamorkil',
          duration: Duration(seconds: 121),
        ),
        limit: 2,
      );

      expect(result, hasLength(2));
      expect(
        result.map((candidate) => candidate.document.providerId),
        contains('142'),
      );
      expect(
        result.map((candidate) => candidate.document.providerId),
        isNot(contains('141')),
      );
    },
  );

  test(
    'similar lyrics fall back to safe artist alternatives of other lengths',
    () async {
      transport.responder = (uri) {
        if (uri.queryParameters['q'] != 'Pamorkil') {
          return _jsonResponse(HttpStatus.ok, const []);
        }
        return _jsonResponse(HttpStatus.ok, [
          _record(
            id: 145,
            trackName: 'Titán Hardcore',
            artistName: 'Pamorkil',
            duration: 155,
            syncedLyrics: '[00:01.00]Hardcore',
          ),
          _record(
            id: 146,
            trackName: 'Yo Soy Tu Titán Acoustic',
            artistName: 'Pamorkil',
            duration: 159,
            plainLyrics: 'Acoustic version',
          ),
          _record(
            id: 147,
            trackName: 'Yo Soy Tu Titán',
            artistName: 'Someone Else',
            duration: 121,
            syncedLyrics: '[00:01.00]Unsafe alternative',
          ),
        ]);
      };
      final service = createService(delay: (_) async {});

      final result = await service.findSimilarLyrics(
        const LyricsLookup(
          title: 'YO SOY TU TITÁN || Mikasa Music Waifu #1 - Pamorkil',
          artist: 'Pamorkil',
          duration: Duration(seconds: 121),
        ),
      );

      expect(transport.requests.last.uri.queryParameters, {'q': 'Pamorkil'});
      expect(result.map((candidate) => candidate.document.providerId), {
        '145',
        '146',
      });
    },
  );

  test(
    'similar lyrics omit an unreliable channel name from the query',
    () async {
      transport.enqueue(
        _jsonResponse(HttpStatus.ok, [
          _record(
            id: 135,
            trackName: 'Libre Soy',
            artistName: 'Carmen Sarahí',
            duration: 225,
            syncedLyrics: '[00:01.00]Libre soy',
          ),
        ]),
      );
      final service = createService();

      final result = await service.findSimilarLyrics(
        const LyricsLookup(
          title: 'Libre Soy',
          artist: 'DisneyMusicLAVEVO',
          duration: Duration(seconds: 227),
        ),
      );

      expect(result.single.document.providerId, '135');
      expect(transport.requests.single.uri.queryParameters, {'q': 'Libre Soy'});
    },
  );

  test('falls back to title-only search for a channel-like artist', () async {
    transport
      ..enqueue(_jsonResponse(HttpStatus.notFound, {'message': 'missing'}))
      ..enqueue(_jsonResponse(HttpStatus.ok, const []))
      ..enqueue(
        _jsonResponse(HttpStatus.ok, [
          _record(
            id: 103,
            trackName: 'Libre Soy',
            artistName: 'Carmen Sarahí',
            duration: 225,
            syncedLyrics: '[00:01.00]Line',
          ),
        ]),
      );
    final service = createService(delay: (_) async {});

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Libre Soy',
        artist: 'DisneyMusicLAVEVO',
        duration: Duration(seconds: 227),
      ),
    );

    expect(result?.providerId, '103');
    expect(transport.requests, hasLength(3));
    expect(transport.requests[1].uri.queryParameters, {
      'track_name': 'Libre Soy',
      'artist_name': 'DisneyMusicLA',
    });
    expect(transport.requests[2].uri.queryParameters, {
      'track_name': 'Libre Soy',
    });
  });

  test('preserves non-Latin artist and title text in requests', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 104,
          trackName: '光',
          artistName: '宇多田ヒカル',
          duration: 309,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: '宇多田ヒカル - 光 ✨',
        artist: '宇多田ヒカル',
        duration: Duration(seconds: 309),
      ),
    );

    expect(result?.providerId, '104');
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': '光',
      'artist_name': '宇多田ヒカル',
      'duration': '309',
    });
  });

  test('does not split slashes or hyphens inside artist names', () async {
    transport
      ..enqueue(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: 105,
            trackName: 'Back in Black',
            artistName: 'AC/DC',
            duration: 255,
            syncedLyrics: '[00:01.00]Line',
          ),
        ),
      )
      ..enqueue(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: 106,
            trackName: 'All the Small Things',
            artistName: 'blink-182',
            duration: 168,
            syncedLyrics: '[00:01.00]Line',
          ),
        ),
      );
    final firstService = createService();
    final secondService = createService();

    await firstService.findLyrics(
      const LyricsLookup(
        title: 'AC/DC - Back in Black',
        artist: 'AC/DC',
        duration: Duration(seconds: 255),
      ),
    );
    await secondService.findLyrics(
      const LyricsLookup(
        title: 'blink-182 - All the Small Things',
        artist: 'blink-182',
        duration: Duration(seconds: 168),
      ),
    );

    expect(transport.requests[0].uri.queryParameters['artist_name'], 'AC/DC');
    expect(
      transport.requests[1].uri.queryParameters['artist_name'],
      'blink-182',
    );
  });

  test('keeps an internal dash as part of the real track title', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 150,
          trackName: 'Love - Part II',
          artistName: 'MitiS',
          duration: 226,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Love - Part II',
        artist: 'MitiS',
        duration: Duration(seconds: 226),
      ),
    );

    expect(result?.providerId, '150');
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': 'Love - Part II',
      'artist_name': 'MitiS',
      'duration': '226',
    });
  });

  test('keeps an ordinary compact hyphenated title intact', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 161,
          trackName: 'Self-Control',
          artistName: 'Laura Branigan',
          duration: 246,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Self-Control',
        artist: 'Laura Branigan',
        duration: Duration(seconds: 246),
      ),
    );

    expect(result?.providerId, '161');
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': 'Self-Control',
      'artist_name': 'Laura Branigan',
      'duration': '246',
    });
  });

  test(
    'uses a duration-safe title-only fallback for an unknown uploader',
    () async {
      transport.responder = (uri) {
        final query = uri.queryParameters;
        if (query['track_name'] == 'Libre Soy' &&
            !query.containsKey('artist_name')) {
          return _jsonResponse(HttpStatus.ok, [
            _record(
              id: 162,
              trackName: 'Libre Soy',
              artistName: 'Carmen Sarahí',
              duration: 225,
              syncedLyrics: '[00:01.00]Line',
            ),
          ]);
        }
        return uri.path.endsWith('/get')
            ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
            : _jsonResponse(HttpStatus.ok, const []);
      };
      final service = createService(delay: (_) async {});

      final result = await service.findLyrics(
        const LyricsLookup(
          title: 'Libre Soy',
          artist: 'Fans Music',
          duration: Duration(seconds: 227),
        ),
      );

      expect(result?.providerId, '162');
      expect(
        transport.requests.any((request) {
          final query = request.uri.queryParameters;
          return query['track_name'] == 'Libre Soy' &&
              !query.containsKey('artist_name');
        }),
        isTrue,
      );
    },
  );

  test(
    'does not auto-select a title-only cover without duration evidence',
    () async {
      transport.responder = (uri) {
        final query = uri.queryParameters;
        if (query['track_name'] == 'Hello' &&
            !query.containsKey('artist_name')) {
          return _jsonResponse(HttpStatus.ok, [
            _record(
              id: 163,
              trackName: 'Hello',
              artistName: 'Unrelated Cover Artist',
              syncedLyrics: '[00:01.00]Wrong cover',
            ),
          ]);
        }
        return _jsonResponse(HttpStatus.ok, const []);
      };
      final service = createService(delay: (_) async {});

      final result = await service.findLyrics(
        const LyricsLookup(title: 'Hello', artist: 'Fans Music'),
      );

      expect(result, isNull);
    },
  );

  test('orients compact and symbolic title-artist separators', () async {
    const cases = <String>[
      'Artist|Song',
      'Song—Artist',
      'Artist : Song',
      'Artist • Song',
      'Artist//Song',
      'Artist-Song',
    ];

    for (final title in cases) {
      transport = _FakeTransport();
      transport.enqueue(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: title,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            syncedLyrics: '[00:01.00]Line',
          ),
        ),
      );
      final service = createService();

      final result = await service.findLyrics(
        LyricsLookup(
          title: title,
          artist: 'Artist',
          duration: const Duration(seconds: 180),
        ),
      );

      expect(result?.providerId, title, reason: title);
      expect(transport.requests.single.uri.queryParameters, {
        'track_name': 'Song',
        'artist_name': 'Artist',
        'duration': '180',
      }, reason: title);
    }
  });

  test(
    'normalizes ft inside a title before falling back to its base',
    () async {
      transport.responder = (uri) {
        final query = uri.queryParameters;
        if (query['track_name'] == 'Starboy feat. Daft Punk' &&
            query['artist_name'] == 'The Weeknd') {
          return _jsonResponse(HttpStatus.ok, [
            _record(
              id: 151,
              trackName: 'Starboy (feat. Daft Punk)',
              artistName: 'The Weeknd',
              duration: 230,
              syncedLyrics: '[00:01.00]Line',
            ),
          ]);
        }
        return uri.path.endsWith('/get')
            ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
            : _jsonResponse(HttpStatus.ok, const []);
      };
      final service = createService(delay: (_) async {});

      final result = await service.findLyrics(
        const LyricsLookup(
          title: 'The Weeknd - Starboy ft.Daft Punk',
          artist: 'The Weeknd',
          duration: Duration(seconds: 230),
        ),
      );

      expect(
        transport.requests.map((request) => request.uri.queryParameters),
        contains(containsPair('track_name', 'Starboy feat. Daft Punk')),
      );
      expect(result?.providerId, '151');
    },
  );

  test('strips an anchored VEVO suffix without changing the title', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 152,
          trackName: 'Hello',
          artistName: 'Adele',
          duration: 295,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Hello',
        artist: 'AdeleVEVO',
        duration: Duration(seconds: 295),
      ),
    );

    expect(result?.providerId, '152');
    expect(
      transport.requests.single.uri.queryParameters['artist_name'],
      'Adele',
    );
  });

  test('extracts a Japanese quoted title and preserves its script', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 153,
          trackName: 'アイドル',
          artistName: 'YOASOBI',
          duration: 213,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'YOASOBI「アイドル」Official Music Video',
        artist: 'YOASOBI',
        duration: Duration(seconds: 213),
      ),
    );

    expect(result?.providerId, '153');
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': 'アイドル',
      'artist_name': 'YOASOBI',
      'duration': '213',
    });
  });

  test('folds broad Latin accents only for local matching', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 154,
          trackName: 'Dung Lam Trai Tim Anh Dau',
          artistName: 'Son Tung M-TP',
          duration: 279,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Sơn Tùng M-TP - Đừng Làm Trái Tim Anh Đau',
        artist: 'Sơn Tùng M-TP',
        duration: Duration(seconds: 279),
      ),
    );

    expect(result?.providerId, '154');
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': 'Đừng Làm Trái Tim Anh Đau',
      'artist_name': 'Sơn Tùng M-TP',
      'duration': '279',
    });
  });

  test('preserves Arabic while ignoring vocal marks for matching', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 155,
          trackName: 'نسم علينا الهوى',
          artistName: 'فيروز',
          duration: 247,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'فيروز — نَسَم علينا الهوى',
        artist: 'فيروز',
        duration: Duration(seconds: 247),
      ),
    );

    expect(result?.providerId, '155');
    expect(
      transport.requests.single.uri.queryParameters['track_name'],
      'نَسَم علينا الهوى',
    );
  });

  test('drops an unknown-language trailing presentation segment', () async {
    transport.responder = (uri) {
      final query = uri.queryParameters;
      if (query['track_name'] == 'Полковнику никто не пишет' &&
          query['artist_name'] == 'Би-2') {
        return _jsonResponse(HttpStatus.ok, [
          _record(
            id: 156,
            trackName: 'Полковнику никто не пишет',
            artistName: 'Би-2',
            duration: 291,
            syncedLyrics: '[00:01.00]Line',
          ),
        ]);
      }
      return uri.path.endsWith('/get')
          ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
          : _jsonResponse(HttpStatus.ok, const []);
    };
    final service = createService(delay: (_) async {});

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Би-2 — Полковнику никто не пишет — официальный клип',
        artist: 'Би-2',
        duration: Duration(seconds: 291),
      ),
    );

    expect(result?.providerId, '156');
    expect(
      transport.requests.any((request) {
        final query = request.uri.queryParameters;
        return query['track_name'] == 'Полковнику никто не пишет' &&
            query['artist_name'] == 'Би-2';
      }),
      isTrue,
    );
  });

  test('rejects a conflicting numbered work', () async {
    transport.responder = (uri) {
      if (uri.path.endsWith('/get')) {
        return _jsonResponse(HttpStatus.notFound, {'message': 'missing'});
      }
      return _jsonResponse(HttpStatus.ok, [
        _record(
          id: 157,
          trackName: 'Symphony No. 9',
          artistName: 'Composer',
          duration: 180,
          syncedLyrics: '[00:01.00]Wrong work',
        ),
      ]);
    };
    final service = createService(delay: (_) async {});

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Symphony No. 5',
        artist: 'Composer',
        duration: Duration(seconds: 180),
      ),
    );

    expect(result, isNull);
  });

  test('similar lookup keeps searching after one strong candidate', () async {
    var calls = 0;
    transport.responder = (_) {
      calls++;
      if (calls == 1) {
        return _jsonResponse(HttpStatus.ok, [
          _record(
            id: 158,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            syncedLyrics: '[00:01.00]Exact',
          ),
        ]);
      }
      return _jsonResponse(HttpStatus.ok, [
        _record(
          id: 159,
          trackName: 'Song (Acoustic)',
          artistName: 'Artist',
          duration: 182,
          syncedLyrics: '[00:01.00]Acoustic',
        ),
        _record(
          id: 160,
          trackName: 'Song (Live)',
          artistName: 'Artist',
          duration: 184,
          syncedLyrics: '[00:01.00]Live',
        ),
      ]);
    };
    final service = createService(delay: (_) async {});

    final result = await service.findSimilarLyrics(
      const LyricsLookup(
        title: 'Artist - Song',
        artist: 'Artist',
        duration: Duration(seconds: 180),
      ),
    );

    expect(calls, greaterThan(1));
    expect(result.map((candidate) => candidate.document.providerId), {
      '158',
      '159',
      '160',
    });
  });

  test(
    'prefers a matching remix over an otherwise identical original',
    () async {
      transport
        ..enqueue(_jsonResponse(HttpStatus.notFound, {'message': 'missing'}))
        ..enqueue(
          _jsonResponse(HttpStatus.ok, [
            _record(
              id: 107,
              trackName: 'Song',
              artistName: 'Artist',
              duration: 180,
              syncedLyrics: '[00:01.00]Original',
            ),
            _record(
              id: 108,
              trackName: 'Song (Remix)',
              artistName: 'Artist',
              duration: 180,
              syncedLyrics: '[00:01.00]Remix',
            ),
          ]),
        );
      final service = createService();

      final result = await service.findLyrics(
        const LyricsLookup(
          title: 'Artist - Song (Remix)',
          artist: 'Artist',
          duration: Duration(seconds: 180),
        ),
      );

      expect(result?.providerId, '108');
    },
  );

  test('deduplicates variants and never exceeds six lookup requests', () async {
    for (var index = 0; index < 6; index++) {
      transport.enqueue(
        index == 0
            ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
            : _jsonResponse(HttpStatus.ok, const []),
      );
    }
    final service = createService(delay: (_) async {});

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'BLESSD | 🤫 PALABRAS SOBRAN ( VIAJE 2 )',
        artist: 'SIEMPRE BLESSD 💙',
        duration: Duration(seconds: 229),
      ),
    );

    expect(result, isNull);
    expect(transport.requests.length, lessThanOrEqualTo(6));
    expect(
      transport.requests.map((request) => request.uri.toString()).toSet(),
      hasLength(transport.requests.length),
    );
  });

  test('searches by title when artist metadata is unavailable', () async {
    transport.enqueue(
      _jsonResponse(HttpStatus.ok, [
        _record(
          id: 90,
          trackName: 'Song',
          artistName: 'Actual Artist',
          duration: 180,
          syncedLyrics: '[00:01.00]Line',
        ),
      ]),
    );
    final service = createService();

    final result = await service.findLyrics(
      const LyricsLookup(
        title: 'Song // Letra',
        artist: 'Desconocido',
        duration: Duration(seconds: 180),
      ),
    );

    expect(result?.providerId, '90');
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.uri.queryParameters, {
      'track_name': 'Song',
    });
  });

  for (final status in [HttpStatus.badRequest, HttpStatus.notFound]) {
    test(
      'HTTP $status from exact lookup falls back to structured search',
      () async {
        transport
          ..enqueue(_jsonResponse(status, {'message': 'not found'}))
          ..enqueue(
            _jsonResponse(HttpStatus.ok, [
              _record(
                id: 2,
                trackName: 'Song',
                artistName: 'Artist',
                duration: 180,
                plainLyrics: 'Plain lyrics',
              ),
            ]),
          );
        final service = createService();

        final result = await service.findLyrics(_lookup());

        expect(result?.plainLyrics, 'Plain lyrics');
        expect(transport.requests.map((request) => request.uri.path), [
          '/api/get',
          '/api/search',
        ]);
        expect(transport.requests.last.uri.queryParameters, {
          'track_name': 'Song',
          'artist_name': 'Artist',
        });
      },
    );
  }

  test('skips exact lookup when duration is unavailable', () async {
    transport.enqueue(
      _jsonResponse(HttpStatus.ok, [
        _record(
          id: 3,
          trackName: 'Song',
          artistName: 'Artist',
          syncedLyrics: '[00:01.00]Line',
        ),
      ]),
    );
    final service = createService();

    await service.findLyrics(
      const LyricsLookup(title: 'Song', artist: 'Artist'),
    );

    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.uri.path, '/api/search');
    expect(
      transport.requests.single.uri.queryParameters.containsKey('album_name'),
      isFalse,
    );
  });

  test('runs at most one broad search after waiting 250 ms', () async {
    final delays = <Duration>[];
    transport
      ..enqueue(_jsonResponse(HttpStatus.notFound, {'message': 'missing'}))
      ..enqueue(
        _jsonResponse(HttpStatus.ok, [
          _record(
            id: 4,
            trackName: 'Completely Different',
            artistName: 'Another Artist',
            duration: 180,
            syncedLyrics: '[00:01.00]Wrong',
          ),
        ]),
      )
      ..enqueue(_jsonResponse(HttpStatus.ok, const []))
      ..enqueue(
        _jsonResponse(HttpStatus.ok, [
          _record(
            id: 5,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            syncedLyrics: '[00:01.00]Correct',
          ),
        ]),
      );
    final service = createService(
      delay: (duration) async {
        delays.add(duration);
      },
    );

    final result = await service.findLyrics(_lookup());

    expect(result?.providerId, '5');
    expect(delays, const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 250),
      Duration(milliseconds: 250),
    ]);
    expect(transport.requests, hasLength(4));
    expect(transport.requests.last.uri.path, '/api/search');
    expect(transport.requests.last.uri.queryParameters, {'q': 'Artist Song'});
  });

  test(
    'returns null after structured and broad searches have no match',
    () async {
      transport.responder = (uri) => uri.path.endsWith('/get')
          ? _jsonResponse(HttpStatus.notFound, {'message': 'missing'})
          : _jsonResponse(HttpStatus.ok, const []);
      final service = createService(delay: (_) async {});

      final result = await service.findLyrics(_lookup());

      expect(result, isNull);
      expect(transport.requests, hasLength(4));
    },
  );

  test(
    'prefers synchronized lyrics between equally matching records',
    () async {
      transport
        ..enqueue(_jsonResponse(HttpStatus.notFound, {'message': 'missing'}))
        ..enqueue(
          _jsonResponse(HttpStatus.ok, [
            _record(
              id: 10,
              trackName: 'Song',
              artistName: 'Artist',
              duration: 180,
              plainLyrics: 'Plain only',
            ),
            _record(
              id: 11,
              trackName: 'Song',
              artistName: 'Artist',
              duration: 180,
              syncedLyrics: '[00:01.00]Synced',
            ),
          ]),
        );
      final service = createService();

      final result = await service.findLyrics(_lookup());

      expect(result?.providerId, '11');
      expect(result?.hasSyncedLyrics, isTrue);
      expect(transport.requests, hasLength(2));
    },
  );

  test(
    'rejects a large duration mismatch and continues to broad search',
    () async {
      final delays = <Duration>[];
      transport
        ..enqueue(_jsonResponse(HttpStatus.notFound, {'message': 'missing'}))
        ..enqueue(
          _jsonResponse(HttpStatus.ok, [
            _record(
              id: 20,
              trackName: 'Song',
              artistName: 'Artist',
              duration: 260,
              syncedLyrics: '[00:01.00]Wrong version',
            ),
          ]),
        )
        ..enqueue(
          _jsonResponse(HttpStatus.ok, [
            _record(
              id: 21,
              trackName: 'Song',
              artistName: 'Artist',
              duration: 181,
              syncedLyrics: '[00:01.00]Right version',
            ),
          ]),
        );
      final service = createService(
        delay: (duration) async {
          delays.add(duration);
        },
      );

      final result = await service.findLyrics(_lookup());

      expect(result?.providerId, '21');
      expect(delays, const [
        Duration(milliseconds: 250),
        Duration(milliseconds: 250),
      ]);
    },
  );

  test('treats an exact instrumental response as valid content', () async {
    transport.enqueue(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 30,
          trackName: 'Song',
          artistName: 'Artist',
          duration: 180,
          instrumental: true,
        ),
      ),
    );
    final service = createService();

    final result = await service.findLyrics(_lookup());

    expect(result?.instrumental, isTrue);
    expect(result?.hasContent, isTrue);
    expect(transport.requests, hasLength(1));
  });

  test(
    'returns numeric Retry-After immediately and keeps a cooldown',
    () async {
      final delays = <Duration>[];
      transport.enqueue(
        _jsonResponse(
          HttpStatus.tooManyRequests,
          {'message': 'slow down'},
          headers: {'Retry-After': '2'},
        ),
      );
      final service = createService(
        delay: (duration) async {
          delays.add(duration);
        },
      );

      await expectLater(
        service.findLyrics(_lookup()),
        throwsA(
          isA<LrclibRateLimitException>().having(
            (error) => error.retryAfter,
            'retryAfter',
            const Duration(seconds: 2),
          ),
        ),
      );
      await expectLater(
        service.findLyrics(_lookup()),
        throwsA(isA<LrclibRateLimitException>()),
      );

      expect(delays, isEmpty);
      expect(transport.requests, hasLength(1));
    },
  );

  test('returns an HTTP-date Retry-After without sleeping', () async {
    final now = DateTime.utc(2026, 8, 3, 12);
    final delays = <Duration>[];
    transport.enqueue(
      _jsonResponse(
        HttpStatus.tooManyRequests,
        {'message': 'slow down'},
        headers: {
          'Retry-After': HttpDate.format(now.add(const Duration(seconds: 5))),
        },
      ),
    );
    final service = createService(
      clock: () => now,
      delay: (duration) async {
        delays.add(duration);
      },
    );

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(
        isA<LrclibRateLimitException>().having(
          (error) => error.retryAfter,
          'retryAfter',
          const Duration(seconds: 5),
        ),
      ),
    );

    expect(delays, isEmpty);
    expect(transport.requests, hasLength(1));
  });

  test('starts Retry-After cooldown when the response is received', () async {
    var now = DateTime.utc(2026, 8, 3, 12);
    transport.responder = (_) {
      now = now.add(const Duration(seconds: 3));
      return _jsonResponse(
        HttpStatus.tooManyRequests,
        {'message': 'slow down'},
        headers: {'Retry-After': '5'},
      );
    };
    final service = createService(clock: () => now);

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(isA<LrclibRateLimitException>()),
    );
    now = now.add(const Duration(seconds: 4));
    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(
        isA<LrclibRateLimitException>().having(
          (error) => error.retryAfter,
          'retryAfter',
          const Duration(seconds: 1),
        ),
      ),
    );

    expect(transport.requests, hasLength(1));
  });

  test('throws a rate-limit error when Retry-After is absent', () async {
    transport.enqueue(
      _jsonResponse(HttpStatus.tooManyRequests, {'message': 'slow down'}),
    );
    final service = createService();

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(isA<LrclibRateLimitException>()),
    );
  });

  test('maps socket failures to a lyrics connection error', () async {
    transport.enqueueFuture(
      Future<LrclibResponse>.error(const SocketException('offline')),
    );
    final service = createService();

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(
        isA<LyricsConnectionException>().having(
          (error) => error.cause,
          'cause',
          isA<SocketException>(),
        ),
      ),
    );
  });

  test('maps request timeouts to a lyrics connection error', () async {
    final pendingResponse = Completer<LrclibResponse>();
    transport.enqueueFuture(pendingResponse.future);
    final service = createService(
      requestTimeout: const Duration(milliseconds: 10),
    );

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(
        isA<LyricsConnectionException>().having(
          (error) => error.cause,
          'cause',
          isA<TimeoutException>(),
        ),
      ),
    );
  });

  test('abandons a slow exact endpoint and uses broad search', () async {
    final pendingExact = Completer<LrclibResponse>();
    transport
      ..enqueueFuture(pendingExact.future)
      ..enqueue(
        _jsonResponse(HttpStatus.ok, [
          _record(
            id: 42,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            syncedLyrics: '[00:01.00]Line',
          ),
        ]),
      );
    final service = createService(
      requestTimeout: const Duration(milliseconds: 100),
      exactRequestTimeout: const Duration(milliseconds: 20),
      lookupTimeout: const Duration(milliseconds: 300),
      delay: (_) async {},
    );

    final result = await service.findLyrics(_lookup());

    expect(result?.providerId, '42');
    expect(transport.requests.map((request) => request.uri.path), [
      '/api/get',
      '/api/search',
    ]);
    expect(transport.requests.last.uri.queryParameters, {'q': 'Artist Song'});
  });

  test('a foreground deadline prevents a slow fallback cascade', () async {
    final pendingExact = Completer<LrclibResponse>();
    final pendingBroad = Completer<LrclibResponse>();
    transport
      ..enqueueFuture(pendingExact.future)
      ..enqueueFuture(pendingBroad.future);
    final service = createService(
      requestTimeout: const Duration(milliseconds: 100),
      exactRequestTimeout: const Duration(milliseconds: 20),
      lookupTimeout: const Duration(milliseconds: 60),
      delay: (_) async {},
    );
    final watch = Stopwatch()..start();

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(
        isA<LyricsConnectionException>().having(
          (error) => error.cause,
          'cause',
          isA<TimeoutException>(),
        ),
      ),
    );
    watch.stop();

    expect(transport.requests, hasLength(1));
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test('treats search 404 responses as lyrics not found', () async {
    transport.responder = (_) =>
        _jsonResponse(HttpStatus.notFound, {'message': 'missing'});
    final service = createService(delay: (_) async {});

    final result = await service.findLyrics(
      const LyricsLookup(title: 'Song', artist: 'Artist'),
    );

    expect(result, isNull);
    expect(transport.requests, hasLength(2));
    expect(
      transport.requests.every((request) => request.uri.path == '/api/search'),
      isTrue,
    );
  });

  test('deduplicates in-flight requests and caches their result', () async {
    final response = Completer<LrclibResponse>();
    transport.enqueueFuture(response.future);
    final service = createService();
    const firstLookup = LyricsLookup(
      title: 'Canción',
      artist: 'Ártist',
      duration: Duration(seconds: 180),
    );
    const equivalentLookup = LyricsLookup(
      title: 'cancion',
      artist: 'artist',
      duration: Duration(seconds: 180),
    );

    final first = service.findLyrics(firstLookup);
    final second = service.findLyrics(equivalentLookup);
    expect(transport.requests, hasLength(1));

    response.complete(
      _jsonResponse(
        HttpStatus.ok,
        _record(
          id: 50,
          trackName: 'Canción',
          artistName: 'Ártist',
          duration: 180,
          syncedLyrics: '[00:01.00]Line',
        ),
      ),
    );
    final firstResult = await first;
    final secondResult = await second;
    final cachedResult = await service.findLyrics(firstLookup);

    expect(identical(firstResult, secondResult), isTrue);
    expect(identical(firstResult, cachedResult), isTrue);
    expect(transport.requests, hasLength(1));
  });

  test(
    'zero cache TTL deduplicates in-flight requests but not completed ones',
    () async {
      final pendingResponse = Completer<LrclibResponse>();
      transport.enqueueFuture(pendingResponse.future);
      final service = createService(cacheTtl: Duration.zero);

      final first = service.findLyrics(_lookup());
      final simultaneous = service.findLyrics(_lookup());
      expect(transport.requests, hasLength(1));

      pendingResponse.complete(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: 80,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            plainLyrics: 'First response',
          ),
        ),
      );
      final firstResult = await first;
      final simultaneousResult = await simultaneous;
      expect(identical(firstResult, simultaneousResult), isTrue);

      transport.enqueue(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: 81,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            plainLyrics: 'Fresh response',
          ),
        ),
      );
      final refreshed = await service.findLyrics(_lookup());

      expect(firstResult?.providerId, '80');
      expect(refreshed?.providerId, '81');
      expect(transport.requests, hasLength(2));
    },
  );

  test('refreshes an expired memory cache entry', () async {
    var now = DateTime.utc(2026, 8, 3);
    transport
      ..enqueue(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: 60,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            plainLyrics: 'First',
          ),
        ),
      )
      ..enqueue(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: 61,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            plainLyrics: 'Updated',
          ),
        ),
      );
    final service = createService(
      clock: () => now,
      cacheTtl: const Duration(minutes: 5),
    );

    final first = await service.findLyrics(_lookup());
    now = now.add(const Duration(minutes: 6));
    final refreshed = await service.findLyrics(_lookup());

    expect(first?.providerId, '60');
    expect(refreshed?.providerId, '61');
    expect(transport.requests, hasLength(2));
  });

  test('does not cache HTTP failures', () async {
    transport
      ..enqueue(_jsonResponse(HttpStatus.internalServerError, {'error': true}))
      ..enqueue(
        _jsonResponse(
          HttpStatus.ok,
          _record(
            id: 70,
            trackName: 'Song',
            artistName: 'Artist',
            duration: 180,
            plainLyrics: 'Recovered',
          ),
        ),
      );
    final service = createService();

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(isA<LrclibHttpException>()),
    );
    final recovered = await service.findLyrics(_lookup());

    expect(recovered?.providerId, '70');
    expect(transport.requests, hasLength(2));
  });

  test('reports malformed JSON as a format error', () async {
    transport.enqueue(
      LrclibResponse(statusCode: HttpStatus.ok, body: '{broken'),
    );
    final service = createService();

    await expectLater(
      service.findLyrics(_lookup()),
      throwsA(isA<LrclibFormatException>()),
    );
  });

  test('dispose closes transport and prevents more requests', () async {
    final service = createService();
    service.dispose();

    expect(transport.closed, isTrue);
    expect(() => service.findLyrics(_lookup()), throwsStateError);
  });
}

LyricsLookup _lookup() {
  return const LyricsLookup(
    title: 'Song',
    artist: 'Artist',
    duration: Duration(seconds: 180),
  );
}

Map<String, Object?> _record({
  required Object id,
  required String trackName,
  required String artistName,
  String? albumName,
  num? duration,
  bool instrumental = false,
  String? plainLyrics,
  String? syncedLyrics,
}) {
  return {
    'id': id,
    'trackName': trackName,
    'artistName': artistName,
    'albumName': albumName,
    'duration': duration,
    'instrumental': instrumental,
    'plainLyrics': plainLyrics,
    'syncedLyrics': syncedLyrics,
  };
}

LrclibResponse _jsonResponse(
  int statusCode,
  Object? body, {
  Map<String, String> headers = const {},
}) {
  return LrclibResponse(
    statusCode: statusCode,
    body: jsonEncode(body),
    headers: headers,
  );
}

class _FakeTransport implements LrclibTransport {
  final List<Future<LrclibResponse>> _responses = [];
  final List<_RecordedRequest> requests = [];
  LrclibResponse Function(Uri uri)? responder;
  bool closed = false;

  void enqueue(LrclibResponse response) {
    enqueueFuture(Future.value(response));
  }

  void enqueueFuture(Future<LrclibResponse> response) {
    _responses.add(response);
  }

  @override
  Future<LrclibResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) {
    if (closed) {
      throw StateError('Transport closed.');
    }
    requests.add(
      _RecordedRequest(uri: uri, headers: Map.unmodifiable(headers)),
    );
    final dynamicResponse = responder;
    if (dynamicResponse != null) {
      return Future.value(dynamicResponse(uri));
    }
    if (_responses.isEmpty) {
      throw StateError('No fake LRCLIB response was queued for $uri.');
    }
    return _responses.removeAt(0);
  }

  @override
  void close() {
    closed = true;
  }
}

class _DefaultManualSearchService extends LyricsService {
  final List<LyricsLookup> lookups = [];
  final List<int> limits = [];

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) async => null;

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async {
    lookups.add(lookup);
    limits.add(limit);
    return const [];
  }

  @override
  void dispose() {}
}

class _RecordedRequest {
  const _RecordedRequest({required this.uri, required this.headers});

  final Uri uri;
  final Map<String, String> headers;
}
