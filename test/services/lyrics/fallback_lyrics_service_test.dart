import 'dart:async';

import 'package:bstream_music/features/music/domain/entities/lyric_line.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics_candidate.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics_document.dart';
import 'package:bstream_music/features/music/domain/entities/lyrics_lookup.dart';
import 'package:bstream_music/services/lyrics/fallback_lyrics_service.dart';
import 'package:bstream_music/services/lyrics/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _lookup = LyricsLookup(
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(seconds: 180),
  sourceId: 'video',
);

void main() {
  group('findLyrics', () {
    test(
      'first synchronized lyrics win without consulting lower priorities',
      () async {
        final calls = <String>[];
        final expected = _synced('LRCLIB');
        final first = _Provider('LRCLIB', calls, document: expected);
        final second = _Provider(
          'YouLyPlus',
          calls,
          document: _synced('YouLyPlus'),
        );
        final third = _Provider(
          'Better Lyrics',
          calls,
          document: _synced('Better Lyrics'),
        );
        final service = _service([first, second, third]);

        expect(await service.findLyrics(_lookup), same(expected));
        expect(calls, ['LRCLIB.find']);
        expect(first.findLookups, [_lookup]);
        expect(second.findLookups, isEmpty);
        expect(third.findLookups, isEmpty);
      },
    );

    test('plain lyrics do not stop a search for synchronization', () async {
      final calls = <String>[];
      final expected = _synced('LyricsPlus');
      final service = _service([
        _Provider('Better Lyrics', calls, document: _plain('Better Lyrics')),
        _Provider('LyricsPlus', calls, document: expected),
      ]);

      expect(await service.findLyrics(_lookup), same(expected));
      expect(calls, ['Better Lyrics.find', 'LyricsPlus.find']);
    });

    test('plain lyrics survive downstream errors and instrumentals', () async {
      final expected = _plain('Better Lyrics');
      final calls = <String>[];
      final service = _service([
        _Provider('Better Lyrics', calls, document: expected),
        _Provider(
          'LyricsPlus',
          calls,
          error: const LyricsConnectionException(),
        ),
        _Provider('LRCLIB', calls, document: _instrumental('LRCLIB')),
      ]);
      expect(await service.findLyrics(_lookup), same(expected));
      expect(calls, ['Better Lyrics.find', 'LyricsPlus.find', 'LRCLIB.find']);
    });

    test(
      'a plain fragment yields to a clearly fuller plain fallback',
      () async {
        final expected = LyricsDocument(
          provider: 'LRCLIB',
          trackName: 'Song',
          artistName: 'Artist',
          plainLyrics: List.generate(
            8,
            (index) => 'Full verse number $index of the song',
          ).join('\n'),
        );
        final service = _service([
          _Provider('Better Lyrics', [], document: _plain('Better Lyrics')),
          _Provider('LRCLIB', [], document: expected),
        ]);
        expect(await service.findLyrics(_lookup), same(expected));
      },
    );

    for (final timestamps in [
      [Duration.zero, Duration.zero, Duration.zero],
      [const Duration(seconds: 10)],
      [const Duration(seconds: -1), const Duration(seconds: 30)],
      [const Duration(seconds: 10), const Duration(seconds: 200)],
    ]) {
      test('unreliable timing $timestamps tries another provider', () async {
        final expected = _synced('LRCLIB');
        final calls = <String>[];
        final service = _service([
          _Provider(
            'LyricsPlus',
            calls,
            document: LyricsDocument(
              provider: 'LyricsPlus',
              trackName: 'Song',
              artistName: 'Artist',
              lines: [
                for (var i = 0; i < timestamps.length; i++)
                  LyricLine(timestamp: timestamps[i], text: 'Verse $i'),
              ],
            ),
          ),
          _Provider('LRCLIB', calls, document: expected),
        ]);
        expect(await service.findLyrics(_lookup), same(expected));
        expect(calls, ['LyricsPlus.find', 'LRCLIB.find']);
      });
    }

    test(
      'full plain text with partial timing tries the next provider',
      () async {
        final expected = _synced('LRCLIB');
        final service = _service([
          _Provider('LyricsPlus', [], document: _partial()),
          _Provider('LRCLIB', [], document: expected),
        ]);
        expect(await service.findLyrics(_lookup), same(expected));
      },
    );

    test(
      'partial timing falls back to all verses if no complete timing exists',
      () async {
        final original = _partial();
        final service = _service([
          _Provider('LyricsPlus', [], document: original),
        ]);
        final result = await service.findLyrics(_lookup);
        expect(result?.provider, 'LyricsPlus');
        expect(result?.hasSyncedLyrics, isFalse);
        expect(result?.plainLyrics, original.plainLyrics);
      },
    );

    test(
      'invalid timing is never displayed as synchronized as a last resort',
      () async {
        final invalid = LyricsDocument(
          provider: 'LyricsPlus',
          trackName: 'Song',
          artistName: 'Artist',
          lines: const [
            LyricLine(timestamp: Duration(seconds: -1), text: 'Verse'),
          ],
        );
        final result = await _service([
          _Provider('LyricsPlus', [], document: invalid),
        ]).findLyrics(_lookup);
        expect(result?.hasSyncedLyrics, isFalse);
        expect(result?.plainLyrics, 'Verse');
      },
    );

    test(
      'zero-stamped verses fall back to plain text after all providers',
      () async {
        const document = LyricsDocument(
          provider: 'LyricsPlus',
          trackName: 'Song',
          artistName: 'Artist',
          lines: [
            LyricLine(timestamp: Duration.zero, text: 'First verse'),
            LyricLine(timestamp: Duration.zero, text: 'Second verse'),
          ],
        );
        final result = await _service([
          _Provider('LyricsPlus', [], document: document),
          _Provider('LRCLIB', []),
        ]).findLyrics(_lookup);
        expect(result?.hasSyncedLyrics, isFalse);
        expect(result?.plainLyrics, 'First verse\nSecond verse');
      },
    );

    test(
      'legitimate one-line songs remain available after exhausting providers',
      () async {
        const single = LyricsDocument(
          provider: 'LyricsPlus',
          trackName: 'Song',
          artistName: 'Artist',
          lines: [
            LyricLine(timestamp: Duration(seconds: 30), text: 'Only one verse'),
          ],
        );
        final calls = <String>[];
        final service = _service([
          _Provider('LyricsPlus', calls, document: single),
          _Provider('LRCLIB', calls),
        ]);
        expect(await service.findLyrics(_lookup), same(single));
        expect(calls, ['LyricsPlus.find', 'LRCLIB.find']);
      },
    );

    test(
      'long intros and instrumental outros do not invalidate timing',
      () async {
        const expected = LyricsDocument(
          provider: 'Better Lyrics',
          trackName: 'Song',
          artistName: 'Artist',
          lines: [
            LyricLine(timestamp: Duration(seconds: 60), text: 'First verse'),
            LyricLine(timestamp: Duration(seconds: 80), text: 'Last verse'),
          ],
        );
        final calls = <String>[];
        final service = _service([
          _Provider('Better Lyrics', calls, document: expected),
          _Provider('LRCLIB', calls),
        ]);
        expect(await service.findLyrics(_lookup), same(expected));
        expect(calls, ['Better Lyrics.find']);
      },
    );

    for (final kind in ['instrumental', 'empty', 'null', 'error']) {
      test(
        '$kind responses fall through to the third provider in order',
        () async {
          final calls = <String>[];
          final expected = _synced('Better Lyrics');
          final service = _service([
            _Provider(
              'LRCLIB',
              calls,
              document: _response(kind, 'LRCLIB'),
              error: kind == 'error' ? StateError('first failed') : null,
            ),
            _Provider(
              'YouLyPlus',
              calls,
              document: _response(kind, 'YouLyPlus'),
              error: kind == 'error' ? StateError('second failed') : null,
            ),
            _Provider('Better Lyrics', calls, document: expected),
          ]);

          expect(await service.findLyrics(_lookup), same(expected));
          expect(calls, [
            'LRCLIB.find',
            'YouLyPlus.find',
            'Better Lyrics.find',
          ]);
        },
      );
    }

    test('only the supplied enabled provider is queried', () async {
      final calls = <String>[];
      final disabledLrclib = _Provider('LRCLIB', calls);
      final enabled = _Provider(
        'YouLyPlus',
        calls,
        document: _plain('YouLyPlus'),
      );
      final disabledBetter = _Provider('Better Lyrics', calls);
      final service = _service([enabled]);

      expect((await service.findLyrics(_lookup))?.provider, 'YouLyPlus');
      expect(calls, ['YouLyPlus.find']);
      expect(disabledLrclib.findLookups, isEmpty);
      expect(disabledBetter.findLookups, isEmpty);
    });

    test('an empty selection yields no lyrics and no candidates', () async {
      final service = _service([]);
      expect(await service.findLyrics(_lookup), isNull);
      expect(await service.findSimilarLyrics(_lookup), isEmpty);
      expect(
        await service.searchLyricsByTitle('Song', context: _lookup),
        isEmpty,
      );
    });

    test(
      'all instrumental results return the first only after trying all',
      () async {
        final calls = <String>[];
        final first = _instrumental('LRCLIB');
        final service = _service([
          _Provider('LRCLIB', calls, document: first),
          _Provider('YouLyPlus', calls, document: _instrumental('YouLyPlus')),
          _Provider(
            'Better Lyrics',
            calls,
            document: _instrumental('Better Lyrics'),
          ),
        ]);

        expect(await service.findLyrics(_lookup), same(first));
        expect(calls, ['LRCLIB.find', 'YouLyPlus.find', 'Better Lyrics.find']);
      },
    );

    test(
      'an instrumental survives null and errors only as last resort',
      () async {
        final calls = <String>[];
        final instrumental = _instrumental('YouLyPlus');
        final service = _service([
          _Provider('LRCLIB', calls, error: const LyricsConnectionException()),
          _Provider('YouLyPlus', calls, document: instrumental),
          _Provider('Better Lyrics', calls),
        ]);

        expect(await service.findLyrics(_lookup), same(instrumental));
        expect(calls, ['LRCLIB.find', 'YouLyPlus.find', 'Better Lyrics.find']);
      },
    );

    test('all null or empty documents return null, not instrumental', () async {
      final calls = <String>[];
      final service = _service([
        _Provider('LRCLIB', calls),
        _Provider('YouLyPlus', calls, document: _empty('YouLyPlus')),
        _Provider('Better Lyrics', calls, document: _empty('Better Lyrics')),
      ]);

      expect(await service.findLyrics(_lookup), isNull);
      expect(calls, ['LRCLIB.find', 'YouLyPlus.find', 'Better Lyrics.find']);
    });

    test(
      'all null results return null after consulting every provider',
      () async {
        final calls = <String>[];
        final service = _service([
          _Provider('LRCLIB', calls),
          _Provider('YouLyPlus', calls),
          _Provider('Better Lyrics', calls),
        ]);
        expect(await service.findLyrics(_lookup), isNull);
        expect(calls, ['LRCLIB.find', 'YouLyPlus.find', 'Better Lyrics.find']);
      },
    );

    test(
      'all failures retain the first exception identity and connection type',
      () async {
        final calls = <String>[];
        final first = LyricsConnectionException(StateError('offline'));
        final service = _service([
          _Provider('LRCLIB', calls, error: first),
          _Provider(
            'YouLyPlus',
            calls,
            error: const FormatException('bad json'),
          ),
          _Provider('Better Lyrics', calls, error: StateError('unavailable')),
        ]);

        await expectLater(service.findLyrics(_lookup), throwsA(same(first)));
        expect(calls, ['LRCLIB.find', 'YouLyPlus.find', 'Better Lyrics.find']);
      },
    );

    for (final nullFirst in [false, true]) {
      test(
        'a legitimate null suppresses unrelated failures (null first: $nullFirst)',
        () async {
          final calls = <String>[];
          final failure = _Provider(
            'failed',
            calls,
            error: StateError('network'),
          );
          final missing = _Provider('missing', calls);
          final service = _service(
            nullFirst ? [missing, failure] : [failure, missing],
          );

          expect(await service.findLyrics(_lookup), isNull);
          expect(calls, hasLength(2));
        },
      );
    }

    test(
      'coalesces equivalent in-flight lookups and releases them on completion',
      () async {
        final calls = <String>[];
        final pending = Completer<LyricsDocument?>();
        final provider = _Provider(
          'LRCLIB',
          calls,
          findOperation: (_) => pending.future,
        );
        final service = _service([provider]);
        final first = service.findLyrics(_lookup);
        final duplicate = service.findLyrics(
          const LyricsLookup(
            title: 'Song',
            artist: 'Artist',
            album: 'Album',
            duration: Duration(seconds: 180),
            sourceId: 'video',
          ),
        );
        expect(duplicate, same(first));
        expect(calls, ['LRCLIB.find']);

        final document = _synced('LRCLIB');
        pending.complete(document);
        expect(await first, same(document));
        expect(await duplicate, same(document));
        expect(await service.findLyrics(_lookup), same(document));
        expect(calls, ['LRCLIB.find', 'LRCLIB.find']);
      },
    );

    test(
      'different lookup context does not share an in-flight request',
      () async {
        final calls = <String>[];
        final pending = Completer<LyricsDocument?>();
        final provider = _Provider(
          'LRCLIB',
          calls,
          findOperation: (_) => pending.future,
        );
        final service = _service([provider]);
        final first = service.findLyrics(_lookup);
        final different = service.findLyrics(
          const LyricsLookup(title: 'Song', artist: 'Other artist'),
        );
        expect(different, isNot(same(first)));
        expect(provider.findLookups, hasLength(2));
        pending.complete(_synced('LRCLIB'));
        await Future.wait([first, different]);
      },
    );

    test(
      'failed in-flight requests are evicted so a later attempt can recover',
      () async {
        final calls = <String>[];
        var attempts = 0;
        final document = _plain('LRCLIB');
        final provider = _Provider(
          'LRCLIB',
          calls,
          findOperation: (_) {
            if (++attempts == 1) throw const LyricsConnectionException();
            return document;
          },
        );
        final service = _service([provider]);
        await expectLater(
          service.findLyrics(_lookup),
          throwsA(isA<LyricsConnectionException>()),
        );
        expect(await service.findLyrics(_lookup), same(document));
        expect(attempts, 2);
      },
    );

    test('does not persist facade misses between completed requests', () async {
      final calls = <String>[];
      final service = _service([_Provider('LRCLIB', calls)]);
      expect(await service.findLyrics(_lookup), isNull);
      expect(await service.findLyrics(_lookup), isNull);
      expect(calls, ['LRCLIB.find', 'LRCLIB.find']);
    });

    test('invalid lookups fail before any provider is queried', () {
      final calls = <String>[];
      final service = _service([_Provider('LRCLIB', calls)]);
      expect(
        () => service.findLyrics(
          const LyricsLookup(title: ' \t ', artist: 'Artist'),
        ),
        throwsArgumentError,
      );
      expect(calls, isEmpty);
    });
  });

  group('ownership and disposal', () {
    test('owns distinct clients by default and disposes each only once', () {
      final calls = <String>[];
      final first = _Provider('first', calls);
      final second = _Provider('second', calls);
      final service = FallbackLyricsService(providers: [first, second, first]);
      service.dispose();
      service.dispose();
      expect(first.disposeCalls, 1);
      expect(second.disposeCalls, 1);
    });

    test('external ownership never disposes providers', () {
      final provider = _Provider('external', []);
      final service = FallbackLyricsService(
        providers: [provider],
        disposeProviders: false,
      );
      service.dispose();
      service.dispose();
      expect(provider.disposeCalls, 0);
    });

    test('closed services reject every lookup entry point', () async {
      final calls = <String>[];
      final service = FallbackLyricsService(
        providers: [_Provider('LRCLIB', calls)],
      );
      service.dispose();
      expect(() => service.findLyrics(_lookup), throwsStateError);
      await expectLater(service.findSimilarLyrics(_lookup), throwsStateError);
      expect(
        () => service.searchLyricsByTitle('Song', context: _lookup),
        throwsStateError,
      );
      expect(calls, isEmpty);
    });

    for (final result in ['lyrics', 'instrumental', 'null', 'error']) {
      test(
        'closing during an awaited $result request prevents stale output and fallback',
        () async {
          final calls = <String>[];
          final pending = Completer<LyricsDocument?>();
          final first = _Provider(
            'LRCLIB',
            calls,
            findOperation: (_) => pending.future,
          );
          final next = _Provider(
            'YouLyPlus',
            calls,
            document: _synced('YouLyPlus'),
          );
          final service = FallbackLyricsService(providers: [first, next]);
          final future = service.findLyrics(_lookup);
          final assertion = expectLater(future, throwsStateError);
          service.dispose();
          if (result == 'error') {
            pending.completeError(const LyricsConnectionException());
          } else {
            pending.complete(
              result == 'lyrics'
                  ? _synced('LRCLIB')
                  : _response(result, 'LRCLIB'),
            );
          }
          await assertion;
          expect(calls, ['LRCLIB.find']);
          expect(next.findLookups, isEmpty);
        },
      );
    }
  });

  for (final manual in [false, true]) {
    group(manual ? 'manual search' : 'similar candidates', () {
      Future<List<LyricsCandidate>> search(
        FallbackLyricsService service, {
        int limit = 8,
      }) => manual
          ? service.searchLyricsByTitle(
              'Manual title',
              context: _lookup,
              limit: limit,
            )
          : service.findSimilarLyrics(_lookup, limit: limit);

      test(
        'preserves provider priority, remaining limits, and immutable output',
        () async {
          final calls = <String>[];
          final a = _candidate(_plain('LRCLIB', id: 'a'));
          final b = _candidate(_synced('YouLyPlus', id: 'b'));
          final first = _Provider('LRCLIB', calls, candidates: [a]);
          final second = _Provider('YouLyPlus', calls, candidates: [b]);
          final third = _Provider(
            'Better Lyrics',
            calls,
            candidates: [_candidate(_plain('Better Lyrics'))],
          );
          final service = _service([first, second, third]);

          final result = await search(service, limit: 2);
          expect(result, [a, b]);
          expect(calls, [
            'LRCLIB.${manual ? 'manual' : 'similar'}',
            'YouLyPlus.${manual ? 'manual' : 'similar'}',
          ]);
          expect(
            manual
                ? first.manualLookups.single.$3
                : first.similarLookups.single.$2,
            2,
          );
          expect(
            manual
                ? second.manualLookups.single.$3
                : second.similarLookups.single.$2,
            1,
          );
          expect(() => result.add(a), throwsUnsupportedError);
          if (manual) {
            expect(first.manualLookups.single.$1, 'Manual title');
            expect(first.manualLookups.single.$2, same(_lookup));
          } else {
            expect(first.similarLookups.single.$1, same(_lookup));
          }
        },
      );

      test(
        'filters empty/instrumental and deduplicates within, not across, providers',
        () async {
          final calls = <String>[];
          final first = _candidate(_synced('LRCLIB', id: 'shared'));
          final duplicate = _candidate(_plain('LRCLIB', id: 'shared'));
          final differentProvider = _candidate(
            _plain('YouLyPlus', id: 'shared'),
          );
          final withoutId = _candidate(_plain('Better Lyrics'));
          final service = _service([
            _Provider(
              'LRCLIB',
              calls,
              candidates: [
                _candidate(_instrumental('LRCLIB')),
                _candidate(_empty('LRCLIB')),
                first,
                duplicate,
              ],
            ),
            _Provider('YouLyPlus', calls, candidates: [differentProvider]),
            _Provider(
              'Better Lyrics',
              calls,
              candidates: [withoutId, withoutId],
            ),
          ]);

          expect(await search(service), [first, differentProvider, withoutId]);
          expect(calls, hasLength(3));
        },
      );

      test(
        'enforces the total limit even if a provider returns too many',
        () async {
          final calls = <String>[];
          final first = _candidate(_plain('LRCLIB', id: '1'));
          final service = _service([
            _Provider(
              'LRCLIB',
              calls,
              candidates: [
                first,
                _candidate(_plain('LRCLIB', id: '2')),
              ],
            ),
            _Provider('YouLyPlus', calls),
          ]);
          expect(await search(service, limit: 1), [first]);
          expect(calls, hasLength(1));
        },
      );

      test(
        'continues after provider errors and accepts actual plain lyrics',
        () async {
          final calls = <String>[];
          final expected = _candidate(_plain('Better Lyrics'));
          final service = _service([
            _Provider(
              'LRCLIB',
              calls,
              error: const LyricsConnectionException(),
            ),
            _Provider('YouLyPlus', calls),
            _Provider('Better Lyrics', calls, candidates: [expected]),
          ]);
          expect(await search(service), [expected]);
          expect(calls, hasLength(3));
        },
      );

      test('all errors preserve the first exception', () async {
        final error = LyricsConnectionException(StateError('offline'));
        final service = _service([
          _Provider('LRCLIB', [], error: error),
          _Provider('YouLyPlus', [], error: const FormatException('bad')),
        ]);
        await expectLater(search(service), throwsA(same(error)));
      });

      test('a valid empty response suppresses failures', () async {
        final service = _service([
          _Provider('LRCLIB', [], error: const LyricsConnectionException()),
          _Provider('YouLyPlus', []),
        ]);
        expect(await search(service), isEmpty);
      });

      test('nonpositive limits never query a provider', () async {
        final calls = <String>[];
        final service = _service([_Provider('LRCLIB', calls)]);
        expect(await search(service, limit: 0), isEmpty);
        expect(await search(service, limit: -3), isEmpty);
        expect(calls, isEmpty);
      });

      test(
        'closing before the last provider fails never returns earlier candidates',
        () async {
          final calls = <String>[];
          final pending = Completer<List<LyricsCandidate>>();
          final lastStarted = Completer<void>();
          Future<List<LyricsCandidate>> waitForLast() {
            lastStarted.complete();
            return pending.future;
          }

          final service = _service([
            _Provider(
              'LRCLIB',
              calls,
              candidates: [_candidate(_plain('LRCLIB', id: 'earlier'))],
            ),
            _Provider(
              'Better Lyrics',
              calls,
              similarOperation: (_, _) => waitForLast(),
              manualOperation: (_, _, _) => waitForLast(),
            ),
          ]);
          final result = search(service);
          final assertion = expectLater(result, throwsStateError);
          // The first provider has already supplied a usable result. Wait for
          // the final awaited provider before changing the enabled selection.
          await lastStarted.future;
          expect(calls, [
            'LRCLIB.${manual ? 'manual' : 'similar'}',
            'Better Lyrics.${manual ? 'manual' : 'similar'}',
          ]);
          service.dispose();
          pending.completeError(const LyricsConnectionException());
          await assertion;
        },
      );

      test(
        'closing while waiting rejects stale candidates and never calls the next provider',
        () async {
          final calls = <String>[];
          final pending = Completer<List<LyricsCandidate>>();
          final first = _Provider(
            'LRCLIB',
            calls,
            similarOperation: (_, _) => pending.future,
            manualOperation: (_, _, _) => pending.future,
          );
          final service = FallbackLyricsService(
            providers: [first, _Provider('YouLyPlus', calls)],
          );
          final assertion = expectLater(search(service), throwsStateError);
          service.dispose();
          pending.complete([_candidate(_plain('LRCLIB'))]);
          await assertion;
          expect(calls, hasLength(1));
        },
      );
    });
  }

  test('blank manual titles never query a provider', () async {
    final calls = <String>[];
    final service = _service([_Provider('LRCLIB', calls)]);
    expect(
      await service.searchLyricsByTitle(' \n ', context: _lookup),
      isEmpty,
    );
    expect(calls, isEmpty);
  });
}

