import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _immediateRetryDelay(Duration _) async {}

DateTime _fixedRetryClock() => DateTime.utc(2026, 8, 22, 12);

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(Duration.zero);
  }
  throw StateError('Condition was not reached.');
}

void main() {
  group('InnerTubeSearchService', () {
    late _FakeInnerTubeTransport transport;

    setUp(() {
      transport = _FakeInnerTubeTransport();
    });

    InnerTubeSearchService createService({
      Duration requestTimeout = const Duration(seconds: 2),
      InnerTubeRetryDelay retryDelay = _immediateRetryDelay,
      InnerTubeRetryClock retryClock = _fixedRetryClock,
    }) {
      final service = InnerTubeSearchService(
        transport: transport,
        endpoint: Uri.parse('https://example.test/search'),
        browseEndpoint: Uri.parse('https://example.test/browse'),
        playerEndpoint: Uri.parse('https://example.test/player'),
        bootstrapUri: Uri.parse('https://example.test/bootstrap'),
        language: 'es',
        region: 'ni',
        userAgent: 'BStreamMusic/InnerTubeTest',
        requestTimeout: requestTimeout,
        retryDelay: retryDelay,
        retryClock: retryClock,
      );
      addTearDown(service.dispose);
      return service;
    }

    test('retries transient catalog failures and preserves request', () async {
      transport.responses.addAll([
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.internalServerError,
          body: 'temporary one',
        ),
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.tooManyRequests,
          body: 'temporary two',
          headers: {'retry-after': '3'},
        ),
        InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(_searchPayload(const [])),
        ),
      ]);
      final delays = <Duration>[];
      final service = createService(
        retryDelay: (delay) async {
          delays.add(delay);
        },
      );

      expect(await service.searchSongs('retry me'), isEmpty);

      expect(transport.requests, hasLength(3));
      expect(
        transport.requests.map((request) => request.body['query']),
        everyElement('retry me'),
      );
      expect(delays, const [Duration(milliseconds: 350), Duration(seconds: 3)]);
    });

    test(
      'bounds transport retries and keeps the typed terminal error',
      () async {
        transport.error = const SocketException('offline');
        final delays = <Duration>[];
        final service = createService(
          retryDelay: (delay) async {
            delays.add(delay);
          },
        );

        await expectLater(
          service.searchSongs('offline'),
          throwsA(isA<InnerTubeTransportException>()),
        );

        expect(transport.requests, hasLength(3));
        expect(delays, const [
          Duration(milliseconds: 350),
          Duration(seconds: 1),
        ]);
      },
    );

    test('sends a WEB_REMIX search restricted to songs', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode(
          _searchPayload([
            _songRenderer(
              videoId: 'hello-video',
              title: 'Hello',
              artists: const ['Adele'],
              album: '25',
              duration: '4:56',
              thumbnails: const [
                ('https://img.test/60.jpg', 60),
                ('https://img.test/120.jpg', 120),
              ],
            ),
          ]),
        ),
      );
      final service = createService();

      final results = await service.searchSongs('  Adele Hello  ');

      expect(results, hasLength(1));
      expect(results.single.videoId, 'hello-video');
      expect(results.single.title, 'Hello');
      expect(results.single.artists, const ['Adele']);
      expect(results.single.album, '25');
      expect(results.single.duration, const Duration(minutes: 4, seconds: 56));
      expect(results.single.thumbnailUrl, 'https://img.test/120.jpg');
      expect(
        results.single.watchUri.toString(),
        'https://www.youtube.com/watch?v=hello-video',
      );

      final request = transport.requests.single;
      expect(request.uri.queryParameters, {
        'key': 'bootstrap-key',
        'prettyPrint': 'false',
      });
      expect(request.headers['X-YouTube-Client-Name'], '99');
      expect(request.headers['X-YouTube-Client-Version'], 'bootstrap-version');
      expect(request.headers['X-Goog-Visitor-Id'], 'visitor-data');
      expect(request.headers['Origin'], 'https://music.youtube.com');
      expect(request.body['query'], 'Adele Hello');
      expect(request.body['params'], 'EgWKAQIIAWoMEA4QChADEAQQCRAF');
      expect(request.body['context'], {
        'client': {
          'clientName': 'TEST_REMIX',
          'clientVersion': 'bootstrap-version',
          'hl': 'es',
          'gl': 'NI',
          'visitorData': 'visitor-data',
        },
      });
      expect(transport.getRequests.single.uri.path, '/bootstrap');
      expect(transport.getRequests.single.uri.queryParameters, {
        'hl': 'es',
        'gl': 'NI',
      });
    });

    test('caches bootstrap configuration across searches', () async {
      final service = createService();

      await service.searchSongs('first');
      await service.searchSongs('second');

      expect(transport.getRequests, hasLength(1));
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].body['query'], 'first');
      expect(transport.requests[1].body['query'], 'second');
    });

    test(
      'searches videos, albums and artists with canonical filters and one bootstrap',
      () async {
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _searchPayload([
                _songRenderer(
                  videoId: 'video000001',
                  title: 'Wonderwall video',
                  artists: const ['Oasis'],
                  duration: '4:20',
                ),
              ]),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _searchPayload([
                _albumRenderer(
                  browseId: 'MPREb_album123',
                  title: 'Wonderwall',
                  artists: const ['Oasis'],
                  type: 'EP',
                  year: '1995',
                  playlistId: 'OLAK5uy_albumplaylist123',
                  thumbnails: const [
                    ('//img.test/120.jpg', 120),
                    ('https://img.test/480.jpg', 480),
                  ],
                ),
              ]),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _searchPayload([
                _responsiveArtistRenderer(
                  browseId: 'UCoasisArtist123',
                  name: 'Oasis',
                  thumbnails: const [
                    ('//img.test/artist-60.jpg', 60),
                    ('https://img.test/artist-240.jpg', 240),
                  ],
                ),
              ]),
            ),
          ),
        ]);
        final service = createService();

        final videos = await service.searchVideos('  Oasis Wonderwall  ');
        final albums = await service.searchAlbums('Oasis Wonderwall');
        final artists = await service.searchArtists('  Oasis  ');

        expect(videos.single.videoId, 'video000001');
        expect(videos.single.title, 'Wonderwall video');
        expect(videos.single.artists, const ['Oasis']);
        expect(videos.single.duration, const Duration(minutes: 4, seconds: 20));

        expect(albums, hasLength(1));
        expect(albums.single.browseId, 'MPREb_album123');
        expect(albums.single.title, 'Wonderwall');
        expect(albums.single.artists, const ['Oasis']);
        expect(albums.single.artist, 'Oasis');
        expect(albums.single.type, 'EP');
        expect(albums.single.year, '1995');
        expect(albums.single.playlistId, 'OLAK5uy_albumplaylist123');
        expect(albums.single.thumbnailUrl, 'https://img.test/480.jpg');

        expect(artists, hasLength(1));
        expect(artists.single.browseId, 'UCoasisArtist123');
        expect(artists.single.name, 'Oasis');
        expect(artists.single.thumbnailUrl, 'https://img.test/artist-240.jpg');

        expect(transport.getRequests, hasLength(1));
        expect(transport.requests, hasLength(3));
        expect(transport.requests[0].body['query'], 'Oasis Wonderwall');
        expect(
          transport.requests[0].body['params'],
          'EgWKAQIQAWoMEA4QChADEAQQCRAF',
        );
        expect(transport.requests[1].body['query'], 'Oasis Wonderwall');
        expect(
          transport.requests[1].body['params'],
          'EgWKAQIYAWoMEA4QChADEAQQCRAF',
        );
        expect(transport.requests[2].body['query'], 'Oasis');
        expect(
          transport.requests[2].body['params'],
          'EgWKAQIgAWoMEA4QChADEAQQCRAF',
        );
      },
    );

    test('refreshes bootstrap once for catalog search', () async {
      transport.responses.addAll([
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.forbidden,
          body: '{"error":"stale catalog client"}',
        ),
        InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(_searchPayload(const [])),
        ),
      ]);
      final service = createService();

      expect(await service.searchVideos('hello'), isEmpty);

      expect(transport.getRequests, hasLength(2));
      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.every(
          (request) =>
              request.body['params'] == InnerTubeSearchService.videosFilter,
        ),
        isTrue,
      );
    });

    test(
      'coalesces a fresh bootstrap across concurrent rejected calls',
      () async {
        transport.responses.addAll([
          const InnerTubeHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: '{"error":"stale one"}',
          ),
          const InnerTubeHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: '{"error":"stale two"}',
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(_searchPayload(const [])),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(_searchPayload(const [])),
          ),
        ]);
        final freshGate = Completer<void>();
        transport.freshBootstrapGate = freshGate;
        final service = createService();

        final first = service.searchSongs('one');
        final second = service.searchSongs('two');
        await _waitUntil(() => transport.getRequests.length == 2);
        expect(transport.requests, hasLength(2));

        freshGate.complete();
        await Future.wait([first, second]);

        expect(transport.getRequests, hasLength(2));
        expect(transport.requests, hasLength(4));
      },
    );

    test(
      'refreshes bootstrap once when the client config is rejected',
      () async {
        transport.responses.addAll([
          const InnerTubeHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: '{"error":"stale client"}',
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(_searchPayload(const [])),
          ),
        ]);
        final service = createService();

        expect(await service.searchSongs('hello'), isEmpty);

        expect(transport.getRequests, hasLength(2));
        expect(transport.requests, hasLength(2));
      },
    );

    test('reports incomplete bootstrap data as a format error', () async {
      transport.bootstrapResponse = const InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: '<html><script>{"INNERTUBE_API_KEY":"only-key"}</script></html>',
      );
      final service = createService();

      await expectLater(
        service.searchSongs('hello'),
        throwsA(isA<InnerTubeFormatException>()),
      );
      expect(transport.requests, isEmpty);
    });

    test('does not make a request for an empty query', () async {
      final service = createService();

      expect(await service.searchSongs('   '), isEmpty);
      expect(transport.requests, isEmpty);
    });

    test('catalog search validates empty queries and limits locally', () async {
      final service = createService();

      expect(await service.searchVideos('   '), isEmpty);
      expect(await service.searchAlbums('\t'), isEmpty);
      expect(await service.searchArtists('\n'), isEmpty);
      await expectLater(
        service.searchVideos('hello', limit: 0),
        throwsRangeError,
      );
      await expectLater(
        service.searchAlbums('hello', limit: 21),
        throwsRangeError,
      );
      await expectLater(
        service.searchArtists('hello', limit: 0),
        throwsRangeError,
      );

      expect(transport.getRequests, isEmpty);
      expect(transport.requests, isEmpty);
    });

    test('rejects limits outside the supported 1 to 20 range', () async {
      final service = createService();

      await expectLater(
        service.searchSongs('hello', limit: 0),
        throwsRangeError,
      );
      await expectLater(
        service.searchSongs('hello', limit: 21),
        throwsRangeError,
      );
      expect(transport.requests, isEmpty);
    });

    test('turns non-success status codes into a typed HTTP error', () async {
      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.tooManyRequests,
        body: '{"error":"slow down"}',
      );
      final service = createService();

      await expectLater(
        service.searchSongs('hello'),
        throwsA(
          isA<InnerTubeHttpException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having((error) => error.body, 'body', contains('slow down')),
        ),
      );
    });

    test('turns request timeouts into a typed timeout error', () async {
      transport.error = TimeoutException('fixture timeout');
      final service = createService();

      await expectLater(
        service.searchSongs('hello'),
        throwsA(isA<InnerTubeTimeoutException>()),
      );
    });

    test('reports invalid JSON without leaking a FormatException', () async {
      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: '{not-json',
      );
      final service = createService();

      await expectLater(
        service.searchSongs('hello'),
        throwsA(isA<InnerTubeFormatException>()),
      );
    });

    test(
      'catalog searches preserve typed transport and format errors',
      () async {
        transport.error = TimeoutException('catalog timeout');
        final timeoutService = createService();

        await expectLater(
          timeoutService.searchVideos('hello'),
          throwsA(isA<InnerTubeTimeoutException>()),
        );

        transport.error = null;
        transport.response = const InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: '{not-json',
        );
        final formatService = createService();
        await expectLater(
          formatService.searchAlbums('hello'),
          throwsA(isA<InnerTubeFormatException>()),
        );
      },
    );

    test('reports a structurally invalid JSON root', () async {
      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: '[]',
      );
      final service = createService();

      await expectLater(
        service.searchSongs('hello'),
        throwsA(isA<InnerTubeFormatException>()),
      );
    });

    test('closes the injected transport when disposed', () async {
      final service = createService();

      service.dispose();
      service.dispose();

      expect(transport.closeCount, 1);
      await expectLater(
        service.searchSongs('hello'),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'looks up player metadata by case-sensitive ID without searching',
      () async {
        const videoId = 'AbCdEfGhI_1';
        transport.response = InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(
            _playerPayload(
              videoId: videoId,
              title: 'Direct song',
              author: 'Direct artist',
              lengthSeconds: '245',
              thumbnails: const [
                ('https://img.test/120.jpg', 120),
                ('//img.test/720.jpg', 720),
              ],
            ),
          ),
        );
        final service = createService();

        final song = await service.getSong(videoId);

        expect(song, isNotNull);
        expect(song!.videoId, videoId);
        expect(song.title, 'Direct song');
        expect(song.artists, const ['Direct artist']);
        expect(song.album, isNull);
        expect(song.duration, const Duration(minutes: 4, seconds: 5));
        expect(song.thumbnailUrl, 'https://img.test/720.jpg');

        final request = transport.requests.single;
        expect(request.uri.path, '/player');
        expect(request.uri.queryParameters, {
          'key': 'bootstrap-key',
          'prettyPrint': 'false',
        });
        expect(request.body['videoId'], videoId);
        expect(request.body, isNot(contains('query')));
        expect(request.body, isNot(contains('params')));
        expect(request.body['context'], {
          'client': {
            'clientName': 'TEST_REMIX',
            'clientVersion': 'bootstrap-version',
            'hl': 'es',
            'gl': 'NI',
            'visitorData': 'visitor-data',
          },
        });
      },
    );

    test('returns null when the player reports an unavailable video', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode({
          'playabilityStatus': {
            'status': 'UNPLAYABLE',
            'reason': 'Video unavailable',
          },
        }),
      );
      final service = createService();

      expect(await service.getSong('Unavailable'), isNull);
      expect(transport.requests.single.uri.path, '/player');
    });

    test(
      'rejects malformed video IDs before bootstrap or player calls',
      () async {
        final service = createService();

        await expectLater(
          service.getSong('not a video id'),
          throwsA(isA<ArgumentError>()),
        );

        expect(transport.getRequests, isEmpty);
        expect(transport.requests, isEmpty);
      },
    );

    test('treats a differently-cased returned video ID as malformed', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode(
          _playerPayload(
            videoId: 'abcdefghij1',
            title: 'Wrong identity',
            author: 'Artist',
          ),
        ),
      );
      final service = createService();

      await expectLater(
        service.getSong('AbCdEfGhIj1'),
        throwsA(isA<InnerTubeFormatException>()),
      );
    });

    test('reports malformed playable player responses', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode({
          'playabilityStatus': {'status': 'OK'},
          'videoDetails': {
            'videoId': 'AbCdEfGhIj1',
            'musicVideoType': 'MUSIC_VIDEO_TYPE_ATV',
          },
        }),
      );
      final service = createService();

      await expectLater(
        service.getSong('AbCdEfGhIj1'),
        throwsA(isA<InnerTubeFormatException>()),
      );
    });

    test('rejects a playable regular video without a music signal', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode(
          _playerPayload(
            videoId: 'AbCdEfGhIj1',
            title: 'Regular video',
            author: 'Video creator',
            musicVideoType: null,
            category: 'Entertainment',
          ),
        ),
      );
      final service = createService();

      expect(await service.getSong('AbCdEfGhIj1'), isNull);
    });

    test('accepts UGC when the player categorizes it as Music', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode(
          _playerPayload(
            videoId: 'AbCdEfGhIj1',
            title: 'User uploaded song',
            author: 'Independent artist',
            musicVideoType: null,
            category: 'Music',
          ),
        ),
      );
      final service = createService();

      final song = await service.getSong('AbCdEfGhIj1');

      expect(song, isNotNull);
      expect(song!.title, 'User uploaded song');
    });

    test('rejects UGC without a Music category', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode(
          _playerPayload(
            videoId: 'AbCdEfGhIj1',
            title: 'User uploaded video',
            author: 'Video creator',
            musicVideoType: 'MUSIC_VIDEO_TYPE_UGC',
            category: 'Entertainment',
          ),
        ),
      );
      final service = createService();

      expect(await service.getSong('AbCdEfGhIj1'), isNull);
    });

    test('turns player HTTP failures into typed errors', () async {
      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.tooManyRequests,
        body: '{"error":"slow down"}',
      );
      final service = createService();

      await expectLater(
        service.getSong('AbCdEfGhIj1'),
        throwsA(
          isA<InnerTubeHttpException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having((error) => error.body, 'body', contains('slow down')),
        ),
      );
    });

    test(
      'refreshes bootstrap once when the player config is rejected',
      () async {
        transport.responses.addAll([
          const InnerTubeHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: '{"error":"stale client"}',
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _playerPayload(
                videoId: 'AbCdEfGhIj1',
                title: 'Fresh metadata',
                author: 'Artist',
              ),
            ),
          ),
        ]);
        final service = createService();

        expect(await service.getSong('AbCdEfGhIj1'), isNotNull);
        expect(transport.getRequests, hasLength(2));
        expect(transport.requests, hasLength(2));
        expect(
          transport.requests.every((request) => request.uri.path == '/player'),
          isTrue,
        );
      },
    );

    test('turns player timeouts into a typed timeout error', () async {
      transport.error = TimeoutException('fixture timeout');
      final service = createService();

      await expectLater(
        service.getSong('AbCdEfGhIj1'),
        throwsA(isA<InnerTubeTimeoutException>()),
      );
    });

    test(
      'requests the anonymous WEB_REMIX home feed and reuses bootstrap',
      () async {
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homePayload([
                _homeCarousel(
                  title: 'Seleccion rapida',
                  items: [
                    _songRenderer(
                      videoId: 'home-video',
                      title: 'Home song',
                      artists: const ['Home artist'],
                    ),
                  ],
                ),
              ]),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(_searchPayload(const [])),
          ),
        ]);
        final service = createService();

        final sections = await service.getHome(
          maxSections: 1,
          maxItemsPerSection: 3,
        );
        await service.searchSongs('after home');

        expect(sections, hasLength(1));
        expect(sections.single.title, 'Seleccion rapida');
        expect(sections.single.songs.single.videoId, 'home-video');
        expect(transport.getRequests, hasLength(1));
        expect(transport.requests, hasLength(2));

        final request = transport.requests.first;
        expect(
          request.uri,
          Uri.parse(
            'https://example.test/browse?key=bootstrap-key&prettyPrint=false',
          ),
        );
        expect(request.headers[HttpHeaders.acceptHeader], 'application/json');
        expect(
          request.headers[HttpHeaders.contentTypeHeader],
          'application/json; charset=UTF-8',
        );
        expect(request.headers['Origin'], 'https://music.youtube.com');
        expect(
          request.headers[HttpHeaders.refererHeader],
          'https://music.youtube.com/',
        );
        expect(
          request.headers[HttpHeaders.userAgentHeader],
          'BStreamMusic/InnerTubeTest',
        );
        expect(request.headers['X-YouTube-Client-Name'], '99');
        expect(
          request.headers['X-YouTube-Client-Version'],
          'bootstrap-version',
        );
        expect(request.headers['X-Goog-Visitor-Id'], 'visitor-data');
        expect(request.timeout, const Duration(seconds: 2));
        expect(request.body['browseId'], 'FEmusic_home');
        expect(request.body, isNot(contains('query')));
        expect(request.body, isNot(contains('params')));
        expect(request.body['context'], {
          'client': {
            'clientName': 'TEST_REMIX',
            'clientVersion': 'bootstrap-version',
            'hl': 'es',
            'gl': 'NI',
            'visitorData': 'visitor-data',
          },
        });
        expect(transport.requests.last.uri.path, '/search');
      },
    );

    test(
      'follows one home continuation and merges sections with global dedupe',
      () async {
        final duplicateSong = _songRenderer(
          videoId: 'shared-home-video',
          title: 'Shared song',
          artists: const ['Shared artist'],
        );
        final duplicateCollection = _collectionRenderer(
          title: 'Shared collection',
          browseId: 'VLPLsharedhomecollection',
          playlistId: 'PLsharedhomecollection',
        );
        final duplicateArtist = _artistRenderer(
          browseId: 'UCsharedhomeartist',
          name: 'Shared Home artist',
        );
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homePayload([
                _homeCarousel(
                  title: 'Initial one',
                  items: [duplicateSong, duplicateCollection],
                ),
                _homeCarousel(
                  title: 'Initial two',
                  items: [
                    _songRenderer(
                      videoId: 'initial-only',
                      title: 'Initial only',
                      artists: const ['Initial artist'],
                    ),
                    duplicateArtist,
                  ],
                ),
              ], continuation: 'home-continuation-1'),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homeContinuationPayload([
                _homeCarousel(
                  title: 'Continued one',
                  items: [
                    duplicateSong,
                    duplicateArtist,
                    _songRenderer(
                      videoId: 'continued-only',
                      title: 'Continued only',
                      artists: const ['Continued artist'],
                    ),
                  ],
                ),
                _homeCarousel(
                  title: 'Continued two',
                  items: [
                    duplicateCollection,
                    _collectionRenderer(
                      title: 'Continued collection',
                      browseId: 'VLPLcontinuedcollection',
                      playlistId: 'PLcontinuedcollection',
                    ),
                  ],
                ),
                _homeCarousel(
                  title: 'Over section limit',
                  items: [
                    _songRenderer(
                      videoId: 'over-section-limit',
                      title: 'Over section limit',
                      artists: const ['Later artist'],
                    ),
                  ],
                ),
              ], continuation: 'home-continuation-2'),
            ),
          ),
        ]);
        final service = createService();

        final sections = await service.getHome(
          maxSections: 4,
          maxItemsPerSection: 2,
        );

        expect(sections.map((section) => section.title), [
          'Initial one',
          'Initial two',
          'Continued one',
          'Continued two',
        ]);
        expect(sections[2].songs.single.videoId, 'continued-only');
        expect(
          sections[3].collections.single.browseId,
          'VLPLcontinuedcollection',
        );
        expect(
          sections
              .expand((section) => section.songs)
              .where((song) => song.videoId == 'shared-home-video'),
          hasLength(1),
        );
        expect(
          sections
              .expand((section) => section.collections)
              .where(
                (collection) =>
                    collection.browseId == 'VLPLsharedhomecollection',
              ),
          hasLength(1),
        );
        expect(
          sections
              .expand((section) => section.artists)
              .where((artist) => artist.browseId == 'UCsharedhomeartist'),
          hasLength(1),
        );
        expect(transport.requests, hasLength(2));
        final continuationRequest = transport.requests.last;
        expect(
          continuationRequest.uri,
          Uri.parse(
            'https://example.test/browse?key=bootstrap-key&prettyPrint=false',
          ),
        );
        expect(continuationRequest.body['continuation'], 'home-continuation-1');
        expect(continuationRequest.body, isNot(contains('browseId')));
        expect(continuationRequest.body, isNot(contains('query')));
        expect(continuationRequest.body, isNot(contains('params')));
        expect(continuationRequest.body['context'], {
          'client': {
            'clientName': 'TEST_REMIX',
            'clientVersion': 'bootstrap-version',
            'hl': 'es',
            'gl': 'NI',
            'visitorData': 'visitor-data',
          },
        });
      },
    );

    test('does not request a continuation when the token is absent', () async {
      transport.response = InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: jsonEncode(
          _homePayload([
            _homeCarousel(
              title: 'Only initial shelf',
              items: [
                _songRenderer(
                  videoId: 'only-initial',
                  title: 'Only initial',
                  artists: const ['Artist'],
                ),
              ],
            ),
          ]),
        ),
      );
      final service = createService();

      final sections = await service.getHome(maxSections: 6);

      expect(sections.single.title, 'Only initial shelf');
      expect(transport.requests, hasLength(1));
    });

    test(
      'stops after one continuation when the next token forms a cycle',
      () async {
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homePayload([
                _homeCarousel(
                  title: 'Initial shelf',
                  items: [
                    _songRenderer(
                      videoId: 'cycle-initial',
                      title: 'Cycle initial',
                      artists: const ['Artist'],
                    ),
                  ],
                ),
              ], continuation: 'cycle-token'),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homeContinuationPayload(
                [
                  _homeCarousel(
                    title: 'Continued shelf',
                    items: [
                      _songRenderer(
                        videoId: 'cycle-continued',
                        title: 'Cycle continued',
                        artists: const ['Artist'],
                      ),
                    ],
                  ),
                ],
                continuation: 'cycle-token',
                useContinuationCommand: true,
              ),
            ),
          ),
        ]);
        final service = createService();

        final sections = await service.getHome(maxSections: 6);

        expect(sections.map((section) => section.title), [
          'Initial shelf',
          'Continued shelf',
        ]);
        expect(transport.requests, hasLength(2));
      },
    );

    test(
      'refreshes bootstrap once when a home continuation is rejected',
      () async {
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homePayload(const [], continuation: 'refresh-continuation'),
            ),
          ),
          const InnerTubeHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: '{"error":"stale continuation client"}',
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homeContinuationPayload([
                _homeCarousel(
                  title: 'Fresh continuation',
                  items: [
                    _songRenderer(
                      videoId: 'fresh-continuation',
                      title: 'Fresh continuation',
                      artists: const ['Artist'],
                    ),
                  ],
                ),
              ]),
            ),
          ),
        ]);
        final service = createService();

        final sections = await service.getHome(maxSections: 2);

        expect(sections.single.title, 'Fresh continuation');
        expect(transport.getRequests, hasLength(2));
        expect(transport.requests, hasLength(3));
        expect(
          transport.requests
              .skip(1)
              .map((request) => request.body['continuation']),
          everyElement('refresh-continuation'),
        );
      },
    );

    test('surfaces HTTP failures from a home continuation', () async {
      transport.responses.addAll([
        InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(
            _homePayload(const [], continuation: 'failing-continuation'),
          ),
        ),
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.tooManyRequests,
          body: '{"error":"slow down continuation"}',
        ),
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.tooManyRequests,
          body: '{"error":"slow down continuation"}',
        ),
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.tooManyRequests,
          body: '{"error":"slow down continuation"}',
        ),
      ]);
      final service = createService();

      await expectLater(
        service.getHome(maxSections: 2),
        throwsA(
          isA<InnerTubeHttpException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having(
                (error) => error.body,
                'body',
                contains('slow down continuation'),
              ),
        ),
      );
      expect(transport.requests, hasLength(4));
    });

    for (final scenario in <(String, Object)>[
      (
        'HTTP',
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.tooManyRequests,
          body: '{"error":"optional page failed"}',
        ),
      ),
      (
        'invalid JSON',
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: '{not-json',
        ),
      ),
      ('timeout', TimeoutException('optional continuation timeout')),
    ]) {
      test(
        'keeps initial home sections after ${scenario.$1} failure',
        () async {
          final continuationOutcomes = scenario.$1 == 'invalid JSON'
              ? <Object>[scenario.$2]
              : <Object>[scenario.$2, scenario.$2, scenario.$2];
          transport.responses.addAll([
            InnerTubeHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(
                _homePayload([
                  _homeCarousel(
                    title: 'Initial fallback',
                    items: [
                      _songRenderer(
                        videoId: 'initial-fallback',
                        title: 'Initial fallback',
                        artists: const ['Artist'],
                      ),
                    ],
                  ),
                ], continuation: 'optional-continuation'),
              ),
            ),
            ...continuationOutcomes,
          ]);
          final service = createService();

          final sections = await service.getHome(maxSections: 4);

          expect(sections.single.title, 'Initial fallback');
          expect(sections.single.songs.single.videoId, 'initial-fallback');
          expect(
            transport.requests,
            hasLength(1 + continuationOutcomes.length),
          );
        },
      );
    }

    test('turns home continuation timeouts into typed errors', () async {
      transport.responses.addAll([
        InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(
            _homePayload(const [], continuation: 'timeout-continuation'),
          ),
        ),
        TimeoutException('fixture continuation timeout'),
        TimeoutException('fixture continuation timeout'),
        TimeoutException('fixture continuation timeout'),
      ]);
      final service = createService();

      await expectLater(
        service.getHome(maxSections: 2),
        throwsA(isA<InnerTubeTimeoutException>()),
      );
      expect(transport.requests, hasLength(4));
    });

    test(
      'loads collection songs on demand while reusing bootstrap configuration',
      () async {
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _homePayload([
                _homeCarousel(
                  title: 'Mixes',
                  items: [
                    _collectionRenderer(
                      title: 'Baladas tranquilas',
                      subtitle: 'Artista uno, Artista dos',
                      browseId: 'VLPLcollection123',
                      playlistId: 'PLcollection123',
                    ),
                  ],
                ),
              ]),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _collectionDetailPayload([
                _songRenderer(
                  videoId: 'collect00001',
                  title: 'Collection one',
                  artists: const ['First artist'],
                ),
                _songRenderer(
                  videoId: 'collect00002',
                  title: 'Collection two',
                  artists: const ['Second artist'],
                ),
                _songRenderer(
                  videoId: 'collect00003',
                  title: 'Over limit',
                  artists: const ['Third artist'],
                ),
              ]),
            ),
          ),
        ]);
        final service = createService();

        final home = await service.getHome(maxSections: 1);
        final collection = home.single.collections.single;
        final songs = await service.getCollectionSongs(
          ' ${collection.browseId} ',
          limit: 2,
        );

        expect(songs.map((song) => song.videoId), [
          'collect00001',
          'collect00002',
        ]);
        expect(transport.getRequests, hasLength(1));
        expect(transport.requests, hasLength(2));
        expect(transport.requests.first.body['browseId'], 'FEmusic_home');
        expect(transport.requests.last.body['browseId'], 'VLPLcollection123');
        expect(transport.requests.last.body, isNot(contains('query')));
        expect(transport.requests.last.body, isNot(contains('params')));
        expect(transport.requests.last.uri.path, '/browse');
      },
    );

    test(
      'loads public playlist metadata and songs from one browse chain',
      () async {
        final initialPayload = _collectionDetailPayload([
          _songRenderer(
            videoId: 'public00001',
            title: 'Public song one',
            artists: const ['First artist'],
          ),
        ], continuation: 'public-playlist-page-2');
        initialPayload['header'] = _publicPlaylistHeader(
          title: 'Playlist publica real',
          owner: 'BStream Listener',
          thumbnails: const [
            ('https://img.test/playlist-160.jpg', 160),
            ('//img.test/playlist-1280.jpg', 1280),
            ('https://img.test/playlist-640.jpg', 640),
          ],
        );
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(initialPayload),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _detailContinuationPayload([
                _songRenderer(
                  videoId: 'public00002',
                  title: 'Public song two',
                  artists: const ['Second artist'],
                ),
              ]),
            ),
          ),
        ]);
        final service = createService();

        final detail = await service.getCollectionDetail(
          ' VLPLpublic123 ',
          limit: 2,
        );

        expect(detail.browseId, 'VLPLpublic123');
        expect(detail.title, 'Playlist publica real');
        expect(detail.subtitle, 'BStream Listener');
        expect(detail.thumbnailUrl, 'https://img.test/playlist-1280.jpg');
        expect(detail.songs.map((song) => song.videoId), [
          'public00001',
          'public00002',
        ]);
        expect(transport.getRequests, hasLength(1));
        expect(transport.requests, hasLength(2));
        expect(transport.requests.first.body['browseId'], 'VLPLpublic123');
        expect(transport.requests.first.body, isNot(contains('continuation')));
        expect(
          transport.requests.last.body['continuation'],
          'public-playlist-page-2',
        );
        expect(transport.requests.last.body, isNot(contains('browseId')));
      },
    );

    test(
      'detail lookups parse more than the 20 search results in one payload',
      () async {
        final collectionTracks = List.generate(
          35,
          (index) => _songRenderer(
            videoId: 'collection-$index',
            title: 'Collection song $index',
            artists: const ['Collection artist'],
          ),
        );
        final albumTracks = List.generate(
          32,
          (index) => _songRenderer(
            videoId: 'album-$index',
            title: 'Album song $index',
            artists: const ['Album artist'],
          ),
        );
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(_collectionDetailPayload(collectionTracks)),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _albumDetailPayload(
                title: 'Large album',
                artists: const ['Album artist'],
                tracks: albumTracks,
              ),
            ),
          ),
        ]);
        final service = createService();

        final collection = await service.getCollectionSongs(
          'VLPLcollection123',
        );
        final album = await service.getAlbumSongs('MPREb_album123');

        expect(collection, hasLength(35));
        expect(collection.last.videoId, 'collection-34');
        expect(album, hasLength(32));
        expect(album.last.videoId, 'album-31');
        expect(transport.requests, hasLength(2));
      },
    );

    test(
      'collection continuations preserve order, globally dedupe IDs, and stop at the requested limit',
      () async {
        final initialTracks = List.generate(
          20,
          (index) => _songRenderer(
            videoId: 'continued-$index',
            title: 'Continued song $index',
            artists: const ['Artist'],
          ),
        );
        final continuedTracks = [
          initialTracks.last,
          ...List.generate(
            20,
            (index) => _songRenderer(
              videoId: 'continued-${index + 20}',
              title: 'Continued song ${index + 20}',
              artists: const ['Artist'],
            ),
          ),
        ];
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _collectionDetailPayload(
                initialTracks,
                continuation: 'collection-page-2',
              ),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _detailContinuationPayload(
                continuedTracks,
                continuation: 'collection-page-3-not-needed',
              ),
            ),
          ),
        ]);
        final service = createService();

        final songs = await service.getCollectionSongs(
          'VLPLcollection123',
          limit: 35,
        );

        expect(songs, hasLength(35));
        expect(
          songs.map((song) => song.videoId),
          List.generate(35, (index) => 'continued-$index'),
        );
        expect(transport.requests, hasLength(2));
        expect(
          transport.requests.last.body['continuation'],
          'collection-page-2',
        );
        expect(transport.requests.last.body, isNot(contains('browseId')));
      },
    );

    test(
      'album continuations inherit header metadata and stop token cycles',
      () async {
        transport.responses.addAll([
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _albumDetailPayload(
                title: 'Continued album',
                artists: const ['Header artist'],
                tracks: [
                  _songRenderer(
                    videoId: 'album-page-1',
                    title: 'First page',
                    artists: const [],
                  ),
                ],
                continuation: 'album-cycle',
              ),
            ),
          ),
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _detailContinuationPayload([
                _songRenderer(
                  videoId: 'album-page-2',
                  title: 'Second page',
                  artists: const [],
                ),
              ], continuation: 'album-cycle'),
            ),
          ),
        ]);
        final service = createService();

        final songs = await service.getAlbumSongs('MPREb_album123');

        expect(songs.map((song) => song.videoId), [
          'album-page-1',
          'album-page-2',
        ]);
        expect(
          songs.map((song) => song.album),
          everyElement('Continued album'),
        );
        expect(
          songs.map((song) => song.artists),
          everyElement(equals(const ['Header artist'])),
        );
        expect(transport.requests, hasLength(2));
      },
    );

    test(
      'detail continuation requests stop at the strict safety cap',
      () async {
        transport.responses.add(
          InnerTubeHttpResponse(
            statusCode: HttpStatus.ok,
            body: jsonEncode(
              _collectionDetailPayload([
                _songRenderer(
                  videoId: 'bounded-0',
                  title: 'Bounded song 0',
                  artists: const ['Artist'],
                ),
              ], continuation: 'bounded-page-1'),
            ),
          ),
        );
        for (
          var index = 1;
          index <= InnerTubeSearchService.maxDetailContinuationRequests;
          index++
        ) {
          transport.responses.add(
            InnerTubeHttpResponse(
              statusCode: HttpStatus.ok,
              body: jsonEncode(
                _detailContinuationPayload([
                  _songRenderer(
                    videoId: 'bounded-$index',
                    title: 'Bounded song $index',
                    artists: const ['Artist'],
                  ),
                ], continuation: 'bounded-page-${index + 1}'),
              ),
            ),
          );
        }
        final service = createService();

        final songs = await service.getCollectionSongs('VLPLcollection123');

        expect(
          songs,
          hasLength(InnerTubeSearchService.maxDetailContinuationRequests + 1),
        );
        expect(
          transport.requests,
          hasLength(InnerTubeSearchService.maxDetailContinuationRequests + 1),
        );
      },
    );

    test(
      'validates collection browse IDs and limits before requests',
      () async {
        final service = createService();

        for (final browseId in const <String>[
          '',
          'FEmusic_home',
          'VLbad id',
          'VL../unsafe',
        ]) {
          await expectLater(
            service.getCollectionSongs(browseId),
            throwsArgumentError,
          );
        }
        await expectLater(
          service.getCollectionSongs('VLPLcollection123', limit: 0),
          throwsRangeError,
        );
        await expectLater(
          service.getCollectionSongs(
            'VLPLcollection123',
            limit: InnerTubeSearchService.maxDetailResults + 1,
          ),
          throwsRangeError,
        );

        expect(transport.getRequests, isEmpty);
        expect(transport.requests, isEmpty);
      },
    );

    test('turns collection HTTP failures into typed errors', () async {
      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.tooManyRequests,
        body: '{"error":"slow down collection"}',
      );
      final service = createService();

      await expectLater(
        service.getCollectionSongs('VLPLcollection123'),
        throwsA(
          isA<InnerTubeHttpException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having(
                (error) => error.body,
                'body',
                contains('slow down collection'),
              ),
        ),
      );
      expect(transport.requests, hasLength(3));
      expect(
        transport.requests.every(
          (request) => request.body['browseId'] == 'VLPLcollection123',
        ),
        isTrue,
      );
    });

    test(
      'loads album songs and inherits missing header metadata with dedupe',
      () async {
        final inheritedTrack = _songRenderer(
          videoId: 'albumtrk001',
          title: 'Inherited metadata',
          artists: const [],
          duration: '4:19',
          durationInFixedColumn: true,
        );
        transport.response = InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(
            _albumDetailPayload(
              title: 'Morning Glory',
              artists: const ['Oasis'],
              tracks: [
                inheritedTrack,
                _songRenderer(
                  videoId: 'albumtrk002',
                  title: 'Own metadata',
                  artists: const ['Oasis', 'Guest'],
                  album: 'Special edition',
                  duration: '3:05',
                ),
                inheritedTrack,
              ],
              relatedTracks: [
                _songRenderer(
                  videoId: 'related0001',
                  title: 'Related, not an album track',
                  artists: const ['Other artist'],
                ),
              ],
            ),
          ),
        );
        final service = createService();

        final songs = await service.getAlbumSongs('  MPREb_album123  ');

        expect(songs, hasLength(2));
        expect(songs.first.videoId, 'albumtrk001');
        expect(songs.first.artists, const ['Oasis']);
        expect(songs.first.album, 'Morning Glory');
        expect(songs.first.duration, const Duration(minutes: 4, seconds: 19));
        expect(songs.last.artists, const ['Oasis', 'Guest']);
        expect(songs.last.album, 'Special edition');

        expect(transport.getRequests, hasLength(1));
        expect(transport.requests, hasLength(1));
        expect(transport.requests.single.uri.path, '/browse');
        expect(transport.requests.single.body['browseId'], 'MPREb_album123');
        expect(transport.requests.single.body, isNot(contains('query')));
        expect(transport.requests.single.body, isNot(contains('params')));
      },
    );

    test(
      'album lookup validates browse IDs and limits before requests',
      () async {
        final service = createService();

        for (final browseId in const <String>[
          '',
          'FEmusic_home',
          'VLPLcollection123',
          'MPRE bad',
          'MPRE../unsafe',
        ]) {
          await expectLater(
            service.getAlbumSongs(browseId),
            throwsArgumentError,
          );
        }
        await expectLater(
          service.getAlbumSongs('MPREb_album123', limit: 0),
          throwsRangeError,
        );
        await expectLater(
          service.getAlbumSongs(
            'MPREb_album123',
            limit: InnerTubeSearchService.maxDetailResults + 1,
          ),
          throwsRangeError,
        );

        expect(transport.getRequests, isEmpty);
        expect(transport.requests, isEmpty);
      },
    );

    test('refreshes bootstrap once for album browse', () async {
      transport.responses.addAll([
        const InnerTubeHttpResponse(
          statusCode: HttpStatus.unauthorized,
          body: '{"error":"stale album client"}',
        ),
        InnerTubeHttpResponse(
          statusCode: HttpStatus.ok,
          body: jsonEncode(
            _albumDetailPayload(
              title: 'Album',
              artists: const ['Artist'],
              tracks: const [],
            ),
          ),
        ),
      ]);
      final service = createService();

      expect(await service.getAlbumSongs('MPREb_album123'), isEmpty);

      expect(transport.getRequests, hasLength(2));
      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.every(
          (request) => request.body['browseId'] == 'MPREb_album123',
        ),
        isTrue,
      );
    });

    test('album browse preserves typed HTTP and JSON errors', () async {
      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.tooManyRequests,
        body: '{"error":"slow down album"}',
      );
      final httpService = createService();
      await expectLater(
        httpService.getAlbumSongs('MPREb_album123'),
        throwsA(
          isA<InnerTubeHttpException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having(
                (error) => error.body,
                'body',
                contains('slow down album'),
              ),
        ),
      );

      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.ok,
        body: '{not-json',
      );
      final formatService = createService();
      await expectLater(
        formatService.getAlbumSongs('MPREb_album123'),
        throwsA(isA<InnerTubeFormatException>()),
      );
    });

    test('validates home limits before bootstrap or browse requests', () async {
      final service = createService();

      await expectLater(service.getHome(maxSections: 0), throwsRangeError);
      await expectLater(
        service.getHome(
          maxSections: InnerTubeSearchService.maxHomeSections + 1,
        ),
        throwsRangeError,
      );
      await expectLater(
        service.getHome(maxItemsPerSection: 0),
        throwsRangeError,
      );
      await expectLater(
        service.getHome(
          maxItemsPerSection: InnerTubeSearchService.maxResults + 1,
        ),
        throwsRangeError,
      );

      expect(transport.getRequests, isEmpty);
      expect(transport.requests, isEmpty);
    });

    test('turns home HTTP failures into typed errors', () async {
      transport.response = const InnerTubeHttpResponse(
        statusCode: HttpStatus.tooManyRequests,
        body: '{"error":"slow down home"}',
      );
      final service = createService();

      await expectLater(
        service.getHome(),
        throwsA(
          isA<InnerTubeHttpException>()
              .having((error) => error.statusCode, 'statusCode', 429)
              .having(
                (error) => error.body,
                'body',
                contains('slow down home'),
              ),
        ),
      );
      expect(transport.requests, hasLength(3));
      expect(
        transport.requests.every((request) => request.uri.path == '/browse'),
        isTrue,
      );
    });
  });

  group('InnerTubeSearchParser', () {
    const parser = InnerTubeSearchParser();

    test('extracts multiple artists, album and long duration', () {
      final result = parser.parse(
        _searchPayload([
          _songRenderer(
            videoId: 'collab-video',
            title: 'Collaboration',
            artists: const ['Artist One', 'Artist Two'],
            album: 'Album Name',
            duration: '1:02:03',
            durationInFixedColumn: true,
          ),
        ]),
      );

      expect(result.single.artists, const ['Artist One', 'Artist Two']);
      expect(result.single.artist, 'Artist One, Artist Two');
      expect(result.single.album, 'Album Name');
      expect(result.single.albumBrowseId, 'MPREalbumResult');
      expect(
        result.single.duration,
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
    });

    test('uses watchEndpoint when playlistItemData is absent', () {
      final result = parser.parse(
        _searchPayload([
          _songRenderer(
            videoId: 'watch-fallback',
            title: 'Fallback',
            artists: const ['Artist'],
            includePlaylistItemData: false,
          ),
        ]),
      );

      expect(result.single.videoId, 'watch-fallback');
    });

    test('skips malformed items and duplicate video IDs', () {
      final duplicate = _songRenderer(
        videoId: 'same-video',
        title: 'Same song',
        artists: const ['Artist'],
      );
      final result = parser.parse(
        _searchPayload([
          const {'musicResponsiveListItemRenderer': <String, Object>{}},
          duplicate,
          duplicate,
        ]),
      );

      expect(result, hasLength(1));
      expect(result.single.videoId, 'same-video');
    });

    test('never returns more than 20 results', () {
      final items = List.generate(
        25,
        (index) => _songRenderer(
          videoId: 'video-$index',
          title: 'Song $index',
          artists: const ['Artist'],
        ),
      );

      final result = parser.parse(_searchPayload(items));

      expect(result, hasLength(InnerTubeSearchService.maxResults));
      expect(result.last.videoId, 'video-19');
    });

    test('detail parsing has an independent bounded 100-song limit', () {
      final items = List.generate(
        105,
        (index) => _songRenderer(
          videoId: 'detail-$index',
          title: 'Detail song $index',
          artists: const ['Artist'],
        ),
      );

      final result = parser.parseDetailSongs(_searchPayload(items));

      expect(result, hasLength(InnerTubeSearchService.maxDetailResults));
      expect(result.last.videoId, 'detail-99');
      expect(
        () => parser.parseDetailSongs(
          const {},
          limit: InnerTubeSearchService.maxDetailResults + 1,
        ),
        throwsRangeError,
      );
      expect(() => parser.parse(const {}, limit: 21), throwsRangeError);
    });

    test('keeps optional metadata absent instead of rejecting the song', () {
      final result = parser.parse(
        _searchPayload([
          _songRenderer(
            videoId: 'minimal-video',
            title: 'Minimal',
            artists: const [],
          ),
        ]),
      );

      expect(result.single.artists, isEmpty);
      expect(result.single.album, isNull);
      expect(result.single.duration, isNull);
      expect(result.single.thumbnailUrl, isNull);
    });
  });

  group('InnerTubeAlbumParser', () {
    const parser = InnerTubeAlbumParser();

    test('parses responsive album metadata and prefers audio playlist', () {
      final albums = parser.parse(
        _searchPayload([
          _albumRenderer(
            browseId: 'MPREb_primary123',
            title: 'Morning Glory',
            artists: const ['Oasis', 'Guest'],
            type: 'Album',
            year: '1995',
            playlistId: 'OLAK5uy_audioplaylist123',
            radioPlaylistId: 'RDAMVMradio12345',
            thumbnails: const [
              ('https://img.test/60.jpg', 60),
              ('//img.test/544.jpg', 544),
            ],
          ),
        ]),
      );

      expect(albums, hasLength(1));
      expect(albums.single.browseId, 'MPREb_primary123');
      expect(albums.single.title, 'Morning Glory');
      expect(albums.single.artists, const ['Oasis', 'Guest']);
      expect(albums.single.type, 'Album');
      expect(albums.single.year, '1995');
      expect(albums.single.playlistId, 'OLAK5uy_audioplaylist123');
      expect(albums.single.thumbnailUrl, 'https://img.test/544.jpg');
    });

    test('normalizes nested legacy artist text and album-header fallbacks', () {
      final nestedSong = const InnerTubeSearchParser().parseDetailSongs(
        _searchPayload([
          _legacyNestedArtistSongRenderer(
            videoId: 'nested-artist',
            title: 'Nested artist song',
            nestedText: 'Nested artist',
          ),
        ]),
        limit: 1,
      );
      expect(nestedSong.single.artists, const ['Nested artist']);
      expect(nestedSong.single.artist, isNot(contains('{runs')));

      final examples = [
        (
          title: 'Valor de la Calle',
          artists: const ['Tiago PZK', 'Emkier'],
          tracks: const ['Solo Los Dos', 'Gira en el Norte', '3 Am', 'Mañana'],
        ),
        (
          title: 'Residente o Visitante',
          artists: const ['Calle 13'],
          tracks: const ['Intro', 'Tango del Pecado', 'La Fokin Moda'],
        ),
        (
          title: 'Calle 13',
          artists: const ['Calle 13'],
          tracks: const ['Cabe-c-o', 'Suave', 'La Aguacatona'],
        ),
      ];

      for (final example in examples) {
        final songs = const InnerTubeAlbumParser().parseSongs(
          _albumDetailPayload(
            title: example.title,
            artists: example.artists,
            tracks: [
              for (var index = 0; index < example.tracks.length; index++)
                _legacyNestedArtistSongRenderer(
                  videoId: 'legacy-${example.title}-$index',
                  title: example.tracks[index],
                  nestedText: 'Ir al artista',
                ),
            ],
          ),
        );

        expect(songs, hasLength(example.tracks.length), reason: example.title);
        expect(
          songs.map((song) => song.artists),
          everyElement(equals(example.artists)),
          reason: example.title,
        );
        expect(
          songs.every(
            (song) =>
                !song.artist.contains('{runs') &&
                !song.artist.contains('Ir al artista'),
          ),
          isTrue,
          reason: example.title,
        );
      }
    });

    test('supports two-row albums and keeps optional metadata absent', () {
      final albums = parser.parse(
        _searchPayload([
          _twoRowAlbumRenderer(
            browseId: 'MPREb_tworow123',
            title: 'Minimal release',
          ),
        ]),
      );

      expect(albums.single.browseId, 'MPREb_tworow123');
      expect(albums.single.title, 'Minimal release');
      expect(albums.single.artists, isEmpty);
      expect(albums.single.type, isNull);
      expect(albums.single.year, isNull);
      expect(albums.single.playlistId, isNull);
      expect(albums.single.thumbnailUrl, isNull);
    });

    test('skips malformed albums and deduplicates by browse ID', () {
      final duplicate = _albumRenderer(
        browseId: 'MPREb_duplicate123',
        title: 'Duplicate',
        artists: const ['Artist'],
      );
      final albums = parser.parse(
        _searchPayload([
          const {'musicResponsiveListItemRenderer': <String, Object>{}},
          _songRenderer(
            videoId: 'notalbum001',
            title: 'Song row',
            artists: const ['Artist'],
          ),
          duplicate,
          duplicate,
        ]),
      );

      expect(albums, hasLength(1));
      expect(albums.single.browseId, 'MPREb_duplicate123');
    });

    test('validates root and result limits', () {
      expect(
        () => parser.parse(const []),
        throwsA(isA<InnerTubeFormatException>()),
      );
      expect(() => parser.parse(const {}, limit: 0), throwsRangeError);
      expect(() => parser.parse(const {}, limit: 21), throwsRangeError);
      expect(
        () => parser.parseSongs(const [], limit: 1),
        throwsA(isA<InnerTubeFormatException>()),
      );
      expect(
        () => parser.parseSongs(
          const {},
          limit: InnerTubeSearchService.maxDetailResults + 1,
        ),
        throwsRangeError,
      );
    });
  });

  group('InnerTubeHomeParser', () {
    const parser = InnerTubeHomeParser();

    test('parses responsive and two-row songs from a carousel', () {
      final sections = parser.parse(
        _homePayload([
          _homeCarousel(
            title: 'Para escuchar',
            items: [
              _songRenderer(
                videoId: 'responsive',
                title: 'Responsive song',
                artists: const ['First artist'],
                duration: '3:21',
              ),
              _twoRowSongRenderer(
                videoId: 'two-row-song',
                title: 'Two row song',
                artists: const ['Second artist', 'Guest artist'],
                album: 'Two row album',
                duration: '4:05',
                thumbnails: const [
                  ('//img.test/120.jpg', 120),
                  ('https://img.test/480.jpg', 480),
                ],
              ),
              _twoRowSongRenderer(
                videoId: 'ignored-playlist',
                title: 'A playlist, not a song',
                artists: const [],
                playable: false,
              ),
            ],
          ),
        ]),
      );

      expect(sections, hasLength(1));
      expect(sections.single.title, 'Para escuchar');
      expect(sections.single.songs.map((song) => song.videoId), [
        'responsive',
        'two-row-song',
      ]);
      final twoRow = sections.single.songs.last;
      expect(twoRow.artists, const ['Second artist', 'Guest artist']);
      expect(twoRow.album, 'Two row album');
      expect(twoRow.duration, const Duration(minutes: 4, seconds: 5));
      expect(twoRow.thumbnailUrl, 'https://img.test/480.jpg');
    });

    test(
      'preserves mixed song, artist, and collection order with metadata',
      () {
        final sections = parser.parse(
          _homePayload([
            _homeCarousel(
              title: 'Para ti',
              items: [
                _songRenderer(
                  videoId: 'mixed-song-1',
                  title: 'First song',
                  artists: const ['First artist'],
                ),
                _artistRenderer(
                  browseId: 'UCpopularartist123',
                  name: 'Popular artist',
                  thumbnails: const [
                    ('//img.test/artist-120.jpg', 120),
                    ('https://img.test/artist-480.jpg', 480),
                  ],
                ),
                _collectionRenderer(
                  title: 'Mix relajante',
                  subtitle: 'Artista uno, Artista dos',
                  browseId: 'VLRDmixcollection123',
                  playlistId: 'RDmixcollection123',
                  thumbnails: const [
                    ('//img.test/226.jpg', 226),
                    ('https://img.test/544.jpg', 544),
                  ],
                ),
                _twoRowSongRenderer(
                  videoId: 'mixed-song-2',
                  title: 'Second song',
                  artists: const ['Second artist'],
                ),
              ],
            ),
          ]),
        );

        expect(sections, hasLength(1));
        expect(sections.single.items, hasLength(4));
        expect(sections.single.items[0], isA<InnerTubeHomeSongItem>());
        expect(sections.single.items[1], isA<InnerTubeHomeArtistItem>());
        expect(sections.single.items[2], isA<InnerTubeHomeCollection>());
        expect(sections.single.items[3], isA<InnerTubeHomeSongItem>());
        expect(sections.single.songs.map((song) => song.videoId), [
          'mixed-song-1',
          'mixed-song-2',
        ]);

        final artist = sections.single.artists.single;
        expect(artist.browseId, 'UCpopularartist123');
        expect(artist.name, 'Popular artist');
        expect(artist.thumbnailUrl, 'https://img.test/artist-480.jpg');

        final collection = sections.single.collections.single;
        expect(collection.title, 'Mix relajante');
        expect(collection.subtitle, 'Artista uno, Artista dos');
        expect(collection.browseId, 'VLRDmixcollection123');
        expect(collection.playlistId, 'RDmixcollection123');
        expect(collection.thumbnailUrl, 'https://img.test/544.jpg');
        expect(collection.kind, InnerTubeHomeCollectionKind.mix);
      },
    );

    test('deduplicates artists globally while respecting item limits', () {
      final duplicateArtist = _artistRenderer(
        browseId: 'UCduplicateartist1',
        name: 'Duplicate artist',
      );
      final sections = parser.parse(
        _homePayload([
          _homeCarousel(
            title: 'First artist shelf',
            items: [
              duplicateArtist,
              duplicateArtist,
              _artistRenderer(
                browseId: 'UCsecondartist001',
                name: 'Second artist',
              ),
              _artistRenderer(
                browseId: 'UCoveritemlimit1',
                name: 'Over item limit',
              ),
            ],
          ),
          _homeCarousel(
            title: 'Second artist shelf',
            items: [
              duplicateArtist,
              _artistRenderer(
                browseId: 'UCoveritemlimit1',
                name: 'Recovered after limit',
              ),
            ],
          ),
          _homeCarousel(
            title: 'Over section limit',
            items: [
              _artistRenderer(
                browseId: 'UCoversectionlimit',
                name: 'Over section limit',
              ),
            ],
          ),
        ]),
        maxSections: 2,
        maxItemsPerSection: 2,
      );

      expect(sections.map((section) => section.title), [
        'First artist shelf',
        'Second artist shelf',
      ]);
      expect(sections.first.artists.map((artist) => artist.browseId), [
        'UCduplicateartist1',
        'UCsecondartist001',
      ]);
      expect(sections.last.artists.map((artist) => artist.browseId), [
        'UCoveritemlimit1',
      ]);
      expect(
        sections
            .expand((section) => section.artists)
            .where((artist) => artist.browseId == 'UCduplicateartist1'),
        hasLength(1),
      );
    });

    test('derives safe collection browse IDs from playlist endpoints', () {
      final sections = parser.parse(
        _homePayload([
          _homeCarousel(
            title: 'Colecciones',
            items: [
              _collectionRenderer(
                title: 'Playlist directa',
                subtitle: 'Un artista',
                playlistId: 'PLsafeplaylist123',
              ),
              _collectionRenderer(
                title: 'Mix desde watch',
                subtitle: 'Otro artista',
                playlistId: 'RDsafemixplaylist123',
                useWatchEndpoint: true,
              ),
              _collectionRenderer(
                title: 'Endpoint inseguro',
                playlistId: '../unsafe',
              ),
            ],
          ),
        ]),
      );

      expect(sections.single.collections, hasLength(2));
      expect(sections.single.collections[0].browseId, 'VLPLsafeplaylist123');
      expect(
        sections.single.collections[0].kind,
        InnerTubeHomeCollectionKind.playlist,
      );
      expect(sections.single.collections[1].browseId, 'VLRDsafemixplaylist123');
      expect(
        sections.single.collections[1].kind,
        InnerTubeHomeCollectionKind.mix,
      );
    });

    test(
      'limits mixed items and deduplicates songs and collections globally',
      () {
        final duplicateSong = _songRenderer(
          videoId: 'same-video',
          title: 'Same song',
          artists: const ['Artist'],
        );
        final duplicateCollection = _collectionRenderer(
          title: 'Same collection',
          browseId: 'VLPLsamecollection123',
          playlistId: 'PLsamecollection123',
        );
        final sections = parser.parse(
          _homePayload([
            _homeCarousel(
              title: 'First mixed shelf',
              items: [
                duplicateSong,
                duplicateCollection,
                _songRenderer(
                  videoId: 'over-limit',
                  title: 'Over limit',
                  artists: const ['Artist'],
                ),
              ],
            ),
            _homeCarousel(
              title: 'Second mixed shelf',
              items: [
                duplicateSong,
                duplicateCollection,
                _collectionRenderer(
                  title: 'Unique collection',
                  browseId: 'VLPLuniquecollection123',
                  playlistId: 'PLuniquecollection123',
                ),
              ],
            ),
          ]),
          maxItemsPerSection: 2,
        );

        expect(sections, hasLength(2));
        expect(sections.first.items, hasLength(2));
        expect(sections.first.songs.single.videoId, 'same-video');
        expect(
          sections.first.collections.single.browseId,
          'VLPLsamecollection123',
        );
        expect(sections.last.items, hasLength(1));
        expect(
          sections.last.collections.single.browseId,
          'VLPLuniquecollection123',
        );
      },
    );

    test('enforces section and item limits while deduplicating globally', () {
      final duplicate = _songRenderer(
        videoId: 'same-video',
        title: 'Same song',
        artists: const ['Artist'],
      );
      final sections = parser.parse(
        _homePayload([
          _homeCarousel(
            title: 'First shelf',
            items: [
              duplicate,
              _songRenderer(
                videoId: 'first-only',
                title: 'First only',
                artists: const ['Artist'],
              ),
              _songRenderer(
                videoId: 'over-item-limit',
                title: 'Too late',
                artists: const ['Artist'],
              ),
            ],
          ),
          _homeCarousel(
            title: 'Second shelf',
            items: [
              duplicate,
              _songRenderer(
                videoId: 'second-only',
                title: 'Second only',
                artists: const ['Artist'],
              ),
            ],
          ),
          _homeCarousel(
            title: 'Over section limit',
            items: [
              _songRenderer(
                videoId: 'third-only',
                title: 'Third only',
                artists: const ['Artist'],
              ),
            ],
          ),
        ]),
        maxSections: 2,
        maxItemsPerSection: 2,
      );

      expect(sections.map((section) => section.title), [
        'First shelf',
        'Second shelf',
      ]);
      expect(sections.first.songs.map((song) => song.videoId), [
        'same-video',
        'first-only',
      ]);
      expect(sections.last.songs.map((song) => song.videoId), ['second-only']);
      expect(
        sections
            .expand((section) => section.songs)
            .map((song) => song.videoId)
            .toSet(),
        hasLength(3),
      );
    });

    test('omits untitled, empty and non-playable shelves', () {
      final sections = parser.parse(
        _homePayload([
          _homeCarousel(
            title: '',
            items: [
              _songRenderer(
                videoId: 'hidden-song',
                title: 'Hidden song',
                artists: const ['Artist'],
              ),
            ],
          ),
          _homeCarousel(title: 'Empty shelf', items: const []),
          _homeCarousel(
            title: 'Playlists only',
            items: [
              _twoRowSongRenderer(
                videoId: 'not-playable',
                title: 'Playlist',
                artists: const [],
                playable: false,
              ),
            ],
          ),
        ]),
      );

      expect(sections, isEmpty);
      expect(
        () => parser.parse(const []),
        throwsA(isA<InnerTubeFormatException>()),
      );
    });
  });

  group('InnerTubeArtistSearchParser', () {
    const parser = InnerTubeArtistSearchParser();

    test('parses responsive and two-row artists with stable deduplication', () {
      final artists = parser.parse(
        _searchPayload([
          _responsiveArtistRenderer(
            browseId: 'UCfirstArtist123',
            name: 'First artist',
            thumbnails: const [
              ('//img.test/first-60.jpg', 60),
              ('https://img.test/first-240.jpg', 240),
            ],
          ),
          _artistRenderer(
            browseId: 'MPLAsecondArtist123',
            name: 'Second artist',
            thumbnails: const [('https://img.test/second.jpg', 120)],
            endpointOnTitleOnly: true,
          ),
          _responsiveArtistRenderer(
            browseId: 'UCfirstArtist123',
            name: 'Duplicate first artist',
          ),
        ]),
      );

      expect(artists, hasLength(2));
      expect(artists.first.browseId, 'UCfirstArtist123');
      expect(artists.first.name, 'First artist');
      expect(artists.first.thumbnailUrl, 'https://img.test/first-240.jpg');
      expect(artists.last.browseId, 'MPLAsecondArtist123');
      expect(artists.last.name, 'Second artist');
      expect(artists.last.thumbnailUrl, 'https://img.test/second.jpg');
      expect(
        parser.parse(
          _searchPayload([
            _artistRenderer(browseId: 'UCfirstArtist123', name: 'First artist'),
          ]),
          limit: 1,
        ),
        hasLength(1),
      );
    });

    test('does not turn song or album artist credits into artist results', () {
      final artists = parser.parse(
        _searchPayload([
          _songRenderer(
            videoId: 'artist-song',
            title: 'A song',
            artists: const ['Credited artist'],
          ),
          _albumRenderer(
            browseId: 'MPREartistAlbum123',
            title: 'An album',
            artists: const ['Album artist'],
          ),
          _responsiveArtistRenderer(
            browseId: 'UCwrongPageType123',
            name: 'Wrong endpoint',
            pageType: 'MUSIC_PAGE_TYPE_ALBUM',
          ),
        ]),
      );

      expect(artists, isEmpty);
    });

    test('validates response roots, browse IDs and limits', () {
      expect(
        () => parser.parse(const []),
        throwsA(isA<InnerTubeFormatException>()),
      );
      expect(() => parser.parse(const {}, limit: 0), throwsRangeError);
      expect(() => parser.parse(const {}, limit: 21), throwsRangeError);
      expect(
        parser.parse(
          _searchPayload([
            _responsiveArtistRenderer(
              browseId: 'not-an-artist-id',
              name: 'Malformed artist',
            ),
          ]),
        ),
        isEmpty,
      );
    });
  });
}

