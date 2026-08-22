import 'dart:convert';
import 'dart:io';

import 'package:bstream_music/services/youtube_music/innertube_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _immediateRetryDelay(Duration _) async {}

DateTime _fixedRetryClock() => DateTime.utc(2026, 8, 22, 12);

void main() {
  group('artist browse IDs', () {
    test('songs and albums preserve IDs aligned with artist names', () {
      final song = const InnerTubeSearchParser().parse({
        'contents': [
          _responsiveSong(
            videoId: 'song0000001',
            title: 'Song',
            artist: 'Song artist',
            artistBrowseId: 'UCsongartist1',
          ),
        ],
      }).single;
      final album = const InnerTubeAlbumParser().parse({
        'contents': [
          _twoRowAlbum(
            browseId: 'MPREalbum0001',
            title: 'Album',
            artist: 'Album artist',
            artistBrowseId: 'UCalbumartist1',
          ),
        ],
      }).single;

      expect(song.artists, ['Song artist']);
      expect(song.artistBrowseIds, ['UCsongartist1']);
      expect(album.artists, ['Album artist']);
      expect(album.artistBrowseIds, ['UCalbumartist1']);
    });

    test('legacy constructors add null IDs and reject misaligned input', () {
      final song = InnerTubeSong(
        videoId: 'song0000001',
        title: 'Song',
        artists: const ['One', 'Two'],
      );

      expect(song.artistBrowseIds, [null, null]);
      expect(
        () => InnerTubeSong(
          videoId: 'song0000001',
          title: 'Song',
          artists: const ['One'],
          artistBrowseIds: const [],
        ),
        throwsArgumentError,
      );
    });
  });

  group('InnerTubeNextParser', () {
    const parser = InnerTubeNextParser();

    test('parses ranked queue, continuation, related tab, and automix', () {
      final page = parser.parse(
        _nextPayload(
          songs: [
            _playlistPanelSong(
              videoId: 'seed0000001',
              title: 'Seed',
              artist: 'Seed artist',
              artistBrowseId: 'UCseedartist1',
              album: 'Seed album',
              duration: '3:05',
            ),
            _playlistPanelSong(
              videoId: 'next0000001',
              title: 'Next',
              artist: 'Next artist',
              artistBrowseId: 'UCnextartist1',
              duration: '1:02:03',
            ),
            _playlistPanelSong(
              videoId: 'next0000001',
              title: 'Duplicate',
              artist: 'Ignored',
            ),
            {
              'playlistPanelVideoRenderer': {'videoId': 'broken00001'},
            },
          ],
          continuation: 'NEXT_TOKEN',
          relatedBrowseId: 'MPTRrelated001',
          automixPlaylistId: 'RDAMVMseed0000001',
        ),
      );

      expect(page.songs.map((song) => song.videoId), [
        'seed0000001',
        'next0000001',
      ]);
      expect(page.songs.first.artistBrowseIds, ['UCseedartist1']);
      expect(page.songs.first.album, 'Seed album');
      expect(page.songs.first.duration, const Duration(minutes: 3, seconds: 5));
      expect(
        page.songs.last.duration,
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(page.continuation, 'NEXT_TOKEN');
      expect(page.relatedBrowseId, 'MPTRrelated001');
      expect(page.automixPlaylistId, 'RDAMVMseed0000001');
    });

    test('supports playlistPanelContinuation and defensive roots', () {
      final page = parser.parse({
        'continuationContents': {
          'playlistPanelContinuation': {
            'contents': [
              _playlistPanelSong(
                videoId: 'next0000002',
                title: 'Continued',
                artist: 'Artist',
              ),
            ],
            'continuations': [
              {
                'continuationCommand': {'token': 'MORE_TOKEN'},
              },
            ],
          },
        },
      });

      expect(page.songs.single.videoId, 'next0000002');
      expect(page.continuation, 'MORE_TOKEN');
      expect(
        () => parser.parse(const []),
        throwsA(isA<InnerTubeFormatException>()),
      );
      expect(() => parser.parse(const {}, limit: 0), throwsRangeError);
      expect(
        () => parser.parse(const {}, limit: innerTubeDetailResultLimit + 1),
        throwsRangeError,
      );
    });
  });

  group('InnerTubeRelatedParser', () {
    const parser = InnerTubeRelatedParser();

    test('separates songs, albums, artists, and playlists', () {
      final page = parser.parse({
        'contents': [
          _twoRowSong(
            videoId: 'song0000002',
            title: 'Related song',
            artist: 'Song artist',
            artistBrowseId: 'UCsongartist2',
          ),
          _twoRowAlbum(
            browseId: 'MPREalbum0002',
            title: 'Related album',
            artist: 'Album artist',
            artistBrowseId: 'UCalbumartist2',
          ),
          _twoRowArtist(browseId: 'UCrelated001', name: 'Related artist'),
          _twoRowCollection(
            browseId: 'VLRDrelated001',
            playlistId: 'RDrelated001',
            title: 'Related mix',
          ),
        ],
        'continuations': [
          {
            'nextContinuationData': {'continuation': 'RELATED_MORE'},
          },
        ],
      });

      expect(page.songs.map((song) => song.title), ['Related song']);
      expect(page.songs.single.artistBrowseIds, ['UCsongartist2']);
      expect(page.albums.map((album) => album.title), ['Related album']);
      expect(page.albums.single.artistBrowseIds, ['UCalbumartist2']);
      expect(page.artists, [
        const InnerTubeArtist(
          browseId: 'UCrelated001',
          name: 'Related artist',
          thumbnailUrl: 'https://img.test/artist-large.jpg',
        ),
      ]);
      expect(page.collections.single.kind, InnerTubeHomeCollectionKind.mix);
      expect(page.collections.single.playlistId, 'RDrelated001');
      expect(page.continuation, 'RELATED_MORE');
    });

    test('deduplicates categories and validates roots and limits', () {
      final artist = _twoRowArtist(
        browseId: 'UCrelated001',
        name: 'Related artist',
      );
      final page = parser.parse({
        'contents': [artist, artist],
      });

      expect(page.artists, hasLength(1));
      expect(
        () => parser.parse(const []),
        throwsA(isA<InnerTubeFormatException>()),
      );
      expect(() => parser.parse(const {}, limit: 21), throwsRangeError);
    });
  });

  group('InnerTube related service', () {
    late _FakeTransport transport;

    setUp(() {
      transport = _FakeTransport();
    });

    InnerTubeSearchService createService({
      InnerTubeVisitorDataStore? visitorDataStore,
    }) {
      final service = InnerTubeSearchService(
        transport: transport,
        visitorDataStore: visitorDataStore,
        endpoint: Uri.parse('https://example.test/search'),
        browseEndpoint: Uri.parse('https://example.test/browse'),
        playerEndpoint: Uri.parse('https://example.test/player'),
        nextEndpoint: Uri.parse('https://example.test/next'),
        bootstrapUri: Uri.parse('https://example.test/bootstrap'),
        language: 'es',
        region: 'ni',
        userAgent: 'BStreamMusic/RelatedTest',
        retryDelay: _immediateRetryDelay,
        retryClock: _fixedRetryClock,
      );
      addTearDown(service.dispose);
      return service;
    }

    test('radio posts RDAMVM and keeps YouTube queue order', () async {
      transport.postResponses.add(
        _okJson(
          _nextPayload(
            songs: [
              _playlistPanelSong(
                videoId: 'seed0000001',
                title: 'Seed',
                artist: 'Artist',
              ),
              _playlistPanelSong(
                videoId: 'next0000001',
                title: 'Next',
                artist: 'Artist',
              ),
            ],
          ),
        ),
      );
      final service = createService();

      final page = await service.getNext('seed0000001', radio: true);

      expect(page.songs.map((song) => song.videoId), [
        'seed0000001',
        'next0000001',
      ]);
      expect(transport.posts, hasLength(1));
      expect(transport.posts.single.uri.path, '/next');
      expect(transport.posts.single.body['videoId'], 'seed0000001');
      expect(transport.posts.single.body['playlistId'], 'RDAMVMseed0000001');
      expect(transport.posts.single.body['isAudioOnly'], isTrue);
      expect(transport.posts.single.body['params'], 'wAEB');
    });

    test(
      'radio falls back to plain next when generated queue has one item',
      () async {
        transport.postResponses.addAll([
          _okJson(
            _nextPayload(
              songs: [
                _playlistPanelSong(
                  videoId: 'seed0000001',
                  title: 'Seed',
                  artist: 'Artist',
                ),
              ],
            ),
          ),
          _okJson(
            _nextPayload(
              songs: [
                _playlistPanelSong(
                  videoId: 'next0000002',
                  title: 'Fallback',
                  artist: 'Artist',
                ),
                _playlistPanelSong(
                  videoId: 'next0000003',
                  title: 'Fallback two',
                  artist: 'Artist',
                ),
              ],
            ),
          ),
        ]);
        final service = createService();

        final page = await service.getNext('seed0000001', radio: true);

        expect(page.songs.first.videoId, 'next0000002');
        expect(transport.posts, hasLength(2));
        expect(transport.posts.first.body['playlistId'], 'RDAMVMseed0000001');
        expect(transport.posts.last.body, isNot(contains('playlistId')));
        expect(transport.gets, hasLength(1));
      },
    );

    test(
      'next continuation sends only its opaque continuation token',
      () async {
        transport.postResponses.add(
          _okJson(
            _nextPayload(
              songs: [
                _playlistPanelSong(
                  videoId: 'next0000004',
                  title: 'Continued',
                  artist: 'Artist',
                ),
              ],
            ),
          ),
        );
        final service = createService();

        await service.getNextContinuation(' NEXT_TOKEN ');

        expect(transport.posts.single.body['continuation'], 'NEXT_TOKEN');
        expect(transport.posts.single.body, isNot(contains('videoId')));
        expect(transport.posts.single.body, isNot(contains('playlistId')));
      },
    );

    test('follows related browse IDs and continuations', () async {
      transport.postResponses.addAll([
        _okJson({
          'contents': [
            _twoRowArtist(browseId: 'UCrelated001', name: 'Related artist'),
          ],
        }),
        _okJson({
          'contents': [
            _twoRowSong(
              videoId: 'song0000003',
              title: 'More',
              artist: 'Artist',
            ),
          ],
        }),
      ]);
      final service = createService();

      final first = await service.getRelated('MPTRrelated001');
      final continued = await service.getRelatedContinuation('RELATED_MORE');

      expect(first.artists.single.browseId, 'UCrelated001');
      expect(continued.songs.single.videoId, 'song0000003');
      expect(transport.posts.first.body['browseId'], 'MPTRrelated001');
      expect(transport.posts.last.body['continuation'], 'RELATED_MORE');
    });

    test('artist release browse returns only direct album cards', () async {
      transport.postResponses.add(
        _okJson({
          'contents': [
            _twoRowAlbum(
              browseId: 'MPRErelease001',
              title: 'New release',
              artist: 'Artist',
              artistBrowseId: 'UCartist00001',
            ),
            _twoRowArtist(browseId: 'UCother000001', name: 'Fans also like'),
          ],
        }),
      );
      final service = createService();

      final releases = await service.getArtistReleases('UCartist00001');

      expect(releases.map((album) => album.title), ['New release']);
      expect(transport.posts.single.body['browseId'], 'UCartist00001');
    });

    test('validates recommendation identifiers before bootstrapping', () async {
      final service = createService();

      await expectLater(service.getNext('bad'), throwsArgumentError);
      await expectLater(service.getNextContinuation('  '), throwsArgumentError);
      await expectLater(service.getRelated('bad id'), throwsArgumentError);
      await expectLater(
        service.getArtistReleases('MPREnot-an-artist'),
        throwsArgumentError,
      );
      expect(transport.gets, isEmpty);
      expect(transport.posts, isEmpty);
    });
  });

  group('anonymous visitor persistence', () {
    test('uses an existing visitor ID without overwriting it', () async {
      final transport = _FakeTransport();
      final store = _FakeVisitorDataStore('persisted-visitor');
      transport.postResponses.add(_okJson({'contents': const []}));
      final service = InnerTubeSearchService(
        transport: transport,
        visitorDataStore: store,
        endpoint: Uri.parse('https://example.test/search'),
        bootstrapUri: Uri.parse('https://example.test/bootstrap'),
      );
      addTearDown(service.dispose);

      await service.searchSongs('query');

      expect(
        transport.posts.single.headers['X-Goog-Visitor-Id'],
        'persisted-visitor',
      );
      expect(
        ((transport.posts.single.body['context'] as Map)['client']
            as Map)['visitorData'],
        'persisted-visitor',
      );
      expect(store.readCount, 1);
      expect(store.writes, isEmpty);
    });

    test('persists bootstrap visitor ID when storage is empty', () async {
      final transport = _FakeTransport();
      final store = _FakeVisitorDataStore(null);
      transport.postResponses.add(_okJson({'contents': const []}));
      final service = InnerTubeSearchService(
        transport: transport,
        visitorDataStore: store,
        endpoint: Uri.parse('https://example.test/search'),
        bootstrapUri: Uri.parse('https://example.test/bootstrap'),
      );
      addTearDown(service.dispose);

      await service.searchSongs('query');

      expect(store.writes, ['bootstrap-visitor']);
      expect(store.value, 'bootstrap-visitor');
    });

    test(
      'rotates a rejected persisted visitor to fresh bootstrap data',
      () async {
        final transport = _FakeTransport();
        transport.getResponses.addAll([
          _bootstrapResponse(visitorData: 'page-visitor-old'),
          _bootstrapResponse(visitorData: 'page-visitor-fresh'),
        ]);
        transport.postResponses.addAll([
          const InnerTubeHttpResponse(
            statusCode: HttpStatus.forbidden,
            body: 'rejected visitor',
          ),
          _okJson({'contents': const []}),
        ]);
        final store = _FakeVisitorDataStore('persisted-stale');
        final service = InnerTubeSearchService(
          transport: transport,
          visitorDataStore: store,
          endpoint: Uri.parse('https://example.test/search'),
          bootstrapUri: Uri.parse('https://example.test/bootstrap'),
        );
        addTearDown(service.dispose);

        await service.searchSongs('query');

        expect(transport.posts, hasLength(2));
        expect(
          transport.posts.first.headers['X-Goog-Visitor-Id'],
          'persisted-stale',
        );
        expect(
          transport.posts.last.headers['X-Goog-Visitor-Id'],
          'page-visitor-fresh',
        );
        expect(store.writes, ['page-visitor-fresh']);
        expect(store.value, 'page-visitor-fresh');
        expect(transport.gets, hasLength(2));
      },
    );

    test('storage failures do not prevent anonymous requests', () async {
      final transport = _FakeTransport();
      final store = _FakeVisitorDataStore(null)
        ..readError = StateError('read failed')
        ..writeError = StateError('write failed');
      transport.postResponses.add(_okJson({'contents': const []}));
      final service = InnerTubeSearchService(
        transport: transport,
        visitorDataStore: store,
        endpoint: Uri.parse('https://example.test/search'),
        bootstrapUri: Uri.parse('https://example.test/bootstrap'),
      );
      addTearDown(service.dispose);

      await service.searchSongs('query');

      expect(
        transport.posts.single.headers['X-Goog-Visitor-Id'],
        'bootstrap-visitor',
      );
    });
  });
}

Map<String, Object> _nextPayload({
  required List<Map<String, Object>> songs,
  String? continuation,
  String? relatedBrowseId,
  String? automixPlaylistId,
}) {
  return {
    'contents': {
      'singleColumnMusicWatchNextResultsRenderer': {
        'tabbedRenderer': {
          'watchNextTabbedResultsRenderer': {
            'tabs': [
              {
                'tabRenderer': {
                  'content': {
                    'musicQueueRenderer': {
                      'content': {
                        'playlistPanelRenderer': {
                          'contents': [
                            ...songs,
                            if (automixPlaylistId != null)
                              {
                                'automixPreviewVideoRenderer': {
                                  'content': {
                                    'automixPlaylistVideoRenderer': {
                                      'navigationEndpoint': {
                                        'watchPlaylistEndpoint': {
                                          'playlistId': automixPlaylistId,
                                        },
                                      },
                                    },
                                  },
                                },
                              },
                          ],
                          if (continuation != null)
                            'continuations': [
                              {
                                'nextRadioContinuationData': {
                                  'continuation': continuation,
                                },
                              },
                            ],
                        },
                      },
                    },
                  },
                },
              },
              if (relatedBrowseId != null)
                {
                  'tabRenderer': {
                    'endpoint': {
                      'browseEndpoint': {
                        'browseId': relatedBrowseId,
                        'browseEndpointContextSupportedConfigs': {
                          'browseEndpointContextMusicConfig': {
                            'pageType': 'MUSIC_PAGE_TYPE_TRACK_RELATED',
                          },
                        },
                      },
                    },
                  },
                },
            ],
          },
        },
      },
    },
  };
}

Map<String, Object> _playlistPanelSong({
  required String videoId,
  required String title,
  required String artist,
  String? artistBrowseId,
  String? album,
  String? duration,
}) {
  return {
    'playlistPanelVideoRenderer': {
      'videoId': videoId,
      'title': {
        'runs': [
          {'text': title},
        ],
      },
      'longBylineText': {
        'runs': [
          _browseRun(
            artist,
            pageType: 'MUSIC_PAGE_TYPE_ARTIST',
            browseId: artistBrowseId,
          ),
          if (album != null) ...[
            {'text': ' • '},
            _browseRun(
              album,
              pageType: 'MUSIC_PAGE_TYPE_ALBUM',
              browseId: 'MPREalbumlink1',
            ),
          ],
        ],
      },
      if (duration != null)
        'lengthText': {
          'runs': [
            {'text': duration},
          ],
        },
      'thumbnail': {
        'thumbnails': [
          {'url': '//img.test/small.jpg', 'width': 100, 'height': 100},
          {'url': 'https://img.test/large.jpg', 'width': 500, 'height': 500},
        ],
      },
    },
  };
}

Map<String, Object> _responsiveSong({
  required String videoId,
  required String title,
  required String artist,
  String? artistBrowseId,
}) {
  return {
    'musicResponsiveListItemRenderer': {
      'playlistItemData': {'videoId': videoId},
      'flexColumns': [
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {
              'runs': [
                {'text': title},
              ],
            },
          },
        },
        {
          'musicResponsiveListItemFlexColumnRenderer': {
            'text': {
              'runs': [
                _browseRun(
                  artist,
                  pageType: 'MUSIC_PAGE_TYPE_ARTIST',
                  browseId: artistBrowseId,
                ),
              ],
            },
          },
        },
      ],
    },
  };
}