FallbackLyricsService _service(List<LyricsService> providers) {
  final service = FallbackLyricsService(providers: providers);
  addTearDown(service.dispose);
  return service;
}

LyricsDocument? _response(String kind, String provider) => switch (kind) {
  'instrumental' => _instrumental(provider),
  'empty' => _empty(provider),
  _ => null,
};

LyricsDocument _synced(String provider, {String? id}) => LyricsDocument(
  provider: provider,
  providerId: id,
  trackName: 'Song',
  artistName: 'Artist',
  duration: const Duration(seconds: 180),
  syncedLyrics: '[00:01.000]First line\n[00:45.000]Second line',
  lines: const [
    LyricLine(timestamp: Duration(seconds: 1), text: 'First line'),
    LyricLine(timestamp: Duration(seconds: 45), text: 'Second line'),
  ],
);

LyricsDocument _partial() => const LyricsDocument(
  provider: 'LyricsPlus',
  trackName: 'Song',
  artistName: 'Artist',
  plainLyrics:
      'First verse of the song\nSecond verse of the song\nThird verse without timing\nFinal verse without timing',
  lines: [
    LyricLine(timestamp: Duration(seconds: 1), text: 'First verse of the song'),
    LyricLine(
      timestamp: Duration(seconds: 40),
      text: 'Second verse of the song',
    ),
  ],
);