Map<String, Object> _searchPayload(List<Map<String, Object>> items) {
  return {
    'contents': {
      'tabbedSearchResultsRenderer': {
        'tabs': [
          {
            'tabRenderer': {
              'content': {
                'sectionListRenderer': {
                  'contents': [
                    {
                      'musicShelfRenderer': {'contents': items},
                    },
                  ],
                },
              },
            },
          },
        ],
      },
    },
  };
}

Map<String, Object> _albumDetailPayload({
  required String title,
  required List<String> artists,
  required List<Map<String, Object>> tracks,
  List<Map<String, Object>> relatedTracks = const [],
  String? continuation,
}) {
  final artistRuns = <Map<String, Object>>[];
  for (final artist in artists) {
    if (artistRuns.isNotEmpty) {
      artistRuns.add(const {'text': ' • '});
    }
    artistRuns.add(_browseRun(artist, 'MUSIC_PAGE_TYPE_ARTIST'));
  }
  return {
    'header': {
      'musicResponsiveHeaderRenderer': {
        'title': {
          'runs': [
            {'text': title},
          ],
        },
        'straplineTextOne': {'runs': artistRuns},
      },
    },
    'contents': {
      'twoColumnBrowseResultsRenderer': {
        'secondaryContents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicShelfRenderer': {
                  'contents': tracks,
                  if (continuation != null)
                    'continuations': [
                      {
                        'nextContinuationData': {'continuation': continuation},
                      },
                    ],
                },
              },
            ],
          },
        },
      },
    },
    if (relatedTracks.isNotEmpty)
      'related': {
        'musicCarouselShelfRenderer': {'contents': relatedTracks},
      },
  };
}