Map<String, Object> _twoRowSong({
  required String videoId,
  required String title,
  required String artist,
  String? artistBrowseId,
}) {
  return {
    'musicTwoRowItemRenderer': {
      'title': {
        'runs': [
          {
            'text': title,
            'navigationEndpoint': {
              'watchEndpoint': {'videoId': videoId},
            },
          },
        ],
      },
      'subtitle': {
        'runs': [
          _browseRun(
            artist,
            pageType: 'MUSIC_PAGE_TYPE_ARTIST',
            browseId: artistBrowseId,
          ),
        ],
      },
    },
  };
}

Map<String, Object> _twoRowAlbum({
  required String browseId,
  required String title,
  required String artist,
  required String artistBrowseId,
}) {
  final endpoint = _browseEndpoint(browseId, pageType: 'MUSIC_PAGE_TYPE_ALBUM');
  return {
    'musicTwoRowItemRenderer': {
      'title': {
        'runs': [
          {'text': title, 'navigationEndpoint': endpoint},
        ],
      },
      'navigationEndpoint': endpoint,
      'subtitle': {
        'runs': [
          {'text': 'Single'},
          {'text': ' • '},
          _browseRun(
            artist,
            pageType: 'MUSIC_PAGE_TYPE_ARTIST',
            browseId: artistBrowseId,
          ),
          {'text': ' • '},
          {'text': '2026'},
        ],
      },
    },
  };
}