LyricsDocument _plain(String provider, {String? id}) => LyricsDocument(
  provider: provider,
  providerId: id,
  trackName: 'Song',
  artistName: 'Artist',
  duration: const Duration(seconds: 180),
  plainLyrics: 'First line\nSecond line',
);

LyricsDocument _instrumental(String provider) => LyricsDocument(
  provider: provider,
  trackName: 'Song',
  artistName: 'Artist',
  instrumental: true,
);

LyricsDocument _empty(String provider) => LyricsDocument(
  provider: provider,
  trackName: 'Song',
  artistName: 'Artist',
  plainLyrics: ' \n ',
);

LyricsCandidate _candidate(LyricsDocument document) =>
    LyricsCandidate(document: document, similarity: 1);

class _Provider extends LyricsService {
  _Provider(
    this.name,
    this.calls, {
    this.document,
    this.error,
    this.candidates = const [],
    this.findOperation,
    this.similarOperation,
    this.manualOperation,
  });

  final String name;
  final List<String> calls;
  final LyricsDocument? document;
  final Object? error;
  final List<LyricsCandidate> candidates;
  final FutureOr<LyricsDocument?> Function(LyricsLookup)? findOperation;
  final FutureOr<List<LyricsCandidate>> Function(LyricsLookup, int)?
  similarOperation;
  final FutureOr<List<LyricsCandidate>> Function(String, LyricsLookup, int)?
  manualOperation;
  final findLookups = <LyricsLookup>[];
  final similarLookups = <(LyricsLookup, int)>[];
  final manualLookups = <(String, LyricsLookup, int)>[];
  int disposeCalls = 0;

  @override
  Future<LyricsDocument?> findLyrics(LyricsLookup lookup) async {
    calls.add('$name.find');
    findLookups.add(lookup);
    if (findOperation case final operation?) return await operation(lookup);
    if (error case final failure?) throw failure;
    return document;
  }

  @override
  Future<List<LyricsCandidate>> findSimilarLyrics(
    LyricsLookup lookup, {
    int limit = 8,
  }) async {
    calls.add('$name.similar');
    similarLookups.add((lookup, limit));
    if (similarOperation case final operation?) {
      return await operation(lookup, limit);
    }
    if (error case final failure?) throw failure;
    return candidates;
  }

  @override
  Future<List<LyricsCandidate>> searchLyricsByTitle(
    String title, {
    required LyricsLookup context,
    int limit = 8,
  }) async {
    calls.add('$name.manual');
    manualLookups.add((title, context, limit));
    if (manualOperation case final operation?) {
      return await operation(title, context, limit);
    }
    if (error case final failure?) throw failure;
    return candidates;
  }

  @override
  void dispose() => disposeCalls++;
}