Map<String, Object> _albumRenderer({
  required String browseId,
  required String title,
  List<String> artists = const [],
  String? type,
  String? year,
  String? playlistId,
  String? radioPlaylistId,
  List<(String, int)> thumbnails = const [],
}) {
  final metadataRuns = <Map<String, Object>>[];

  void addMetadata(Map<String, Object> run) {
    if (metadataRuns.isNotEmpty) {
      metadataRuns.add(const {'text': ' • '});
    }
    metadataRuns.add(run);
  }

  if (type != null) {
    addMetadata({'text': type});
  }
  for (final artist in artists) {
    addMetadata(_browseRun(artist, 'MUSIC_PAGE_TYPE_ARTIST'));
  }
  if (year != null) {
    addMetadata({'text': year});
  }

  final navigationEndpoint = _albumNavigationEndpoint(browseId);
  return {
    'musicResponsiveListItemRenderer': {
      'flexColumns': [
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {
              'runs': [
                {'text': title, 'navigationEndpoint': navigationEndpoint},
              ],
            },
          },
        },
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {'runs': metadataRuns},
          },
        },
      ],
      'navigationEndpoint': navigationEndpoint,
      if (playlistId != null)
        'overlay': {
          'musicItemThumbnailOverlayRenderer': {
            'content': {
              'musicPlayButtonRenderer': {
                'playNavigationEndpoint': {
                  'watchEndpoint': {'playlistId': playlistId},
                },
              },
            },
          },
        },
      if (radioPlaylistId != null)
        'menu': {
          'menuRenderer': {
            'items': [
              {
                'menuNavigationItemRenderer': {
                  'navigationEndpoint': {
                    'watchEndpoint': {'playlistId': radioPlaylistId},
                  },
                },
              },
            ],
          },
        },
      if (thumbnails.isNotEmpty)
        'thumbnail': {
          'musicThumbnailRenderer': {
            'thumbnail': {
              'thumbnails': [
                for (final thumbnail in thumbnails)
                  {
                    'url': thumbnail.$1,
                    'width': thumbnail.$2,
                    'height': thumbnail.$2,
                  },
              ],
            },
          },
        },
    },
  };
}