Map<String, Object> _twoRowArtist({
  required String browseId,
  required String name,
}) {
  final endpoint = _browseEndpoint(
    browseId,
    pageType: 'MUSIC_PAGE_TYPE_ARTIST',
  );
  return {
    'musicTwoRowItemRenderer': {
      'title': {
        'runs': [
          {'text': name, 'navigationEndpoint': endpoint},
        ],
      },
      'navigationEndpoint': endpoint,
      'thumbnailRenderer': {
        'musicThumbnailRenderer': {
          'thumbnail': {
            'thumbnails': [
              {
                'url': 'https://img.test/artist-small.jpg',
                'width': 100,
                'height': 100,
              },
              {
                'url': 'https://img.test/artist-large.jpg',
                'width': 500,
                'height': 500,
              },
            ],
          },
        },
      },
    },
  };
}

Map<String, Object> _twoRowCollection({
  required String browseId,
  required String playlistId,
  required String title,
}) {
  final endpoint = _browseEndpoint(
    browseId,
    pageType: 'MUSIC_PAGE_TYPE_PLAYLIST',
  );
  return {
    'musicTwoRowItemRenderer': {
      'title': {
        'runs': [
          {'text': title, 'navigationEndpoint': endpoint},
        ],
      },
      'navigationEndpoint': endpoint,
      'thumbnailOverlay': {
        'musicItemThumbnailOverlayRenderer': {
          'content': {
            'musicPlayButtonRenderer': {
              'playNavigationEndpoint': {
                'watchPlaylistEndpoint': {'playlistId': playlistId},
              },
            },
          },
        },
      },
    },
  };
}

