import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/features/music/domain/entities/lyrics_document.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics_lookup.dart';
import 'package:bstream_music/services/lyrics/better_lyrics_service.dart';
import 'package:bstream_music/services/lyrics/lrclib_transport.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:bstream_music/services/lyrics/remote_lyrics_service_base.dart';
import 'package:bstream_music/services/lyrics/youlyplus_lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _lookup = LyricsLookup(
  title: 'A sample song',
  artist: 'A sample artist',
  album: 'A sample album',
  duration: Duration(seconds: 180),
);

void main() {
  for (final better in [false, true]) {
    final provider = better ? 'Better Lyrics' : 'LyricsPlus';
    group(provider, () {
      late _Transport transport;
      late RemoteLyricsServiceBase service;
      late DateTime now;

      RemoteLyricsServiceBase create({
        Duration cacheTtl = const Duration(minutes: 15),
        Duration requestTimeout = const Duration(seconds: 1),
        int maxCacheEntries = 24,
      }) {
        final instance = better
            ? BetterLyricsService(
                userAgent: 'BStream lyrics test',
                transport: transport,
                apiBaseUri: Uri.parse('https://test.invalid/'),
                cacheTtl: cacheTtl,
                requestTimeout: requestTimeout,
                maxCacheEntries: maxCacheEntries,
                clock: () => now,
              )
            : YouLyPlusLyricsService(
                userAgent: 'BStream lyrics test',
                transport: transport,
                apiBaseUri: Uri.parse('https://test.invalid/'),
                cacheTtl: cacheTtl,
                requestTimeout: requestTimeout,
                maxCacheEntries: maxCacheEntries,
                clock: () => now,
              );
        addTearDown(instance.dispose);
        return instance;
      }

      setUp(() {
        now = DateTime.utc(2026, 10, 26);
        transport = _Transport();
        transport.body = better ? _better() : _youly();
        service = create();
      });

      test(
        'uses the documented exact endpoint and supplied metadata',
        () async {
          final result = (await service.findLyrics(_lookup))!;
          final request = transport.requests.single;
          expect(request.path, better ? '/getLyrics' : '/v2/lyrics/get');
          expect(
            request.queryParameters,
            better
                ? {
                    's': 'A sample song',
                    'a': 'A sample artist',
                    'al': 'A sample album',
                    'd': '180',
                  }
                : {
                    'title': 'A sample song',
                    'artist': 'A sample artist',
                    'album': 'A sample album',
                    'duration': '180.0',
                  },
          );
          expect(transport.headers.single['User-Agent'], 'BStream lyrics test');
          expect(transport.headers.single['X-API-Key'], isNull);
          expect(
            transport.timeouts.single,
            lessThanOrEqualTo(const Duration(seconds: 1)),
          );
          expect(transport.timeouts.single, greaterThan(Duration.zero));
          expect(result.provider, provider);
          expect(result.providerId, isNotEmpty);
          expect(result.lines.map((line) => line.text), [
            'First sample',
            'Next sample',
          ]);
          expect(result.lines.map((line) => line.timestamp), [
            const Duration(milliseconds: 1250),
            const Duration(seconds: 5),
          ]);
          expect(result.syncedLyrics, contains('[00:01.250]First sample'));
          expect(result.instrumental, isFalse);
        },
      );

      test(
        'cache keeps document and stable provenance without more requests',
        () async {
          final first = await service.findLyrics(_lookup);
          final second = await service.findLyrics(_lookup);
          expect(second, same(first));
          expect(transport.requests, hasLength(1));
        },
      );

      test(
        'coalesces simultaneous requests without duplicating HTTP work',
        () async {
          final pending = Completer<LrclibResponse>();
          transport.handler = (_) => pending.future;
          final first = service.findLyrics(_lookup);
          final second = service.findLyrics(_lookup);
          expect(identical(first, second), isTrue);
          pending.complete(
            LrclibResponse(statusCode: 200, body: transport.body),
          );
          expect(await second, same(await first));
          expect(transport.requests, hasLength(1));
        },
      );

      test('expires memory cache and fetches again', () async {
        await service.findLyrics(_lookup);
        now = now.add(const Duration(minutes: 16));
        await service.findLyrics(_lookup);
        expect(transport.requests, hasLength(2));
      });

      test('evicts least recently used cache entries', () async {
        service.dispose();
        service = create(maxCacheEntries: 1);
        await service.findLyrics(_lookup);
        await service.findLyrics(
          const LyricsLookup(
            title: 'Another sample',
            artist: 'A sample artist',
          ),
        );
        await service.findLyrics(_lookup);
        expect(transport.requests, hasLength(3));
      });

      test('supports disabling completed-result caching', () async {
        service.dispose();
        service = create(cacheTtl: Duration.zero);
        await service.findLyrics(_lookup);
        await service.findLyrics(_lookup);
        expect(transport.requests, hasLength(2));
      });

      test(
        'oversized parsed documents are not retained in the small memory cache',
        () async {
          final largeText = 'synthetic ' * 40000;
          transport.body = better
              ? jsonEncode({
                  'ttml': '<tt><body><p begin="1s">$largeText</p></body></tt>',
                })
              : jsonEncode({
                  'type': 'Line',
                  'lyrics': [
                    {'time': 1000, 'text': largeText},
                  ],
                });
          expect(await service.findLyrics(_lookup), isNotNull);
          expect(await service.findLyrics(_lookup), isNotNull);
          expect(transport.requests, hasLength(4));
        },
      );

      test(
        'empty or explicitly instrumental payload is a miss, not lyrics',
        () async {
          transport.body = better
              ? jsonEncode({
                  'ttml': '<tt><body><div/></body></tt>',
                  'instrumental': true,
                })
              : jsonEncode({
                  'type': 'None',
                  'instrumental': true,
                  'lyrics': [],
                });
          expect(await service.findLyrics(_lookup), isNull);
        },
      );

      for (final status in [204, 404]) {
        test('HTTP $status is an ordinary cached catalogue miss', () async {
          transport.status = status;
          expect(await service.findLyrics(_lookup), isNull);
          expect(await service.findLyrics(_lookup), isNull);
          expect(transport.requests, hasLength(2));
        });
      }

      for (final status in [401, 403, 422, 500, 503]) {
        test(
          'HTTP $status remains a typed provider error, not instrumental or offline',
          () async {
            transport.status = status;
            await expectLater(
              service.findLyrics(_lookup),
              throwsA(
                isA<RemoteLyricsHttpException>()
                    .having((e) => e.statusCode, 'status', status)
                    .having((e) => e.provider, 'provider', provider),
              ),
            );
            await expectLater(
              service.findLyrics(_lookup),
              throwsA(isA<RemoteLyricsHttpException>()),
            );
            expect(
              transport.requests,
              hasLength(better && status == 401 ? 4 : 2),
            );
          },
        );
      }

      test(
        'honors bounded Retry-After without requesting while limited',
        () async {
          transport.status = 429;
          transport.responseHeaders = {'Retry-After': '9999'};
          await expectLater(
            service.findLyrics(_lookup),
            throwsA(
              isA<RemoteLyricsHttpException>().having(
                (e) => e.retryAfter,
                'cooldown',
                const Duration(minutes: 5),
              ),
            ),
          );
          transport.status = 200;
          await expectLater(
            service.findLyrics(_lookup),
            throwsA(isA<RemoteLyricsHttpException>()),
          );
          expect(transport.requests, hasLength(1));
          now = now.add(const Duration(minutes: 5));
          expect(await service.findLyrics(_lookup), isNotNull);
        },
      );

      test('uses safe cooldown when Retry-After is missing', () async {
        transport.status = 429;
        await expectLater(
          service.findLyrics(_lookup),
          throwsA(
            isA<RemoteLyricsHttpException>().having(
              (e) => e.retryAfter,
              'cooldown',
              const Duration(seconds: 30),
            ),
          ),
        );
      });

      test('parses HTTP-date Retry-After', () async {
        transport.status = 429;
        transport.responseHeaders = {
          'Retry-After': HttpDate.format(now.add(const Duration(seconds: 90))),
        };
        await expectLater(
          service.findLyrics(_lookup),
          throwsA(
            isA<RemoteLyricsHttpException>().having(
              (e) => e.retryAfter,
              'cooldown',
              const Duration(seconds: 90),
            ),
          ),
        );
      });

      test('connection failure stays a connection failure', () async {
        transport.handler = (_) =>
            Future.error(const SocketException('offline'));
        await expectLater(
          service.findLyrics(_lookup),
          throwsA(isA<LyricsConnectionException>()),
        );
      });

      test(
        'bounds request duration even if injected transport does not',
        () async {
          service.dispose();
          service = create(requestTimeout: const Duration(milliseconds: 5));
          transport.handler = (_) => Completer<LrclibResponse>().future;
          await expectLater(
            service.findLyrics(_lookup),
            throwsA(
              isA<LyricsConnectionException>().having(
                (e) => e.cause,
                'cause',
                isA<TimeoutException>(),
              ),
            ),
          );
        },
      );

      for (final malformed in ['{bad json', '[]', '{}']) {
        test(
          'malformed payload $malformed remains an error and is not cached',
          () async {
            transport.body = malformed;
            await expectLater(
              service.findLyrics(_lookup),
              throwsA(isA<FormatException>()),
            );
            transport.body = better ? _better() : _youly();
            expect(await service.findLyrics(_lookup), isNotNull);
            expect(transport.requests, hasLength(2));
          },
        );
      }

      test('rejects conflicting title, artist and duration metadata', () async {
        for (final metadata in [
          {'title': 'A sample song (Live)'},
          {'artist': 'Someone else'},
          {'duration': 230},
        ]) {
          service.dispose();
          service = create(cacheTtl: Duration.zero);
          transport.body = better
              ? _better(metadata: metadata)
              : _youly(metadata: metadata);
          expect(await service.findLyrics(_lookup), isNull);
        }
      });

      test(
        'accepts compilation album while retaining exact recording identity',
        () async {
          transport.body = better
              ? _better(metadata: {'album': 'Compilation'})
              : _youly(metadata: {'album': 'Compilation'});
          expect((await service.findLyrics(_lookup))!.albumName, 'Compilation');
        },
      );

      test(
        'does not assign longer live timeline to studio recording',
        () async {
          transport.body = better
              ? _better(lastTime: '3:59.000')
              : _youly(lastTime: 239000);
          expect(await service.findLyrics(_lookup), isNull);
        },
      );

      test(
        'returns bounded candidates using the same retained document',
        () async {
          final candidates = await service.findSimilarLyrics(_lookup, limit: 1);
          expect(candidates, hasLength(1));
          expect(
            candidates.single.document,
            same(await service.findLyrics(_lookup)),
          );
          expect(await service.findSimilarLyrics(_lookup, limit: 0), isEmpty);
        },
      );

      test(
        'manual title uses supplied title while retaining context hints',
        () async {
          await service.searchLyricsByTitle('Manual sample', context: _lookup);
          final query = transport.requests.single.queryParameters;
          expect(query[better ? 's' : 'title'], 'Manual sample');
          expect(query[better ? 'a' : 'artist'], _lookup.artist);
          expect(query[better ? 'al' : 'album'], _lookup.album);
          expect(
            await service.searchLyricsByTitle(' ', context: _lookup),
            isEmpty,
          );
          expect(transport.requests, hasLength(1));
        },
      );

      test('does not issue unsafe title-only automatic queries', () async {
        expect(
          await service.findLyrics(
            const LyricsLookup(title: 'A sample song', artist: ''),
          ),
          isNull,
        );
        expect(transport.requests, isEmpty);
        expect(
          () => service.findLyrics(
            const LyricsLookup(title: ' ', artist: 'Artist'),
          ),
          throwsArgumentError,
        );
      });

      test('bounded payload is rejected before parsing', () async {
        transport.body =
            'x' * (RemoteLyricsServiceBase.maximumResponseBytes + 1);
        await expectLater(
          service.findLyrics(_lookup),
          throwsA(isA<FormatException>()),
        );
      });

      test('disposal is idempotent and prevents new lookups', () {
        service.dispose();
        service.dispose();
        expect(transport.closeCount, 1);
        expect(() => service.findLyrics(_lookup), throwsStateError);
      });

      test('disposal during request never repopulates the cache', () async {
        final pending = Completer<LrclibResponse>();
        transport.handler = (_) => pending.future;
        final result = service.findLyrics(_lookup);
        final expectation = expectLater(result, throwsStateError);
        service.dispose();
        pending.complete(LrclibResponse(statusCode: 200, body: transport.body));
        await expectation;
      });
    });
  }

  group('YouLyPlus parsing', () {
    for (final embedded in [
      '[00:01.25]First sample\n[00:05.00]Next sample',
      '<tt><body><p begin="1.25s">First sample</p><p begin="5s">Next sample</p></body></tt>',
    ]) {
      test('recovers actual embedded timing from None ($embedded)', () async {
        final transport = _Transport()
          ..body = jsonEncode({'type': 'None', 'lyrics': embedded});
        final service = YouLyPlusLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        final result = (await service.findLyrics(_lookup))!;
        expect(result.lines.map((line) => line.text), [
          'First sample',
          'Next sample',
        ]);
        expect(result.lines.last.timestamp, const Duration(seconds: 5));
        expect(result.plainLyrics, 'First sample\nNext sample');
      });
    }

    test(
      'preserves untimed rows instead of truncating mixed Line lyrics',
      () async {
        final transport = _Transport()
          ..body = jsonEncode({
            'type': 'Line',
            'lyrics': [
              {'time': 1000, 'text': 'First sample'},
              {'text': 'An untimed sample that must not silently disappear'},
              {'time': 5000, 'text': 'Next sample'},
            ],
          });
        final service = YouLyPlusLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        final result = (await service.findLyrics(_lookup))!;
        expect(result.lines, hasLength(2));
        expect(result.plainLyrics, contains('An untimed sample'));
        expect(transport.requests, hasLength(2));
      },
    );

    test('validates durationMs in selected upstream metadata', () async {
      final transport = _Transport()
        ..body = _youly(metadata: {'durationMs': 230000});
      final service = YouLyPlusLyricsService(
        userAgent: 'test',
        transport: transport,
      );
      addTearDown(service.dispose);
      expect(await service.findLyrics(_lookup), isNull);
    });

    test(
      'word timing derives a line start without concatenating syllables incorrectly',
      () async {
        final transport = _Transport()
          ..body = jsonEncode({
            'type': 'Word',
            'lyrics': [
              {
                'syllabus': [
                  {'time': 1250, 'duration': 300, 'text': 'First '},
                  {'time': 1550, 'duration': 500, 'text': 'sample'},
                ],
              },
            ],
          });
        final service = YouLyPlusLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        final result = (await service.findLyrics(_lookup))!;
        expect(result.lines.single.text, 'First sample');
        expect(
          result.lines.single.timestamp,
          const Duration(milliseconds: 1250),
        );
      },
    );

    test('None is unsynchronized text, not instrumental', () async {
      final transport = _Transport()
        ..body = jsonEncode({
          'type': 'None',
          'lyrics': [
            {'time': 0, 'text': 'First sample'},
            {'time': 0, 'text': 'Next sample'},
          ],
        });
      final service = YouLyPlusLyricsService(
        userAgent: 'test',
        transport: transport,
      );
      addTearDown(service.dispose);
      final result = (await service.findLyrics(_lookup))!;
      expect(result.plainLyrics, 'First sample\nNext sample');
      expect(result.lines, isEmpty);
      expect(result.instrumental, isFalse);
    });

    test(
      'metadata permits ampersand versus performer-list punctuation',
      () async {
        final transport = _Transport()
          ..body = _youly(metadata: {'artist': 'Chino, Nacho'});
        final service = YouLyPlusLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        final result = await service.findLyrics(
          const LyricsLookup(title: 'A sample song', artist: 'Chino & Nacho'),
        );
        expect(result, isNotNull);
      },
    );

    test('large response parses safely on bounded background worker', () async {
      final transport = _Transport()
        ..body = jsonEncode({
          'type': 'Line',
          'lyrics': List.generate(
            500,
            (i) => {
              'time': i * 1000,
              'text':
                  'Synthetic sample line number $i with enough text for background parsing',
            },
          ),
        });
      final service = YouLyPlusLyricsService(
        userAgent: 'test',
        transport: transport,
      );
      addTearDown(service.dispose);
      expect(
        (await service.findLyrics(
          const LyricsLookup(title: 'Sample', artist: 'Sample'),
        ))?.lines,
        hasLength(500),
      );
    });
  });

  group('Better Lyrics TTML parsing', () {
    Future<LyricsDocument?> parse(String source) {
      final transport = _Transport()..body = jsonEncode({'ttml': source});
      final service = BetterLyricsService(
        userAgent: 'test',
        transport: transport,
      );
      addTearDown(service.dispose);
      return service.findLyrics(_lookup);
    }

    test(
      'preserves raw inter-span whitespace and excludes translation annotations',
      () async {
        final result = await parse(
          '<tt xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div><p begin="1.25s"><span>First</span> <span>sample</span><span ttm:role="x-translation">Not original</span></p></div></body></tt>',
        );
        expect(result!.lines.single.text, 'First sample');
        expect(
          result.lines.single.timestamp,
          const Duration(milliseconds: 1250),
        );
      },
    );

    test(
      'handles namespace-prefixed TTML, nested spans, CDATA and escapes',
      () async {
        final result = await parse(
          '<tt:tt xmlns:tt="http://www.w3.org/ns/ttml"><tt:body><tt:div><tt:p begin="00:00:01.250"><tt:span><![CDATA[First ]]><tt:span>sample &amp; second</tt:span></tt:span></tt:p></tt:div></tt:body></tt:tt>',
        );
        expect(result!.lines.single.text, 'First sample & second');
      },
    );

    test(
      'derives timing from the earliest nested timed word if line omits begin',
      () async {
        final result = await parse(
          '<tt><body><div><p><span><span begin="0:05.000">First </span><span begin="5.5s">sample</span></span></p></div></body></tt>',
        );
        expect(result!.lines.single.timestamp, const Duration(seconds: 5));
      },
    );

    test(
      'untimed paragraphs remain plain lyrics rather than fake synchronized lyrics',
      () async {
        final result = await parse(
          '<tt><body><div><p>First sample</p></div></body></tt>',
        );
        expect(result!.plainLyrics, 'First sample');
        expect(result.lines, isEmpty);
      },
    );

    test('metadata transliteration is not mixed into original lyrics', () async {
      final result = await parse(
        '<tt><head><metadata><transliterations><p begin="0s">Not original</p></transliterations></metadata></head><body><div><p begin="1s">Original sample</p></div></body></tt>',
      );
      expect(result!.lines.single.text, 'Original sample');
    });

    for (final source in [
      '<tt><body><div><p begin="not-a-time">Sample</p></div></body></tt>',
      '<tt><body><p>broken',
      '<html>not TTML</html>',
      '<!DOCTYPE tt SYSTEM "https://bad.invalid/secret"><tt><body/></tt>',
    ]) {
      test('rejects invalid or unsafe TTML $source', () async {
        await expectLater(parse(source), throwsA(isA<FormatException>()));
      });
    }

    test(
      'rejects weak match confidence without presenting incorrect lyrics',
      () async {
        final transport = _Transport()
          ..body = jsonEncode({
            'score': 0.5,
            'ttml': '<tt><body><p begin="1s">Sample</p></body></tt>',
          });
        final service = BetterLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        expect(await service.findLyrics(_lookup), isNull);
      },
    );

    test(
      'large TTML decodes XML and reduces to lines on background worker',
      () async {
        final body = List.generate(
          600,
          (i) => '<p begin="${i / 10}s"><span>Synthetic sample $i</span></p>',
        ).join();
        final result = await parse('<tt><body><div>$body</div></body></tt>');
        expect(result!.lines, hasLength(600));
      },
    );
  });

  group('bounded provider-specific discovery', () {
    for (final better in [false, true]) {
      final provider = better ? 'Better Lyrics' : 'LyricsPlus';
      RemoteLyricsServiceBase create(_Transport transport) {
        final service = better
            ? BetterLyricsService(userAgent: 'test', transport: transport)
            : YouLyPlusLyricsService(userAgent: 'test', transport: transport);
        addTearDown(service.dispose);
        return service;
      }

      test(
        '$provider shares one timeout budget across at most three attempts',
        () async {
          final transport = _Transport();
          transport.handler = (_) async {
            if (transport.requests.length == 1) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            return LrclibResponse(statusCode: 404, body: '');
          };
          expect(
            await create(transport).findLyrics(
              const LyricsLookup(
                title: 'A sample song (Official Video)',
                artist: 'A sample artist - Topic',
                album: 'Compilation',
              ),
            ),
            isNull,
          );
          expect(transport.requests, hasLength(3));
          expect(
            transport.timeouts.first,
            lessThanOrEqualTo(const Duration(seconds: 7)),
          );
          expect(transport.timeouts[1], lessThan(transport.timeouts.first!));
          expect(transport.timeouts[2], lessThan(transport.timeouts[1]!));
        },
      );

      for (final artists in [
        ('Queen', 'Queen Naija'),
        ('Coldplay', 'Coldplay Tribute Band'),
      ]) {
        test(
          '$provider rejects different artist sharing only name tokens ${artists.$1}',
          () async {
            final transport = _Transport()
              ..body = better
                  ? _better(metadata: {'artist': artists.$2})
                  : _youly(metadata: {'artist': artists.$2});
            expect(
              await create(transport).findLyrics(
                LyricsLookup(
                  title: _lookup.title,
                  artist: artists.$1,
                  duration: _lookup.duration,
                ),
              ),
              isNull,
            );
          },
        );
      }

      test(
        '$provider retries safe presentation metadata after a miss',
        () async {
          final transport = _Transport();
          transport.handler = (uri) async {
            if (transport.requests.length == 1) {
              return LrclibResponse(statusCode: 404, body: '');
            }
            return LrclibResponse(
              statusCode: 200,
              body: better
                  ? _better(
                      metadata: {
                        'title': 'A sample song',
                        'artist': 'A sample artist',
                      },
                    )
                  : _youly(
                      metadata: {
                        'title': 'A sample song',
                        'artist': 'A sample artist',
                      },
                    ),
            );
          };
          final result = await create(transport).findLyrics(
            const LyricsLookup(
              title: 'A sample artist - A sample song (Official Video)',
              artist: 'A sample artist - Topic',
              album: 'A sample album',
              duration: Duration(seconds: 180),
            ),
          );
          expect(result?.hasSyncedLyrics, isTrue);
          expect(transport.requests, hasLength(2));
          expect(
            transport.requests.last.queryParameters[better ? 's' : 'title'],
            'A sample song',
          );
          expect(
            transport.requests.last.queryParameters[better ? 'a' : 'artist'],
            'A sample artist',
          );
        },
      );

      for (final qualifier in [
        'Live',
        'Remix',
        'Acoustic',
        'Cover',
        'Remastered 2021',
        'Sped up',
      ]) {
        test('$provider never drops recording qualifier $qualifier', () async {
          final transport = _Transport()
            ..body = better
                ? _better(metadata: {'title': 'A sample song'})
                : _youly(metadata: {'title': 'A sample song'});
          final result = await create(transport).findLyrics(
            LyricsLookup(
              title: 'A sample song ($qualifier) (Official Video)',
              artist: 'A sample artist',
              album: 'Compilation',
            ),
          );
          expect(result, isNull);
          expect(transport.requests.length, lessThanOrEqualTo(3));
          for (final uri in transport.requests) {
            expect(
              uri.queryParameters[better ? 's' : 'title'],
              contains(qualifier),
            );
            expect(uri.queryParameters.containsKey('forceReload'), isFalse);
          }
        });
      }

      test(
        '$provider accepts accent/featured artist metadata without fuzzy wrong-title matches',
        () async {
          final transport = _Transport()
            ..body = better
                ? _better(metadata: {'title': 'Canción', 'artist': 'Beyoncé'})
                : _youly(metadata: {'title': 'Canción', 'artist': 'Beyoncé'});
          final result = await create(transport).findLyrics(
            const LyricsLookup(
              title: 'Cancion (feat. Guest)',
              artist: 'Beyonce feat. Guest',
            ),
          );
          expect(result, isNotNull);
          expect(transport.requests, hasLength(1));
        },
      );

      for (final failure in ['timeout', 'connection', 'malformed', 'server']) {
        test(
          '$provider retains earlier plain lyrics after later $failure',
          () async {
            final transport = _Transport();
            transport.handler = (uri) async {
              if (transport.requests.length == 1) {
                return LrclibResponse(
                  statusCode: 200,
                  body: better
                      ? jsonEncode({
                          'ttml':
                              '<tt><body><p>First plain sample</p></body></tt>',
                        })
                      : jsonEncode({
                          'type': 'None',
                          'lyrics': [
                            {'text': 'First plain sample'},
                          ],
                        }),
                );
              }
              if (failure == 'timeout') throw TimeoutException('sample');
              if (failure == 'connection') {
                throw const SocketException('sample');
              }
              return LrclibResponse(
                statusCode: failure == 'server' ? 503 : 200,
                body: '{bad',
              );
            };
            final result = await create(transport).findLyrics(_lookup);
            expect(result?.plainLyrics, 'First plain sample');
            expect(result?.lines, isEmpty);
            expect(transport.requests, hasLength(2));
          },
        );
      }
    }

    test('LyricsPlus removes stale album hint but retains duration', () async {
      final transport = _Transport();
      transport.handler = (uri) async =>
          uri.queryParameters.containsKey('album')
          ? LrclibResponse(statusCode: 404, body: '')
          : LrclibResponse(statusCode: 200, body: _youly());
      final service = YouLyPlusLyricsService(
        userAgent: 'test',
        transport: transport,
      );
      addTearDown(service.dispose);
      expect((await service.findLyrics(_lookup))?.hasSyncedLyrics, isTrue);
      expect(transport.requests, hasLength(2));
      expect(transport.requests.last.queryParameters['duration'], '180.0');
    });

    test(
      'Better uses documented public Kugou after TTML cache authentication miss',
      () async {
        final transport = _Transport();
        transport.handler = (uri) async => uri.path == '/getLyrics'
            ? LrclibResponse(statusCode: 401, body: '{}')
            : LrclibResponse(
                statusCode: 200,
                body: jsonEncode({
                  'provider': 'kugou',
                  'lyrics': '[00:01.25]First sample\n[00:05.00]Next sample',
                }),
              );
        final service = BetterLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        final result = await service.findLyrics(_lookup);
        expect(result?.provider, 'Better Lyrics');
        expect(result?.providerId, startsWith('betterlyrics:kugou:'));
        expect(result?.lines, hasLength(2));
        expect(transport.requests.map((uri) => uri.path), [
          '/getLyrics',
          '/kugou/getLyrics',
        ]);
        expect(
          transport.headers.every(
            (headers) => !headers.containsKey('X-API-Key'),
          ),
          isTrue,
        );
      },
    );

    test(
      'Better public LRC preserves untimed verses for completeness checks',
      () async {
        final transport = _Transport()
          ..body = jsonEncode({
            'provider': 'kugou',
            'lyrics':
                '[ar:Sample]\n[00:01.25]First sample\nA long untimed middle sample verse should survive\n[00:05.00]Next sample',
          });
        final service = BetterLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        final result = await service.findLyrics(_lookup);
        expect(result?.plainLyrics, contains('A long untimed middle'));
        expect(result?.plainLyrics, isNot(contains('[ar:')));
        expect(result?.lines, hasLength(2));
      },
    );

    test(
      'Better public LRC still rejects conflicting upstream metadata',
      () async {
        final transport = _Transport()
          ..body = jsonEncode({
            'provider': 'kugou',
            'metadata': {'title': 'A different recording'},
            'lyrics': '[00:01.25]First sample\n[00:05.00]Next sample',
          });
        final service = BetterLyricsService(
          userAgent: 'test',
          transport: transport,
        );
        addTearDown(service.dispose);
        expect(await service.findLyrics(_lookup), isNull);
      },
    );
  });
}