Map<String, Object> _twoRowAlbumRenderer({
  required String browseId,
  required String title,
  List<String> artists = const [],
  String? type,
  String? year,
  String? playlistId,
  List<(String, int)> thumbnails = const [],
}) {
  final responsive =
      _albumRenderer(
            browseId: browseId,
            title: title,
            artists: artists,
            type: type,
            year: year,
            playlistId: playlistId,
            thumbnails: thumbnails,
          )['musicResponsiveListItemRenderer']!
          as Map<String, Object>;
  final columns = responsive['flexColumns']! as List<Object>;
  final metadataColumn = columns[1] as Map<String, Object>;
  final metadataRenderer =
      metadataColumn['musicResponsiveListItemFlexColumnRenderer']!
          as Map<String, Object>;
  return {
    'musicTwoRowItemRenderer': {
      'title': {
        'runs': [
          {
            'text': title,
            'navigationEndpoint': _albumNavigationEndpoint(browseId),
          },
        ],
      },
      'subtitle': metadataRenderer['text']!,
      'navigationEndpoint': _albumNavigationEndpoint(browseId),
      if (playlistId != null) 'overlay': responsive['overlay']!,
      if (thumbnails.isNotEmpty) 'thumbnailRenderer': responsive['thumbnail']!,
    },
  };
}