Map<String, Object> _browseRun(
  String text, {
  required String pageType,
  String? browseId,
}) {
  return {
    'text': text,
    'navigationEndpoint': _browseEndpoint(
      browseId ?? 'UNKNOWN',
      pageType: pageType,
    ),
  };
}

Map<String, Object> _browseEndpoint(
  String browseId, {
  required String pageType,
}) {
  return {
    'browseEndpoint': {
      'browseId': browseId,
      'browseEndpointContextSupportedConfigs': {
        'browseEndpointContextMusicConfig': {'pageType': pageType},
      },
    },
  };
}

InnerTubeHttpResponse _okJson(Object body) =>
    InnerTubeHttpResponse(statusCode: HttpStatus.ok, body: jsonEncode(body));

InnerTubeHttpResponse _bootstrapResponse({
  String visitorData = 'bootstrap-visitor',
}) {
  return InnerTubeHttpResponse(
    statusCode: HttpStatus.ok,
    body:
        '<script>{"INNERTUBE_API_KEY":"bootstrap-key",'
        '"INNERTUBE_CLIENT_VERSION":"bootstrap-version",'
        '"INNERTUBE_CLIENT_NAME":"WEB_REMIX",'
        '"INNERTUBE_CONTEXT_CLIENT_NAME":67,'
        '"VISITOR_DATA":"$visitorData"}</script>',
  );
}