String _youly({
  Map<String, Object?> metadata = const {},
  int lastTime = 5000,
}) => jsonEncode({
  'type': 'Line',
  'processingTime': {'selectedSongMetadata': metadata},
  'lyrics': [
    {'time': 1250, 'duration': 1000, 'text': 'First sample'},
    {'time': lastTime, 'duration': 1000, 'text': 'Next sample'},
  ],
});

String _better({
  Map<String, Object?> metadata = const {},
  String lastTime = '0:05.000',
}) => jsonEncode({
  'metadata': metadata,
  'ttml':
      '<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="00:00:01.250"><span begin="1.25s">First </span><span begin="1.5s">sample</span></p><p begin="$lastTime">Next sample</p></div></body></tt>',
});

class _Transport implements LrclibTransport {
  String body = '';
  int status = 200;
  int closeCount = 0;
  Map<String, String> responseHeaders = {};
  final requests = <Uri>[];
  final headers = <Map<String, String>>[];
  final timeouts = <Duration?>[];
  Future<LrclibResponse> Function(Uri)? handler;

  @override
  Future<LrclibResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    requests.add(uri);
    this.headers.add(headers);
    timeouts.add(timeout);
    return await handler?.call(uri) ??
        LrclibResponse(
          statusCode: status,
          body: body,
          headers: responseHeaders,
        );
  }

  @override
  void close() => closeCount++;
}