Map<String, Object> _albumNavigationEndpoint(String browseId) {
  return {
    'browseEndpoint': {
      'browseId': browseId,
      'browseEndpointContextSupportedConfigs': {
        'browseEndpointContextMusicConfig': {
          'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
        },
      },
    },
  };
}

Map<String, Object> _homePayload(
  List<Map<String, Object>> shelves, {
  String? continuation,
}) {
  return {
    'contents': {
      'singleColumnBrowseResultsRenderer': {
        'tabs': [
          {
            'tabRenderer': {
              'content': {
                'sectionListRenderer': {
                  'contents': shelves,
                  if (continuation != null)
                    'continuations': [
                      {
                        'nextContinuationData': {'continuation': continuation},
                      },
                    ],
                },
              },
            },
          },
        ],
      },
    },
  };
}

Map<String, Object> _homeContinuationPayload(
  List<Map<String, Object>> shelves, {
  String? continuation,
  bool useContinuationCommand = false,
}) {
  return {
    'continuationContents': {
      'sectionListContinuation': {
        'contents': [
          ...shelves,
          if (continuation != null && useContinuationCommand)
            {
              'continuationItemRenderer': {
                'continuationEndpoint': {
                  'continuationCommand': {'token': continuation},
                },
              },
            },
        ],
        if (continuation != null && !useContinuationCommand)
          'continuations': [
            {
              'nextContinuationData': {'continuation': continuation},
            },
          ],
      },
    },
  };
}