class _FakeTransport implements InnerTubeTransport {
  final List<InnerTubeHttpResponse> getResponses = [];
  final List<Object> postResponses = [];
  final List<_GetRequest> gets = [];
  final List<_PostRequest> posts = [];
  int closeCount = 0;

  @override
  Future<InnerTubeHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
    Duration? timeout,
  }) async {
    gets.add(_GetRequest(uri));
    if (getResponses.isNotEmpty) {
      return getResponses.removeAt(0);
    }
    return _bootstrapResponse();
  }

  @override
  Future<InnerTubeHttpResponse> postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Object body,
    Duration? timeout,
  }) async {
    posts.add(
      _PostRequest(
        uri: uri,
        headers: Map.unmodifiable(headers),
        body: Map.unmodifiable(body as Map<String, Object>),
      ),
    );
    if (postResponses.isEmpty) {
      return _okJson({'contents': const []});
    }
    final response = postResponses.removeAt(0);
    if (response is InnerTubeHttpResponse) {
      return response;
    }
    throw response;
  }

  @override
  void close() {
    closeCount += 1;
  }
}

class _FakeVisitorDataStore implements InnerTubeVisitorDataStore {
  _FakeVisitorDataStore(this.value);

  String? value;
  Object? readError;
  Object? writeError;
  int readCount = 0;
  int clearCount = 0;
  final List<String> writes = [];

  @override
  Future<String?> read() async {
    readCount += 1;
    if (readError != null) {
      throw readError!;
    }
    return value;
  }

  @override
  Future<void> write(String visitorData) async {
    if (writeError != null) {
      throw writeError!;
    }
    writes.add(visitorData);
    value = visitorData;
  }

  @override
  Future<void> clear() async {
    clearCount += 1;
    value = null;
  }
}

class _GetRequest {
  const _GetRequest(this.uri);

  final Uri uri;
}

class _PostRequest {
  const _PostRequest({
    required this.uri,
    required this.headers,
    required this.body,
  });

  final Uri uri;
  final Map<String, String> headers;
  final Map<String, Object> body;
}
