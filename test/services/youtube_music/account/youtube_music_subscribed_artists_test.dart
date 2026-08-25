import 'package:bstream_music/services/youtube_music/account/youtube_music_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reads and paginates the authenticated subscribed-artists shelf',
    () async {
      final transport = _FakeTransport(<YouTubeMusicAccountResponse>[
        _ok(
          _artistShelf(
            browseId: 'MPLA-one',
            channelId: 'UC-one',
            name: 'Artista uno',
            continuation: 'artists-next',
          ),
        ),
        _ok(
          _artistShelf(
            browseId: 'UC-two',
            channelId: 'UC-two',
            name: 'Artista dos',
            continuationPage: true,
          ),
        ),
      ]);

      final collection = await _gateway(transport).getSubscribedArtists();

      expect(collection.isComplete, isTrue);
      expect(collection.pagesFetched, 2);
      expect(collection.artists.map((artist) => artist.name), <String>[
        'Artista uno',
        'Artista dos',
      ]);
      expect(collection.artists.first.browseId, 'MPLA-one');
      expect(collection.artists.first.channelId, 'UC-one');
      expect(
        collection.artists.first.thumbnailUrl,
        'https://img.test/UC-one-large.jpg',
      );
      expect(
        transport.requests.first.body['browseId'],
        'FEmusic_library_corpus_artists',
      );
      expect(transport.requests.last.body['continuation'], 'artists-next');
    },
  );

  test('deduplicates the same channel across artist browse ids', () async {
    const parser = YouTubeMusicAccountParser();
    final payload = <String, Object?>{
      'contents': <Object?>[
        <String, Object?>{
          'gridRenderer': <String, Object?>{
            'items': <Object?>[
              _artistItem(
                browseId: 'MPLA-version',
                channelId: 'UC-same',
                name: 'Duplicado',
              ),
              _artistItem(
                browseId: 'UC-same',
                channelId: 'UC-same',
                name: 'Duplicado',
              ),
            ],
          },
        },
      ],
    };

    final artists = parser.parseSubscribedArtists(payload);

    expect(artists, hasLength(1));
    expect(artists.single.identity, 'UC-same');
  });
}

YouTubeMusicAccountGateway _gateway(_FakeTransport transport) {
  return YouTubeMusicAccountGateway(
    transport: transport,
    sessionHeaders: StaticYouTubeMusicSessionHeadersProvider(
      YouTubeMusicSessionHeaders(const <String, String>{
        'Authorization': 'SAPISIDHASH fixture',
        'Cookie': 'SAPISID=fixture',
      }),
    ),
    clientContext: const <String, Object?>{
      'client': <String, Object?>{
        'clientName': 'WEB_REMIX',
        'clientVersion': 'test-version',
      },
    },
    retryDelay: (_) async {},
  );
}

YouTubeMusicAccountResponse _ok(Object? body) =>
    YouTubeMusicAccountResponse(statusCode: 200, body: body);

Map<String, Object?> _artistShelf({
  required String browseId,
  required String channelId,
  required String name,
  String? continuation,
  bool continuationPage = false,
}) {
  final items = <Object?>[
    _artistItem(browseId: browseId, channelId: channelId, name: name),
    if (continuation != null) _continuationItem(continuation),
  ];
  if (continuationPage) {
    return <String, Object?>{
      'continuationContents': <String, Object?>{
        'gridContinuation': <String, Object?>{'items': items},
      },
    };
  }
  return <String, Object?>{
    'contents': <Object?>[
      <String, Object?>{
        'gridRenderer': <String, Object?>{'items': items},
      },
    ],
  };
}

Map<String, Object?> _artistItem({
  required String browseId,
  required String channelId,
  required String name,
}) => <String, Object?>{
  'musicTwoRowItemRenderer': <String, Object?>{
    'title': <String, Object?>{
      'runs': <Object?>[
        <String, Object?>{'text': name},
      ],
    },
    'navigationEndpoint': <String, Object?>{
      'browseEndpoint': <String, Object?>{
        'browseId': browseId,
        'browseEndpointContextSupportedConfigs': <String, Object?>{
          'browseEndpointContextMusicConfig': <String, Object?>{
            'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
          },
        },
      },
    },
    'channelId': channelId,
    'thumbnailRenderer': <String, Object?>{
      'musicThumbnailRenderer': <String, Object?>{
        'thumbnail': <String, Object?>{
          'thumbnails': <Object?>[
            <String, Object?>{
              'url': 'https://img.test/$channelId-small.jpg',
              'width': 80,
              'height': 80,
            },
            <String, Object?>{
              'url': 'https://img.test/$channelId-large.jpg',
              'width': 320,
              'height': 320,
            },
          ],
        },
      },
    },
  },
};

Map<String, Object?> _continuationItem(String token) => <String, Object?>{
  'continuationItemRenderer': <String, Object?>{
    'continuationEndpoint': <String, Object?>{
      'continuationCommand': <String, Object?>{'token': token},
    },
  },
};

class _FakeTransport implements YouTubeMusicAccountTransport {
  _FakeTransport(this.responses);

  final List<YouTubeMusicAccountResponse> responses;
  final List<YouTubeMusicAccountRequest> requests =
      <YouTubeMusicAccountRequest>[];

  @override
  Future<YouTubeMusicAccountResponse> send(
    YouTubeMusicAccountRequest request,
  ) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}