Map<String, Object> _homeCarousel({
  required String title,
  required List<Map<String, Object>> items,
}) {
  return {
    'musicCarouselShelfRenderer': {
      'header': {
        'musicCarouselShelfBasicHeaderRenderer': {
          'title': {
            'runs': [
              {'text': title},
            ],
          },
        },
      },
      'contents': items,
    },
  };
}

Map<String, Object> _collectionDetailPayload(
  List<Map<String, Object>> items, {
  String? continuation,
}) {
  return {
    'contents': {
      'twoColumnBrowseResultsRenderer': {
        'secondaryContents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicPlaylistShelfRenderer': {
                  'playlistId': 'PLcollection123',
                  'contents': items,
                  if (continuation != null)
                    'continuations': [
                      {
                        'nextContinuationData': {'continuation': continuation},
                      },
                    ],
                },
              },
            ],
          },
        },
      },
    },
  };
}

Map<String, Object> _publicPlaylistHeader({
  required String title,
  required String owner,
  required List<(String, int)> thumbnails,
}) {
  return {
    'musicDetailHeaderRenderer': {
      'title': {
        'runs': [
          {'text': title},
        ],
      },
      'subtitle': {
        'runs': [
          {'text': 'Playlist'},
          {'text': ' \u2022 '},
          {
            'text': owner,
            'navigationEndpoint': {
              'browseEndpoint': {'browseId': 'UCplaylist-owner'},
            },
          },
          {'text': ' \u2022 '},
          {'text': '2 canciones'},
        ],
      },
      'thumbnail': {
        'musicThumbnailRenderer': {
          'thumbnail': {
            'thumbnails': [
              for (final thumbnail in thumbnails)
                {
                  'url': thumbnail.$1,
                  'width': thumbnail.$2,
                  'height': thumbnail.$2,
                },
            ],
          },
        },
      },
    },
  };
}

Map<String, Object> _detailContinuationPayload(
  List<Map<String, Object>> items, {
  String? continuation,
}) {
  return {
    'continuationContents': {
      'musicPlaylistShelfContinuation': {
        'contents': items,
        if (continuation != null)
          'continuations': [
            {
              'nextContinuationData': {'continuation': continuation},
            },
          ],
      },
    },
  };
}

Map<String, Object> _collectionRenderer({
  required String title,
  String? subtitle,
  String? browseId,
  String? playlistId,
  List<(String, int)> thumbnails = const [],
  bool useWatchEndpoint = false,
}) {
  final browseEndpoint = browseId == null
      ? null
      : <String, Object>{
          'browseEndpoint': {
            'browseId': browseId,
            'browseEndpointContextSupportedConfigs': {
              'browseEndpointContextMusicConfig': {
                'pageType': 'MUSIC_PAGE_TYPE_PLAYLIST',
              },
            },
          },
        };
  final renderer = <String, Object>{
    'title': {
      'runs': [
        {'text': title, ...?browseEndpoint},
      ],
    },
    if (subtitle != null)
      'subtitle': {
        'runs': [
          {'text': subtitle},
        ],
      },
    'navigationEndpoint': ?browseEndpoint,
    if (thumbnails.isNotEmpty)
      'thumbnailRenderer': {
        'musicThumbnailRenderer': {
          'thumbnail': {
            'thumbnails': [
              for (final thumbnail in thumbnails)
                {
                  'url': thumbnail.$1,
                  'width': thumbnail.$2,
                  'height': thumbnail.$2,
                },
            ],
          },
        },
      },
    if (playlistId != null)
      'thumbnailOverlay': {
        'musicItemThumbnailOverlayRenderer': {
          'content': {
            'musicPlayButtonRenderer': {
              'playNavigationEndpoint': useWatchEndpoint
                  ? {
                      'watchEndpoint': {'playlistId': playlistId},
                    }
                  : {
                      'watchPlaylistEndpoint': {'playlistId': playlistId},
                    },
            },
          },
        },
      },
  };
  return {'musicTwoRowItemRenderer': renderer};
}

Map<String, Object> _playerPayload({
  required String videoId,
  required String title,
  required String author,
  String? lengthSeconds,
  List<(String, int)> thumbnails = const [],
  String? musicVideoType = 'MUSIC_VIDEO_TYPE_ATV',
  String? category,
}) {
  return {
    'playabilityStatus': {'status': 'OK'},
    if (category != null)
      'microformat': {
        'playerMicroformatRenderer': {'category': category},
      },
    'videoDetails': {
      'videoId': videoId,
      'title': title,
      'author': author,
      'lengthSeconds': ?lengthSeconds,
      'musicVideoType': ?musicVideoType,
      if (thumbnails.isNotEmpty)
        'thumbnail': {
          'thumbnails': [
            for (final thumbnail in thumbnails)
              {
                'url': thumbnail.$1,
                'width': thumbnail.$2,
                'height': thumbnail.$2,
              },
          ],
        },
    },
  };
}

Map<String, Object> _songRenderer({
  required String videoId,
  required String title,
  required List<String> artists,
  String? album,
  String albumBrowseId = 'MPREalbumResult',
  String? duration,
  List<(String, int)> thumbnails = const [],
  bool durationInFixedColumn = false,
  bool includePlaylistItemData = true,
}) {
  final metadataRuns = <Map<String, Object>>[];
  for (final artist in artists) {
    if (metadataRuns.isNotEmpty) {
      metadataRuns.add(const {'text': ' • '});
    }
    metadataRuns.add(_browseRun(artist, 'MUSIC_PAGE_TYPE_ARTIST'));
  }
  if (album != null) {
    if (metadataRuns.isNotEmpty) {
      metadataRuns.add(const {'text': ' • '});
    }
    metadataRuns.add(
      _browseRun(album, 'MUSIC_PAGE_TYPE_ALBUM', browseId: albumBrowseId),
    );
  }
  if (duration != null && !durationInFixedColumn) {
    if (metadataRuns.isNotEmpty) {
      metadataRuns.add(const {'text': ' • '});
    }
    metadataRuns.add({'text': duration});
  }

  final renderer = <String, Object>{
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {
                'text': title,
                'navigationEndpoint': {
                  'watchEndpoint': {'videoId': videoId},
                },
              },
            ],
          },
        },
      },
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {'runs': metadataRuns},
        },
      },
    ],
  };
  if (includePlaylistItemData) {
    renderer['playlistItemData'] = {'videoId': videoId};
  }
  if (duration != null && durationInFixedColumn) {
    renderer['fixedColumns'] = [
      {
        'musicResponsiveListItemFixedColumnRenderer': {
          'text': {
            'runs': [
              {'text': duration},
            ],
          },
        },
      },
    ];
  }
  if (thumbnails.isNotEmpty) {
    renderer['thumbnail'] = {
      'musicThumbnailRenderer': {
        'thumbnail': {
          'thumbnails': [
            for (final thumbnail in thumbnails)
              {
                'url': thumbnail.$1,
                'width': thumbnail.$2,
                'height': thumbnail.$2,
              },
          ],
        },
      },
    };
  }
  return {'musicResponsiveListItemRenderer': renderer};
}

Map<String, Object> _legacyNestedArtistSongRenderer({
  required String videoId,
  required String title,
  required String nestedText,
}) {
  final item = _songRenderer(videoId: videoId, title: title, artists: const []);
  final renderer =
      item['musicResponsiveListItemRenderer']! as Map<String, Object>;
  final columns = renderer['flexColumns']! as List<Object>;
  final metadataColumn = columns[1] as Map<String, Object>;
  final metadataRenderer =
      metadataColumn['musicResponsiveListItemFlexColumnRenderer']!
          as Map<String, Object>;
  metadataRenderer['text'] = {
    'runs': [
      {
        'text': {
          'runs': [
            {'text': nestedText},
          ],
        },
        'navigationEndpoint': {
          'browseEndpoint': {
            'browseEndpointContextSupportedConfigs': {
              'browseEndpointContextMusicConfig': {
                'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
              },
            },
          },
        },
      },
    ],
  };
  return item;
}

Map<String, Object> _artistRenderer({
  required String browseId,
  required String name,
  List<(String, int)> thumbnails = const [],
  bool endpointOnTitleOnly = false,
}) {
  final endpoint = {
    'browseEndpoint': {
      'browseId': browseId,
      'browseEndpointContextSupportedConfigs': {
        'browseEndpointContextMusicConfig': {
          'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
        },
      },
    },
  };
  return {
    'musicTwoRowItemRenderer': {
      'title': {
        'runs': [
          {'text': name, 'navigationEndpoint': endpoint},
        ],
      },
      if (!endpointOnTitleOnly) 'navigationEndpoint': endpoint,
      if (thumbnails.isNotEmpty)
        'thumbnailRenderer': {
          'musicThumbnailRenderer': {
            'thumbnail': {
              'thumbnails': [
                for (final thumbnail in thumbnails)
                  {
                    'url': thumbnail.$1,
                    'width': thumbnail.$2,
                    'height': thumbnail.$2,
                  },
              ],
            },
          },
        },
    },
  };
}

Map<String, Object> _responsiveArtistRenderer({
  required String browseId,
  required String name,
  List<(String, int)> thumbnails = const [],
  String pageType = 'MUSIC_PAGE_TYPE_ARTIST',
}) {
  final endpoint = <String, Object>{
    'browseEndpoint': {
      'browseId': browseId,
      'browseEndpointContextSupportedConfigs': {
        'browseEndpointContextMusicConfig': {'pageType': pageType},
      },
    },
  };
  return {
    'musicResponsiveListItemRenderer': {
      'flexColumns': [
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {
              'runs': [
                {'text': name},
              ],
            },
          },
        },
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {
              'runs': [
                {'text': 'Artist'},
              ],
            },
          },
        },
      ],
      'navigationEndpoint': endpoint,
      if (thumbnails.isNotEmpty)
        'thumbnail': {
          'musicThumbnailRenderer': {
            'thumbnail': {
              'thumbnails': [
                for (final thumbnail in thumbnails)
                  {
                    'url': thumbnail.$1,
                    'width': thumbnail.$2,
                    'height': thumbnail.$2,
                  },
              ],
            },
          },
        },
    },
  };
}

Map<String, Object> _twoRowSongRenderer({
  required String videoId,
  required String title,
  required List<String> artists,
  String? album,
  String? duration,
  List<(String, int)> thumbnails = const [],
  bool playable = true,
}) {
  final metadataRuns = <Map<String, Object>>[];
  for (final artist in artists) {
    if (metadataRuns.isNotEmpty) {
      metadataRuns.add(const {'text': ' \u2022 '});
    }
    metadataRuns.add(_browseRun(artist, 'MUSIC_PAGE_TYPE_ARTIST'));
  }
  if (album != null) {
    if (metadataRuns.isNotEmpty) {
      metadataRuns.add(const {'text': ' \u2022 '});
    }
    metadataRuns.add(_browseRun(album, 'MUSIC_PAGE_TYPE_ALBUM'));
  }
  if (duration != null) {
    if (metadataRuns.isNotEmpty) {
      metadataRuns.add(const {'text': ' \u2022 '});
    }
    metadataRuns.add({'text': duration});
  }

  return {
    'musicTwoRowItemRenderer': {
      'title': {
        'runs': [
          {
            'text': title,
            if (playable)
              'navigationEndpoint': {
                'watchEndpoint': {'videoId': videoId},
              },
          },
        ],
      },
      'subtitle': {'runs': metadataRuns},
      if (thumbnails.isNotEmpty)
        'thumbnailRenderer': {
          'musicThumbnailRenderer': {
            'thumbnail': {
              'thumbnails': [
                for (final thumbnail in thumbnails)
                  {
                    'url': thumbnail.$1,
                    'width': thumbnail.$2,
                    'height': thumbnail.$2,
                  },
              ],
            },
          },
        },
    },
  };
}

Map<String, Object> _browseRun(
  String text,
  String pageType, {
  String? browseId,
}) {
  return {
    'text': text,
    'navigationEndpoint': {
      'browseEndpoint': {
        'browseId': ?browseId,
        'browseEndpointContextSupportedConfigs': {
          'browseEndpointContextMusicConfig': {'pageType': pageType},
        },
      },
    },
  };
}

class _FakeInnerTubeTransport implements InnerTubeTransport {
  InnerTubeHttpResponse bootstrapResponse = const InnerTubeHttpResponse(
    statusCode: HttpStatus.ok,
    body:
        '<script>{"INNERTUBE_API_KEY":"bootstrap-key",'
        '"INNERTUBE_CLIENT_VERSION":"bootstrap-version",'
        '"INNERTUBE_CLIENT_NAME":"TEST_REMIX",'
        '"INNERTUBE_CONTEXT_CLIENT_NAME":99,'
        '"VISITOR_DATA":"visitor-data"}</script>',
  );
  InnerTubeHttpResponse response = InnerTubeHttpResponse(
    statusCode: HttpStatus.ok,
    body: jsonEncode(_searchPayload(const [])),
  );
  final List<Object> responses = [];
  Object? error;
  Object? bootstrapError;
  Completer<void>? freshBootstrapGate;
  final List<_RecordedRequest> requests = [];
  final List<_RecordedGetRequest> getRequests = [];
  int closeCount = 0;

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    getRequests.add(
      _RecordedGetRequest(
        uri: uri,
        headers: Map.unmodifiable(headers),
        timeout: timeout,
      ),
    );
    if (bootstrapError != null) {
      throw bootstrapError!;
    }
    if (getRequests.length > 1) {
      await freshBootstrapGate?.future;
    }
    return bootstrapResponse;
  }

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    requests.add(
      _RecordedRequest(
        uri: uri,
        headers: Map.unmodifiable(headers),
        body: Map.unmodifiable(body as Map<String, Object>),
        timeout: timeout,
      ),
    );
    if (error != null) {
      throw error!;
    }
    if (responses.isEmpty) {
      return response;
    }
    final outcome = responses.removeAt(0);
    if (outcome is InnerTubeHttpResponse) {
      return outcome;
    }
    throw outcome;
  }

  @override
  void close() {
    closeCount += 1;
  }
}

class _RecordedGetRequest {
  const _RecordedGetRequest({
    required this.uri,
    required this.headers,
    required this.timeout,
  });

  final Uri uri;
  final Map<String, String> headers;
  final Duration? timeout;
}

class _RecordedRequest {
  const _RecordedRequest({
    required this.uri,
    required this.headers,
    required this.body,
    required this.timeout,
  });

  final Uri uri;
  final Map<String, String> headers;
  final Map<String, Object> body;
  final Duration? timeout;
}
